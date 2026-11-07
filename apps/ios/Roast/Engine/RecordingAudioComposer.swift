import AVFoundation
import Foundation

struct StudioSourceAudioSlice: Codable, Sendable, Equatable {
    var url: URL
    var sourceStart: Double
    var outputStart: Double
    var duration: Double
}

/// Maps actual player progress to take time. Playback stalls, pauses, seeks and
/// source changes break continuity instead of stretching or leaking old audio.
struct StudioSourceAudioTimeline {
    private(set) var slices: [StudioSourceAudioSlice] = []
    private var anchor: Anchor?
    private struct Anchor {
        var url: URL
        var source: Double
        var output: Double
        var playing: Bool
    }

    mutating func reset() { slices = []; anchor = nil }
    mutating func discontinuity() { anchor = nil }

    mutating func capture(url: URL, sourceTime: Double, outputTime: Double, playing: Bool) {
        guard sourceTime.isFinite, outputTime.isFinite, sourceTime >= 0, outputTime >= 0 else {
            anchor = nil
            return
        }
        let current = Anchor(url: url, source: sourceTime, output: outputTime, playing: playing)
        defer { anchor = current }
        guard let previous = anchor, previous.url == url, previous.playing, current.playing else { return }
        let sourceAdvance = sourceTime - previous.source
        let outputAdvance = outputTime - previous.output
        guard sourceAdvance > 0, outputAdvance > 0,
              sourceAdvance < max(0.25, outputAdvance * 2.5) else { return }
        let length = min(sourceAdvance, outputAdvance)
        if let last = slices.last, last.url == url,
           abs(last.sourceStart + last.duration - previous.source) < 0.015,
           abs(last.outputStart + last.duration - previous.output) < 0.015 {
            slices[slices.count - 1].duration = min(sourceTime - last.sourceStart,
                                                  outputTime - last.outputStart)
        } else {
            slices.append(StudioSourceAudioSlice(url: url, sourceStart: previous.source,
                                                 outputStart: previous.output, duration: length))
        }
    }
}

enum RecordingDraftError: LocalizedError {
    case missingMicrophone, invalidVideo, cannotExportAudio
    var errorDescription: String? {
        switch self {
        case .missingMicrophone: "No microphone audio was captured. Check microphone access and record again."
        case .invalidVideo: "The recorded video couldn’t be opened."
        case .cannotExportAudio: "The original clip audio couldn’t be prepared. Your microphone recording has been kept."
        }
    }
}

enum RecordingAudioComposer {
    static func makeDraft(captureURL: URL, duration: TimeInterval, title: String,
                          sourceAudio: [StudioSourceAudioSlice], microphoneRequired: Bool,
                          directory: URL? = nil) async throws -> RecordingDraft {
        let id = UUID()
        let folder = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Drafts", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let videoURL = folder.appendingPathComponent("capture.mov")
        try FileManager.default.copyItem(at: captureURL, to: videoURL)
        let captured = AVURLAsset(url: videoURL)
        defer { withExtendedLifetime(captured) {} }
        guard !(try await captured.loadTracks(withMediaType: .video)).isEmpty,
              duration.isFinite, duration > 0 else { throw RecordingDraftError.invalidVideo }
        let microphone = try await captured.loadTracks(withMediaType: .audio).first
        let microphoneRange = try await microphone?.load(.timeRange)
        let hasMicrophone = microphoneRange.map { $0.duration.seconds.isFinite && $0.duration.seconds > 0 } ?? false
        guard !microphoneRequired || hasMicrophone else { throw RecordingDraftError.missingMicrophone }
        let stemURL = folder.appendingPathComponent("source.m4a")
        let sourceURL = try await exportSourceAudio(sourceAudio, duration: duration, to: stemURL)
        let draft = RecordingDraft(id: id, videoURL: videoURL,
                                   microphoneURL: hasMicrophone ? videoURL : nil,
                                   sourceAudioURL: sourceURL, duration: duration, title: title)
        try JSONEncoder().encode(draft).write(to: folder.appendingPathComponent("draft.json"), options: .atomic)
        return draft
    }

