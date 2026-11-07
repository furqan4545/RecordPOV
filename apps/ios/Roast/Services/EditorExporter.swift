import AVFoundation
import CoreImage
import CoreText
import Foundation

struct EditorComposition {
    let asset: AVMutableComposition
    let audioMix: AVAudioMix
    let videoComposition: AVVideoComposition?
    let timeline: EditorTimeline
    let retainedAssets: [AVURLAsset]

    func playerItem() -> AVPlayerItem {
        let item = EditorPlayerItem(asset: asset, retaining: retainedAssets)
        item.audioMix = audioMix
        item.videoComposition = videoComposition
        return item
    }
}

private final class EditorPlayerItem: AVPlayerItem {
    private let sourceAssets: [AVURLAsset]
    init(asset: AVAsset, retaining sourceAssets: [AVURLAsset]) {
        self.sourceAssets = sourceAssets
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)
    }
}

@MainActor
enum EditorExporter {
    static func composition(draft: RecordingDraft, edits: TakeEdits) async throws -> EditorComposition {
        // Loading and inserting compressed tracks may perform synchronous media
        // work. Keep that assembly off the editor's UI actor, with ownership and
        // cancellation transferred back only after the complete result is ready.
        let preparation = Task.detached(priority: .userInitiated) {
            try await assembleComposition(draft: draft, edits: edits)
        }
        return try await withTaskCancellationHandler {
            let result = try await preparation.value
            try Task.checkCancellation()
            return result
        } onCancel: { preparation.cancel() }
    }

    nonisolated private static func assembleComposition(draft: RecordingDraft, edits: TakeEdits) async throws -> EditorComposition {
        try Task.checkCancellation()
        let captured = AVURLAsset(url: draft.videoURL)
        var retainedAssets = [captured]
        guard let originalVideo = try await captured.loadTracks(withMediaType: .video).first else {
            throw EditorError.noVideo
        }
        let videoRange = try await originalVideo.load(.timeRange)
        let duration = min(draft.duration, videoRange.end.seconds)
        var boundedEdits = edits
        boundedEdits.trimStart = max(edits.trimStart, videoRange.start.seconds)
        let timeline = EditorTimeline(duration: duration, edits: boundedEdits)
        guard timeline.duration >= 0.04 else { throw EditorError.emptyEdit }
        let asset = AVMutableComposition()
        guard let video = asset.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw EditorError.noVideo
        }
        video.preferredTransform = try await originalVideo.load(.preferredTransform)
        for segment in timeline.segments {
            try Task.checkCancellation()
            try video.insertTimeRange(timeRange(segment.sourceStart, segment.duration), of: originalVideo,
                                      at: time(segment.outputStart))
        }

