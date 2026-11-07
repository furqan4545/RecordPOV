import AVFoundation
import CoreMedia
import Foundation

/// Copies compatible compressed samples. No video re-encoding happens here.
enum DirectVideoPreparer {
    private struct Facts {
        let asset: AVURLAsset
        let video: AVAssetTrack?
        let audio: AVAssetTrack?
        let duration: Double
        let width: Int
        let height: Int
    }
    static func prepare(_ media: ResolvedMedia, assets: [DirectMediaAsset], files: [URL],
                        expected chosen: DirectMediaExpectation? = nil, directory: URL? = nil) async throws -> URL {
        guard assets.count == files.count, let expected = chosen ?? media.delivery?.expected,
              let limit = media.delivery?.maxBytes else { throw DirectImportError.invalidDelivery }
        let bytes = try files.reduce(Int64(0)) { result, url in
            result + ((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        guard bytes > 0, bytes <= limit else { throw DirectImportError.tooLarge }
        try Task.checkCancellation()
        let (target, published) = try stagingFiles(directory: directory)
        do {
            if assets.count == 1, assets[0].role == "muxed" {
                let facts = try await inspect(files[0], needsVideo: true)
                try validate(facts, expected: expected)
                try FileManager.default.copyItem(at: files[0], to: target)
            } else {
                guard let videoIndex = assets.firstIndex(where: { $0.role == "video" }),
                      let audioIndex = assets.firstIndex(where: { $0.role == "audio" }) else { throw DirectImportError.invalidDelivery }
                async let videoFacts = inspect(files[videoIndex], needsVideo: true)
                async let audioFacts = inspect(files[audioIndex], needsVideo: false)
                let (video, audio) = try await (videoFacts, audioFacts)
                defer { withExtendedLifetime((video.asset, audio.asset)) {} }
                guard video.audio == nil, audio.video == nil,
                      let videoTrack = video.video, let audioTrack = audio.audio,
                      abs(video.duration - audio.duration) <= max(0.4, video.duration * 0.005) else { throw DirectImportError.incompatible }
                let combined = Facts(asset: video.asset, video: videoTrack, audio: audioTrack,
                                     duration: video.duration, width: video.width, height: video.height)
                try validate(combined, expected: expected)
                // YouTube's DASH pair: copy the samples into one regular MP4 ourselves, which is much
                // faster than the export on the phone. Anything the joiner rejects takes the export below.
                var joined = false
                if isFragmentedMP4(files[videoIndex]), isFragmentedMP4(files[audioIndex]) {
                    do {
                        try FragmentedMP4Joiner.join(video: files[videoIndex], audio: files[audioIndex], to: target)
                        joined = true
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try? FileManager.default.removeItem(at: target)
                    }
                }
                if !joined {
                    let composition = AVMutableComposition()
                    guard let outputVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                          let outputAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw DirectImportError.incompatible }
                    let videoRange = try await videoTrack.load(.timeRange)
                    let audioRange = try await audioTrack.load(.timeRange)
                    let commonStart = CMTimeMinimum(videoRange.start, audioRange.start)
                    try outputVideo.insertTimeRange(videoRange, of: videoTrack, at: CMTimeSubtract(videoRange.start, commonStart))
                    outputVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
                    // Preserve relative source timestamps and all compressed audio samples.
                    try outputAudio.insertTimeRange(audioRange, of: audioTrack, at: CMTimeSubtract(audioRange.start, commonStart))
                    guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw DirectImportError.incompatible }
                    exporter.shouldOptimizeForNetworkUse = true
                    try await withTaskCancellationHandler {
                        try await exporter.export(to: target, as: .mp4)
                    } onCancel: { exporter.cancelExport() }
                }
                let output = try await inspect(target, needsVideo: true)
                try validate(output, expected: expected)
            }
            try Task.checkCancellation()
            _ = try await StudioVideoPreparer.prepare(target)
            try FileManager.default.moveItem(at: target, to: published)
            return published
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }
    /// The staging file and its final name in the folder the studio and library read from.
    static func stagingFiles(directory: URL? = nil) throws -> (target: URL, published: URL) {
        let folder = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SourceVideos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let token = UUID().uuidString
        return (folder.appendingPathComponent(".\(token).importing.mp4"),
                folder.appendingPathComponent(token).appendingPathExtension("mp4"))
    }
    /// True when the downloaded files already meet the H.264 + AAC-LC rules of this preparer.
    static func isDirectlyCompatible(assets: [DirectMediaAsset], files: [URL]) async throws -> Bool {
        guard assets.count == files.count else { return false }
        for (asset, file) in zip(assets, files) {
            do { _ = try await inspect(file, needsVideo: asset.role != "audio") }
            catch is CancellationError { throw CancellationError() }
            catch { return false }
        }
        return true
    }
    /// Validates an on-device conversion with the same rules as a direct copy, then publishes it.
    static func publishConverted(_ target: URL, as published: URL, expected: DirectMediaExpectation) async throws -> URL {
        do {
            let output = try await inspect(target, needsVideo: true)
            try validate(output, expected: expected)
            try Task.checkCancellation()
            _ = try await StudioVideoPreparer.prepare(target)
            try FileManager.default.moveItem(at: target, to: published)
            return published
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }
    /// AAC-LC only: an HE-AAC track can report the plain AAC subtype at its core layer,
    /// so its format list is checked for HE-AAC layers too.
    static func isAACLC(_ description: CMFormatDescription) -> Bool {
        guard CMFormatDescriptionGetMediaSubType(description) == kAudioFormatMPEG4AAC else { return false }
        var size = 0
        guard let list = CMAudioFormatDescriptionGetFormatList(description, sizeOut: &size) else { return true }
        let count = size / MemoryLayout<AudioFormatListItem>.size
        return !(0..<count).contains { [kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2].contains(list[$0].mASBD.mFormatID) }
    }
    private static func validate(_ facts: Facts, expected: DirectMediaExpectation) throws {
        guard facts.video != nil, (facts.audio != nil) == expected.hasAudio,
              facts.width > 0, facts.height > 0, max(facts.width, facts.height) <= 3840, min(facts.width, facts.height) <= 2160 else { throw DirectImportError.incompatible }
        if let width = expected.width, width != facts.width { throw DirectImportError.incompatible }
        if let height = expected.height, height != facts.height { throw DirectImportError.incompatible }
        if let duration = expected.duration, abs(duration - facts.duration) > durationTolerance(duration) { throw DirectImportError.incompatible }
    }
    static func durationTolerance(_ expected: Double) -> Double {
        // Some platforms publish only rounded whole seconds. Keep the entire
        // downloaded source; this tolerance never changes or trims its range.
        max(expected.rounded() == expected ? 1.05 : 0.35, expected * 0.005)
    }
    /// YouTube's DASH files are fragmented MP4 whose moov declares the full duration although it
    /// holds no samples, so AVFoundation counts the length twice. Clearing those declared durations
    /// (mvhd, tkhd, mdhd) in place makes AVFoundation take the length from the fragments.
    /// Returns true when the file is fragmented (and was normalized).
    @discardableResult
    static func normalizeFragmentedMP4(_ file: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { return false }
            var length = header[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            var headerLength: UInt64 = 8
            if length == 1 {
                guard header.count >= 16 else { return false }
                length = header[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                headerLength = 16
            } else if length == 0 { length = fileSize - offset }
            guard length >= headerLength, length <= fileSize - offset else { return false }
            guard String(decoding: header[4..<8], as: UTF8.self) == "moov" else { offset += length; continue }
            guard length - headerLength <= 64 << 20 else { return false }
            try handle.seek(toOffset: offset + headerLength)
            guard var body = try handle.read(upToCount: Int(length - headerLength)) else { return false }
            let moov = Self.boxes(in: body, 0..<body.count)
            guard moov.contains(where: { $0.type == "mvex" }) else { return false }
            // (box start, content start) of every mvhd, tkhd and mdhd; the duration's place depends on the version.
            var headers: [(type: String, content: Int)] = moov.filter { $0.type == "mvhd" }.map { ($0.type, $0.content) }
            for trak in moov where trak.type == "trak" {
                let children = Self.boxes(in: body, trak.content..<trak.end)
                headers += children.filter { $0.type == "tkhd" }.map { ($0.type, $0.content) }
                for mdia in children where mdia.type == "mdia" {
                    headers += Self.boxes(in: body, mdia.content..<mdia.end).filter { $0.type == "mdhd" }.map { ($0.type, $0.content) }
                }
            }
            for (type, content) in headers {
                guard content < body.count else { return false }
                let longForm = body[content] == 1
                let place = content + (type == "tkhd" ? (longForm ? 28 : 20) : (longForm ? 24 : 16))
                let size = longForm ? 8 : 4
                guard place + size <= body.count else { return false }
                body.replaceSubrange(place..<place + size, with: Data(count: size))
            }
            try handle.seek(toOffset: offset + headerLength)
            try handle.write(contentsOf: body)
            return true
        }
        return false
    }
    /// True when the file's moov declares movie fragments (mvex), as YouTube's DASH files do.
    private static func isFragmentedMP4(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file), let fileSize = try? handle.seekToEnd() else { return false }
        defer { try? handle.close() }
        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let header = try? handle.read(upToCount: 16), header.count >= 8 else { return false }
            var length = header[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            var headerLength: UInt64 = 8
            if length == 1 {
                guard header.count >= 16 else { return false }
                length = header[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                headerLength = 16
            } else if length == 0 { length = fileSize - offset }
            guard length >= headerLength, length <= fileSize - offset else { return false }
            guard String(decoding: header[4..<8], as: UTF8.self) == "moov" else { offset += length; continue }
            guard length - headerLength <= 64 << 20, (try? handle.seek(toOffset: offset + headerLength)) != nil,
                  let body = try? handle.read(upToCount: Int(length - headerLength)) else { return false }
            return Self.boxes(in: body, 0..<body.count).contains { $0.type == "mvex" }
        }
        return false
    }
    private static func boxes(in data: Data, _ range: Range<Int>) -> [(type: String, content: Int, end: Int)] {
        var result: [(type: String, content: Int, end: Int)] = []
        var position = range.lowerBound
        while position + 8 <= range.upperBound {
            let length = data[position..<position + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length >= 8, position + length <= range.upperBound else { break }
            result.append((String(decoding: data[position + 4..<position + 8], as: UTF8.self), position + 8, position + length))
            position += length
        }
        return result
    }
    private static func inspect(_ file: URL, needsVideo: Bool) async throws -> Facts {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: file)
        let header = try handle.read(upToCount: 12) ?? Data()
        try handle.close()
        guard header.count >= 12, String(data: header.subdata(in: 4..<8), encoding: .ascii) == "ftyp" else { throw DirectImportError.incompatible }
        let asset = AVURLAsset(url: file)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= DirectMediaPolicy.maxDuration + 0.2, video.count <= 1, audio.count <= 1,
              needsVideo ? video.count == 1 : (video.isEmpty && audio.count == 1) else { throw DirectImportError.incompatible }
        var width = 0, height = 0
        if let track = video.first {
            let descriptions = try await track.load(.formatDescriptions)
            guard !descriptions.isEmpty, descriptions.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }) else { throw DirectImportError.incompatible }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let fps = try await track.load(.nominalFrameRate)
            guard abs(transform.a - 1) < 0.001, abs(transform.d - 1) < 0.001,
                  abs(transform.b) < 0.001, abs(transform.c) < 0.001,
                  fps > 0, fps <= 60.1 else { throw DirectImportError.incompatible }
            width = Int(size.width.rounded()); height = Int(size.height.rounded())
            guard width % 2 == 0, height % 2 == 0 else { throw DirectImportError.incompatible }
        }
        if let track = audio.first {
            let descriptions = try await track.load(.formatDescriptions)
            guard !descriptions.isEmpty else { throw DirectImportError.incompatible }
            for description in descriptions {
                guard isAACLC(description),
                      let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                      (1...2).contains(stream.pointee.mChannelsPerFrame),
                      (8000...48000).contains(stream.pointee.mSampleRate) else { throw DirectImportError.incompatible }
            }
        }
        return Facts(asset: asset, video: video.first, audio: audio.first, duration: duration, width: width, height: height)
    }
}
