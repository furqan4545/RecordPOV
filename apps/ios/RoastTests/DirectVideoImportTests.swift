import AVFoundation
import XCTest
@testable import Roast

final class DirectVideoImportTests: XCTestCase {
    func testCDNDestinationsRejectCredentialsPortsAndLookalikeHosts() {
        XCTAssertTrue(DirectMediaPolicy.allows(URL(string: "https://scontent.cdninstagram.com/v/video.mp4?token=private")!, platform: "instagram"))
        XCTAssertTrue(DirectMediaPolicy.allows(URL(string: "https://rr1---sn.test.googlevideo.com/videoplayback?expire=1")!, platform: "youtube"))
        for raw in ["https://cdninstagram.com.evil.test/video", "http://cdninstagram.com/video", "https://user:secret@cdninstagram.com/video", "https://cdninstagram.com:8443/video", "https://127.0.0.1/video", "https://cdninstagram.com/video#fragment"] {
            XCTAssertFalse(DirectMediaPolicy.allows(URL(string: raw)!, platform: "instagram"), raw)
        }
        XCTAssertFalse(DirectMediaPolicy.allows(URL(string: "https://evil.twimg.com/video")!, platform: "x"))
        XCTAssertFalse(DirectMediaPolicy.allows(URL(string: "https://www.tiktok.com/video")!, platform: "tiktok"))
    }
    func testPrivilegedHeadersNeverBecomeCDNRequests() throws {
        let url = URL(string: "https://video.twimg.com/a.mp4")!
        for name in ["Authorization", "Cookie", "Host", "X-YouTube-Session-Token", "Proxy-Authorization"] {
            XCTAssertThrowsError(try DirectMediaPolicy.request(.init(role: "muxed", url: url, headers: [name: "secret"]), platform: "x"))
        }
        XCTAssertThrowsError(try DirectMediaPolicy.request(.init(role: "muxed", url: url, headers: ["User-Agent": "bad\r\nCookie: x"]), platform: "x"))
        let request = try DirectMediaPolicy.request(.init(role: "muxed", url: url, headers: ["User-Agent": "RecordPOV", "Referer": "https://x.com/"]), platform: "x")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://x.com/")
    }
    func testPreparedFilesStayOnConfiguredOriginAndExactMediaPath() {
        let base = URL(string: "https://api.recordpov.app")!
        XCTAssertTrue(DirectMediaPolicy.serviceFile(URL(string: "https://api.recordpov.app/v1/media/0123456789abcdef01234567/file")!, base: base))
        for raw in ["https://evil.test/v1/media/0123456789abcdef01234567/file", "https://api.recordpov.app/health", "https://api.recordpov.app/v1/media/0123456789abcdef01234567/file?redirect=1", "http://api.recordpov.app/v1/media/0123456789abcdef01234567/file"] {
            XCTAssertFalse(DirectMediaPolicy.serviceFile(URL(string: raw)!, base: base))
        }
    }
    func testMuxedSilentImportCopiesVideoAndRetainsDuration() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        try await AudioSignalFixtures.writeVideo(to: source, duration: 0.6)
        let media = try manifest(hasAudio: false)
        let result = try await DirectVideoPreparer.prepare(media, assets: media.delivery!.assets!, files: [source], directory: root.appendingPathComponent("ready"))
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: result), "A compatible muxed video should not be encoded again")
        let output = AVURLAsset(url: result)
        let duration = try await output.load(.duration).seconds
        let audio = try await output.loadTracks(withMediaType: .audio)
        XCTAssertEqual(duration, 0.6, accuracy: 0.04)
        XCTAssertTrue(audio.isEmpty)
    }
    func testSplitImportMuxesAACWithoutLosingTheVoiceOrChangingVideoDuration() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("video.mp4")
        let tone = root.appendingPathComponent("tone.caf")
        let audio = root.appendingPathComponent("audio.m4a")
        try await AudioSignalFixtures.writeVideo(to: video, duration: 0.6)
        try AudioSignalFixtures.writeTone(to: tone, frequency: 440, duration: 0.6)
        let encoder = AVAssetExportSession(asset: AVURLAsset(url: tone), presetName: AVAssetExportPresetAppleM4A)!
        try await encoder.export(to: audio, as: .m4a)
        let media = try manifest(hasAudio: true, split: true)
        let result = try await DirectVideoPreparer.prepare(media, assets: media.delivery!.assets!, files: [video, audio], directory: root.appendingPathComponent("ready"))
        let output = AVURLAsset(url: result)
        let duration = try await output.load(.duration).seconds
        XCTAssertEqual(duration, 0.6, accuracy: 0.05)
        let decoded = try await AudioSignalFixtures.decode(result)
        XCTAssertGreaterThan(decoded.amplitude(at: 440, start: 0.1, duration: 0.3), 0.15)
        let videoTrack = try await output.loadTracks(withMediaType: .video).first!
        let descriptions = try await videoTrack.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(descriptions[0]), kCMVideoCodecType_H264)
    }
    func testMissingOriginalAudioIsRejectedRatherThanSilentlyOpened() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("silent.mp4")
        try await AudioSignalFixtures.writeVideo(to: source, duration: 0.6)
        let media = try manifest(hasAudio: true)
        do {
            _ = try await DirectVideoPreparer.prepare(media, assets: media.delivery!.assets!, files: [source], directory: root.appendingPathComponent("ready"))
            XCTFail("Losing source audio must require fallback")
        } catch { XCTAssertTrue(error is DirectImportError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("ready").path).isEmpty)
    }
    func testTruncatedDurationIsRejectedInsteadOfTrimmingSource() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("short.mp4")
        try await AudioSignalFixtures.writeVideo(to: source, duration: 0.6)
        let media = try manifest(hasAudio: false, duration: 3)
        do {
            _ = try await DirectVideoPreparer.prepare(media, assets: media.delivery!.assets!, files: [source], directory: root.appendingPathComponent("ready"))
            XCTFail("A partial source must require fallback")
        } catch { XCTAssertTrue(error is DirectImportError) }
    }
    func testRoundedPlatformDurationRetainsTheCompleteActualVideo() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("rounded.mp4")
        try await AudioSignalFixtures.writeVideo(to: source, duration: 0.6)
        let media = try manifest(hasAudio: false, duration: 1)
        let result = try await DirectVideoPreparer.prepare(media, assets: media.delivery!.assets!, files: [source], directory: root.appendingPathComponent("ready"))
        let actual = try await AVURLAsset(url: result).load(.duration).seconds
        XCTAssertEqual(actual, 0.6, accuracy: 0.04, "Rounded platform metadata must not trim, extend, or re-encode the real source")
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: result))
    }
    func testExpiredManifestAndMissingSplitAudioAreRejected() throws {
        let media = try manifest(hasAudio: false, split: true, expiry: "2020-01-01T00:00:00Z")
        XCTAssertThrowsError(try DirectMediaPolicy.validate(media))
        let expired = try manifest(hasAudio: false, expiry: "2020-01-01T00:00:00Z")
        XCTAssertThrowsError(try DirectMediaPolicy.validate(expired))
        XCTAssertNoThrow(try DirectMediaPolicy.validate(expired, checkExpiry: false), "An already scheduled background transfer can finish after manifest expiry")
    }
    func testSixtyMinuteTwoGiBManifestIsAcceptedAndLargerOnesAreRejected() throws {
        let twoGiB: Int64 = 2 * 1024 * 1024 * 1024
        XCTAssertEqual(DirectMediaPolicy.maxDuration, 3600)
        XCTAssertEqual(DirectMediaPolicy.byteLimit, twoGiB)
        XCTAssertNoThrow(try DirectMediaPolicy.validate(manifest(hasAudio: true, duration: 3599, maxBytes: twoGiB)))
        XCTAssertNoThrow(try DirectMediaPolicy.validate(manifest(hasAudio: true, duration: 3600, maxBytes: 250 * 1024 * 1024)))
        XCTAssertNoThrow(try DirectMediaPolicy.validate(manifest(hasAudio: true, duration: 900, maxBytes: 250 * 1024 * 1024)))
        XCTAssertThrowsError(try DirectMediaPolicy.validate(manifest(hasAudio: true, duration: 3601, maxBytes: twoGiB)))
        XCTAssertThrowsError(try DirectMediaPolicy.validate(manifest(hasAudio: true, duration: 3599, maxBytes: twoGiB + 1)))
    }
    private func manifest(hasAudio: Bool, split: Bool = false, duration: Double = 0.6, maxBytes: Int64 = 1_000_000,
                          expiry: String = ISO8601DateFormatter().string(from: .now.addingTimeInterval(240))) throws -> ResolvedMedia {
        let assets: [[String: Any]] = (split ? ["video", "audio"] : ["muxed"]).map {
            ["role": $0, "url": "https://video.twimg.com/\($0).mp4", "headers": [:]]
        }
        let payload: [String: Any] = ["id": "0123456789abcdef01234567", "title": "Fixture", "sourceUrl": "https://x.com/example/status/123456789", "platform": "x", "expiresAt": expiry,
            "delivery": ["kind": "direct", "assets": assets, "expected": ["duration": duration, "width": 64, "height": 96, "hasAudio": hasAudio], "maxBytes": maxBytes]]
        return try JSONDecoder().decode(ResolvedMedia.self, from: JSONSerialization.data(withJSONObject: payload))
    }
    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("DirectImport-\(UUID())")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
}