        // Never copy capture.mov's audio implicitly. Only explicit isolated stems
        // enter the mix, so original-video sound cannot be counted as microphone.
        var inputs: [AVMutableAudioMixInputParameters] = []
        let microphoneURL: URL?
        if edits.voiceCleanupEnabled == true, let raw = draft.microphoneURL {
            microphoneURL = try await VoiceCleanup.process(microphoneURL: raw)
        } else { microphoneURL = draft.microphoneURL }
        try await addStem(microphoneURL, gain: edits.microphoneVolume, timeline: timeline, to: asset,
                          inputs: &inputs, retainedAssets: &retainedAssets)
        try await addStem(draft.sourceAudioURL, gain: edits.sourceVolume, timeline: timeline, to: asset,
                          inputs: &inputs, retainedAssets: &retainedAssets)
        if let music = edits.musicURL {
            try await addMusic(music, gain: edits.musicVolume, duration: timeline.duration, to: asset,
                               inputs: &inputs, retainedAssets: &retainedAssets)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = inputs
        let captions = edits.captionsEnabled ? timeline.remap(edits.captions) : []
        let videoComposition: AVVideoComposition?
        if captions.isEmpty {
            videoComposition = nil
        } else {
            let rasterizer = CaptionRasterizer()
            // CI composition works in both AVPlayer and AVAssetExportSession.
            // A CoreAnimationTool would burn captions offline but fail in preview.
            videoComposition = try await AVVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
                let source = request.sourceImage
                let seconds = request.compositionTime.seconds
                guard let caption = captions.first(where: { seconds >= $0.start && seconds < $0.end }),
                      let overlay = rasterizer.image(text: caption.text, videoWidth: source.extent.width) else {
                    request.finish(with: source, context: nil)
                    return
                }
                let x = source.extent.midX - overlay.extent.width / 2
                let y = source.extent.minY + source.extent.height * 0.12
                let result = overlay.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: source)
                request.finish(with: result.cropped(to: source.extent), context: nil)
            })
        }
        return EditorComposition(asset: asset, audioMix: mix, videoComposition: videoComposition,
                                 timeline: timeline, retainedAssets: retainedAssets)
    }

    static func export(draft: RecordingDraft, edits: TakeEdits) async throws -> URL {
        let composed = try await composition(draft: draft, edits: edits)
        defer { withExtendedLifetime(composed.retainedAssets) {} }
        guard let exporter = AVAssetExportSession(asset: composed.asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw EditorError.exportUnavailable
        }
        let destination = draft.videoURL.deletingLastPathComponent()
            .appendingPathComponent("edited-\(UUID()).mp4")
        exporter.audioMix = composed.audioMix
        exporter.videoComposition = composed.videoComposition
        exporter.shouldOptimizeForNetworkUse = true
        do {
            try await withTaskCancellationHandler {
                try await exporter.export(to: destination, as: .mp4)
            } onCancel: { exporter.cancelExport() }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if Task.isCancelled { throw CancellationError() }
            throw EditorError.exportUnavailable
        }
    }

    nonisolated private static func addStem(_ url: URL?, gain: Double, timeline: EditorTimeline,
                                to asset: AVMutableComposition,
                                inputs: inout [AVMutableAudioMixInputParameters],
                                retainedAssets: inout [AVURLAsset]) async throws {
        guard let url else { return }
        let source = AVURLAsset(url: url)
        retainedAssets.append(source)
        guard let audio = try await source.loadTracks(withMediaType: .audio).first,
              let track = asset.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw EditorError.unreadableAudio
        }
        let available = try await audio.load(.timeRange)
        for segment in timeline.segments {
            try Task.checkCancellation()
            let start = max(segment.sourceStart, available.start.seconds)
            let end = min(segment.sourceEnd, available.end.seconds)
            guard end > start else { continue }
            try track.insertTimeRange(timeRange(start, end - start), of: audio,
                                      at: time(segment.outputStart + start - segment.sourceStart))
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.setVolume(volume(gain), at: .zero)
        inputs.append(parameters)
    }

    nonisolated private static func addMusic(_ url: URL, gain: Double, duration: Double,
                                 to asset: AVMutableComposition,
                                 inputs: inout [AVMutableAudioMixInputParameters],
                                 retainedAssets: inout [AVURLAsset]) async throws {
        let source = AVURLAsset(url: url)
        retainedAssets.append(source)
        guard let audio = try await source.loadTracks(withMediaType: .audio).first,
              let track = asset.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw EditorError.invalidMusic
        }
        let available = try await audio.load(.timeRange)
        guard available.duration.seconds.isFinite, available.duration.seconds >= 0.25 else { throw EditorError.invalidMusic }
        var cursor = 0.0
        while cursor < duration - 0.0001 {
            try Task.checkCancellation()
            let length = min(available.duration.seconds, duration - cursor)
            try track.insertTimeRange(timeRange(available.start.seconds, length), of: audio, at: time(cursor))
            cursor += length
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.setVolume(volume(gain), at: .zero)
        inputs.append(parameters)
    }

    nonisolated private static func volume(_ value: Double) -> Float { Float(value.isFinite ? min(2, max(0, value)) : 0) }
    nonisolated private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }
    nonisolated private static func timeRange(_ start: Double, _ duration: Double) -> CMTimeRange {
        CMTimeRange(start: time(start), duration: time(duration))
    }
}

enum EditorMusicImporter {
    static func copy(_ source: URL, for draft: RecordingDraft) async throws -> URL {
        let target = draft.videoURL.deletingLastPathComponent()
            .appendingPathComponent("music-\(UUID())")
            .appendingPathExtension(source.pathExtension.isEmpty ? "m4a" : source.pathExtension)
        try await Task.detached(priority: .userInitiated) {
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var copyError: Error?
            coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
                do { try FileManager.default.copyItem(at: readable, to: target) }
                catch { copyError = error }
            }
            if let error = coordinationError ?? copyError { throw error }
        }.value
        do {
            let asset = AVURLAsset(url: target)
            defer { withExtendedLifetime(asset) {} }
            guard let audio = try await asset.loadTracks(withMediaType: .audio).first,
                  try await audio.load(.timeRange).duration.seconds >= 0.25 else { throw EditorError.invalidMusic }
            return target
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw EditorError.invalidMusic
        }
    }
}

/// Bounded, thread-safe text raster cache. No full-frame bitmap per caption and
/// no UIKit drawing or main-thread round trips in the video rendering callback.
private final class CaptionRasterizer: @unchecked Sendable {
    private let cache = NSCache<NSString, CaptionBitmap>()
    init() { cache.totalCostLimit = 8 * 1024 * 1024 }

    func image(text: String, videoWidth: CGFloat) -> CIImage? {
        let text = String(text.prefix(240))
        let width = Int(max(120, videoWidth * 0.84))
        let key = "\(width):\(text)" as NSString
        if let cached = cache.object(forKey: key) { return CIImage(cgImage: cached.image) }
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, max(18, videoWidth * 0.048), nil)
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let padding = max(10, videoWidth * 0.018)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil,
            CGSize(width: CGFloat(width) - padding * 2, height: .greatestFiniteMagnitude), nil)
        let height = Int(ceil(min(measured.height, videoWidth * 0.30) + padding * 2))
        guard let context = CGContext(data: nil, width: width, height: max(1, height), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 0, alpha: 0.72))
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.fillPath()
        let textBounds = bounds.insetBy(dx: padding, dy: padding)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: textBounds, transform: nil), nil)
        CTFrameDraw(frame, context)
        guard let bitmap = context.makeImage() else { return nil }
        cache.setObject(CaptionBitmap(bitmap), forKey: key, cost: width * height * 4)
        return CIImage(cgImage: bitmap)
    }
}

private final class CaptionBitmap: NSObject {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