    static func exportSourceAudio(_ slices: [StudioSourceAudioSlice], duration: TimeInterval,
                                  to destination: URL) async throws -> URL? {
        guard !slices.isEmpty else { return nil }
        let composition = AVMutableComposition()
        guard let output = composition.addMutableTrack(withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { throw RecordingDraftError.cannotExportAudio }
        var assets: [URL: AVURLAsset] = [:]
        defer { withExtendedLifetime(assets) {} }
        var tracks: [URL: AVAssetTrack] = [:]
        var withoutAudio: Set<URL> = []
        var lastEnd = 0.0
        var inserted = false
        for slice in slices.sorted(by: { $0.outputStart < $1.outputStart }) {
            guard slice.sourceStart.isFinite, slice.outputStart.isFinite, slice.duration.isFinite,
                  slice.duration > 0 else { continue }
            if assets[slice.url] == nil {
                let asset = AVURLAsset(url: slice.url)
                assets[slice.url] = asset
                if let track = try await asset.loadTracks(withMediaType: .audio).first { tracks[slice.url] = track }
                else { withoutAudio.insert(slice.url) }
            }
            if withoutAudio.contains(slice.url) { continue }
            guard let track = tracks[slice.url] else { continue }
            let available = try await track.load(.timeRange)
            let initialOutput = max(0, max(slice.outputStart, lastEnd))
            let initialSource = slice.sourceStart + initialOutput - slice.outputStart
            let start = max(initialSource, available.start.seconds)
            let outputStart = initialOutput + start - initialSource
            let length = min(slice.duration - (outputStart - slice.outputStart),
                             min(available.end.seconds - start, duration - outputStart))
            guard length > 0.0001 else { continue }
            try output.insertTimeRange(CMTimeRange(start: time(start), duration: time(length)),
                                       of: track, at: time(outputStart))
            lastEnd = outputStart + length
            inserted = true
        }
        guard inserted else { return nil }
        // Empty trailing edits are trimmed by the M4A exporter. Real zero-valued
        // samples keep pauses and the held-last-frame tail aligned with the take.
        let silenceURL = destination.deletingLastPathComponent()
            .appendingPathComponent("padding-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: silenceURL) }
        try writeSilence(duration: duration, to: silenceURL)
        let paddingAsset = AVURLAsset(url: silenceURL)
        assets[silenceURL] = paddingAsset
        guard let paddingSource = try await paddingAsset.loadTracks(withMediaType: .audio).first,
              let padding = composition.addMutableTrack(withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { throw RecordingDraftError.cannotExportAudio }
        try padding.insertTimeRange(CMTimeRange(start: .zero, duration: time(duration)), of: paddingSource, at: .zero)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecordingDraftError.cannotExportAudio
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [output, padding].map { track in
            let input = AVMutableAudioMixInputParameters(track: track)
            input.setVolume(1, at: .zero)
            return input
        }
        exporter.audioMix = mix
        exporter.timeRange = CMTimeRange(start: .zero, duration: time(duration))
        try await exporter.export(to: destination, as: .m4a)
        return destination
    }

    /// Compatibility export; the editor independently selects/mixes these stems.
    static func exportMixed(_ draft: RecordingDraft, to destination: URL,
                            microphoneGain: Float = 0.6, sourceGain: Float = 0.75) async throws -> URL {
        let composition = AVMutableComposition()
        let captured = AVURLAsset(url: draft.videoURL)
        var retainedAssets: [AVAsset] = [captured]
        // AVAssetTrack.asset is weak; temporary URL assets can disappear across
        // awaits and make the exporter fail or omit an intended audio source.
        defer { withExtendedLifetime(retainedAssets) {} }
        guard let sourceVideo = try await captured.loadTracks(withMediaType: .video).first,
              let video = composition.addMutableTrack(withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { throw RecordingDraftError.invalidVideo }
        let requested = CMTimeRange(start: .zero, duration: time(draft.duration))
        let videoRange = CMTimeRangeGetIntersection(requested, otherRange: try await sourceVideo.load(.timeRange))
        try video.insertTimeRange(videoRange, of: sourceVideo, at: videoRange.start)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        var parameters: [AVMutableAudioMixInputParameters] = []
        for (url, gain) in [(draft.microphoneURL, microphoneGain), (draft.sourceAudioURL, sourceGain)] {
            guard let url else { continue }
            let asset = AVURLAsset(url: url)
            retainedAssets.append(asset)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let range = CMTimeRangeGetIntersection(requested, otherRange: try await source.load(.timeRange))
            guard range.duration.seconds > 0 else { continue }
            try track.insertTimeRange(range, of: source, at: range.start)
            let input = AVMutableAudioMixInputParameters(track: track)
            input.setVolume(max(0, min(1, gain)), at: .zero)
            parameters.append(input)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        guard let exporter = AVAssetExportSession(asset: composition,
                presetName: AVAssetExportPresetHighestQuality) else { throw RecordingDraftError.invalidVideo }
        exporter.audioMix = mix
        exporter.timeRange = requested
        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.export(to: destination, as: .mp4)
        return destination
    }

    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }

    private static func writeSilence(duration: Double, to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let data = buffer.floatChannelData else { throw RecordingDraftError.cannotExportAudio }
        data[0].initialize(repeating: 0, count: 4096)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        var remaining = Int64((duration * 48_000).rounded(.up))
        while remaining > 0 {
            buffer.frameLength = AVAudioFrameCount(min(remaining, 4096))
            try file.write(from: buffer)
            remaining -= Int64(buffer.frameLength)
        }
    }
}
