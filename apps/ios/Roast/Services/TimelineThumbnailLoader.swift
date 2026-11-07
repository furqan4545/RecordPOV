import AVFoundation
import UIKit

@MainActor
final class TimelineThumbnailLoader {
    static let shared = TimelineThumbnailLoader()
    private let images = NSCache<NSString, UIImage>()
    private var generating = 0

    private init() {
        images.totalCostLimit = 12 * 1024 * 1024
        images.countLimit = 180
    }

    /// Local-file frames only, with bounded decoding and no disk thumbnail cache.
    func thumbnail(videoURL: URL, at seconds: Double) async -> UIImage? {
        guard videoURL.isFileURL, seconds.isFinite else { return nil }
        let seconds = max(0, (seconds * 10).rounded() / 10)
        let key = "\(videoURL.standardizedFileURL.path)#\(seconds)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        do {
            while generating >= 4 {
                try await Task.sleep(for: .milliseconds(12))
            }
            try Task.checkCancellation()
            if let cached = images.object(forKey: key) { return cached }
            generating += 1
            defer { generating -= 1 }
            let asset = AVURLAsset(url: videoURL)
            defer { withExtendedLifetime(asset) {} }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 128, height: 192)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
            let result = try await withTaskCancellationHandler {
                try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            } onCancel: { generator.cancelAllCGImageGeneration() }
            try Task.checkCancellation()
            let image = UIImage(cgImage: result.image)
            images.setObject(image, forKey: key, cost: result.image.bytesPerRow * result.image.height)
            return image
        } catch { return nil }
    }
}
