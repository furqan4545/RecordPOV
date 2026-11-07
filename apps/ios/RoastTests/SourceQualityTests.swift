import AVFoundation
import CoreImage
import CoreVideo
import UIKit
import XCTest
@testable import Roast

final class SourceQualityTests: XCTestCase {
    func test1080p60MuxedSourceRetainsResolutionFrameRateAndOriginalBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SourceQuality-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.mp4")
        try await write1080p60Video(to: source)
        let originalAsset = AVURLAsset(url: source)
        defer { withExtendedLifetime(originalAsset) {} }
        let originalTracks = try await originalAsset.loadTracks(withMediaType: .video)
        let originalTrack = try XCTUnwrap(originalTracks.first)
        let originalSize = try await originalTrack.load(.naturalSize)
        let originalFPS = try await originalTrack.load(.nominalFrameRate)
        XCTAssertEqual(originalSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(originalFPS, 60, accuracy: 0.01, "The fixture must actually exercise the formerly rejected 60fps path")
        let media = try manifest()
        let result = try await DirectVideoPreparer.prepare(media, assets: try XCTUnwrap(media.delivery?.assets),
            files: [source], directory: root.appendingPathComponent("ready", isDirectory: true))
        XCTAssertEqual(try Data(contentsOf: result), try Data(contentsOf: source),
                       "Opening a compatible high-quality source must preserve its compressed bytes")
        let output = AVURLAsset(url: result)
        defer { withExtendedLifetime(output) {} }
        let tracks = try await output.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let fps = try await track.load(.nominalFrameRate)
        let descriptions = try await track.load(.formatDescriptions)
        let audio = try await output.loadTracks(withMediaType: .audio)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(fps, 60, accuracy: 0.01)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(descriptions.first)), kCMVideoCodecType_H264)
        XCTAssertTrue(audio.isEmpty)
    }

    func testStudioPreviewUsesFull720By1280Composite() async throws {
        let pipeline = StudioFramePipeline()
        let source = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 720, height: 1280))
        let result: StudioRenderResult = await withCheckedContinuation { continuation in
            pipeline.render(StudioRenderRequest(source: source, pip: PiPTransform(), cameraEnabled: false,
                recordingTime: nil)) { continuation.resume(returning: $0) }
        }
        let image = try XCTUnwrap(result.image?.cgImage)
        XCTAssertEqual(image.width, 720, "Studio must not halve the preview width to 360 pixels")
        XCTAssertEqual(image.height, 1280, "Studio must not halve the preview height to 640 pixels")
        XCTAssertFalse(result.cameraPresent)
    }

    private func manifest() throws -> ResolvedMedia {
        let payload: [String: Any] = [
            "id": "0123456789abcdef01234567", "title": "1080p60 fixture",
            "sourceUrl": "https://x.com/example/status/123456789", "platform": "x",
            "expiresAt": ISO8601DateFormatter().string(from: .now.addingTimeInterval(240)),
            "delivery": ["kind": "direct", "assets": [["role": "muxed",
                "url": "https://video.twimg.com/high-quality.mp4", "headers": [:]]],
                "expected": ["duration": 0.2, "width": 1920, "height": 1080, "hasAudio": false],
                "maxBytes": 10_000_000]
        ]
        return try JSONDecoder().decode(ResolvedMedia.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func write1080p60Video(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoAverageBitRateKey: 8_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080
        ])
        guard writer.canAdd(input) else { throw FixtureError.writer }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.writer }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let pixels = buffer else { throw FixtureError.writer }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) { memset(base, 100, CVPixelBufferGetDataSize(pixels)) }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<12 {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw writer.error ?? FixtureError.writer }
                try await Task.sleep(for: .milliseconds(1))
            }
            guard adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 60)) else {
                throw writer.error ?? FixtureError.writer
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 12, timescale: 60))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FixtureError.writer }
    }

    private enum FixtureError: Error { case writer }
}
