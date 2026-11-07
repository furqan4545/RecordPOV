import XCTest
@testable import Roast

final class HybridImportTests: XCTestCase {
    // MARK: ImportPlan

    func testDirectlyPlayablePrimaryIsDownloadedWithoutConversion() throws {
        let media = try manifest(codec: "h264", convert: false)
        XCTAssertEqual(ImportPlan.choose(media.delivery, capabilities: phone(decodes: [])), .primary)
    }
    func testUnknownCodecIsDecidedAfterDownload() throws {
        for codec: String? in ["unknown", nil] {
            let media = try manifest(codec: codec, convert: false)
            XCTAssertEqual(ImportPlan.choose(media.delivery, capabilities: phone(decodes: [], supplemental: false)), .primary)
        }
    }
    func testDecodableOriginalIsDownloadedForConversion() throws {
        for codec in ["vp9", "av1", "hevc"] {
            let media = try manifest(codec: codec, convert: true, fallback: true)
            XCTAssertEqual(ImportPlan.choose(media.delivery, capabilities: phone(decodes: [.vp9, .av1, .hevc])), .primary, codec)
        }
    }
    func testUndecodableOriginalUsesTheFallback() throws {
        let media = try manifest(codec: "vp9", convert: true, fallback: true)
        XCTAssertEqual(ImportPlan.choose(media.delivery, capabilities: phone(decodes: [.hevc], supplemental: false)), .fallback)
        XCTAssertEqual(ImportPlan.choose(media.delivery, capabilities: phone(decodes: [.hevc], supplemental: true)), .fallback)
    }
    func testVP9OrAV1WithoutFallbackBeforeIOS262AsksForAnUpdate() throws {
        for codec in ["vp9", "av1"] {
            let media = try manifest(codec: codec, convert: true)
            XCTAssertEqual(ImportPlan.choose(media.delivery, capabilities: phone(decodes: [], supplemental: false)),
                           .unsupported("This video needs iOS 26.2 or later. Update iOS and try again."), codec)
        }
    }
    func testOtherUndecodableOriginalsWithoutFallbackAreUnsupported() throws {
        let vp9 = try manifest(codec: "vp9", convert: true)
        XCTAssertEqual(ImportPlan.choose(vp9.delivery, capabilities: phone(decodes: [], supplemental: true)),
                       .unsupported(ImportPlan.unsupportedFormatMessage))
        let hevc = try manifest(codec: "hevc", convert: true)
        XCTAssertEqual(ImportPlan.choose(hevc.delivery, capabilities: phone(decodes: [], supplemental: false)),
                       .unsupported(ImportPlan.unsupportedFormatMessage))
    }
    func testH264IsAlwaysDecodable() {
        XCTAssertTrue(phone(decodes: []).canDecode(.h264))
        XCTAssertFalse(phone(decodes: []).canDecode(.vp9))
    }
    func testPlanSurvivesTheJournal() throws {
        for plan in [ImportPlan.primary, .fallback, .unsupported("x")] {
            XCTAssertEqual(try JSONDecoder().decode(ImportPlan.self, from: JSONEncoder().encode(plan)), plan)
        }
    }

    // MARK: Manifest decoding

    func testManifestWithoutHybridFieldsStillDecodes() throws {
        let media = try manifest(codec: nil, convert: nil)
        let delivery = try XCTUnwrap(media.delivery)
        XCTAssertNil(delivery.convert)
        XCTAssertNil(delivery.fallback)
        XCTAssertNil(delivery.expected?.fps)
        XCTAssertNil(delivery.expected?.videoCodec)
        XCTAssertNil(delivery.expected?.audioCodec)
        XCTAssertNoThrow(try DirectMediaPolicy.validate(media))
    }
    func testHybridManifestDecodesConvertFallbackAndCodecs() throws {
        let media = try manifest(codec: "vp9", convert: true, fallback: true, fps: 30, audioCodec: "he-aac")
        let delivery = try XCTUnwrap(media.delivery)
        XCTAssertEqual(delivery.convert, true)
        XCTAssertEqual(delivery.expected?.fps, 30)
        XCTAssertEqual(delivery.expected?.videoCodec, "vp9")
        XCTAssertEqual(delivery.expected?.audioCodec, "he-aac")
        let fallback = try XCTUnwrap(delivery.fallback)
        XCTAssertEqual(fallback.assets.map(\.role), ["video", "audio"])
        XCTAssertEqual(fallback.expected.videoCodec, "h264")
        XCTAssertEqual(fallback.expected.audioCodec, "aac-lc")
        XCTAssertEqual(fallback.expected.width, 720)
        XCTAssertEqual(SourceVideoCodec(manifest: delivery.expected?.videoCodec), .vp9)
        XCTAssertEqual(SourceVideoCodec(manifest: "mpeg4"), .unknown)
    }

    // MARK: Bitrate

    func testConvertedBitrateFollowsTheSourceWithinClamps() {
        // 1080x1920 VP9 at 4 Mbps -> 6.4 Mbps.
        XCTAssertEqual(OnDeviceConverter.targetBitrate(sourceBitsPerSecond: 4_000_000, codec: .vp9, width: 1080, height: 1920), 6_400_000)
        XCTAssertEqual(OnDeviceConverter.targetBitrate(sourceBitsPerSecond: 4_000_000, codec: .av1, width: 1920, height: 1080), 6_400_000)
        XCTAssertEqual(OnDeviceConverter.targetBitrate(sourceBitsPerSecond: 4_000_000, codec: .hevc, width: 1080, height: 1920), 5_200_000)
        // Clamped per raster tier.
        XCTAssertEqual(OnDeviceConverter.targetBitrate(sourceBitsPerSecond: 100_000, codec: .vp9, width: 720, height: 1280), 1_500_000)
        XCTAssertEqual(OnDeviceConverter.targetBitrate(sourceBitsPerSecond: 20_000_000, codec: .vp9, width: 720, height: 1280), 8_000_000)
        XCTAssertEqual(OnDeviceConverter.targetBitrate(sourceBitsPerSecond: 0, codec: .vp9, width: 1080, height: 1920), 3_000_000)
        XCTAssertEqual(OnDeviceConverter.targetBitrate(sourceBitsPerSecond: 50_000_000, codec: .av1, width: 1080, height: 1920), 12_000_000)
        XCTAssertEqual(OnDeviceConverter.targetBitrate(sourceBitsPerSecond: 1_000_000, codec: .av1, width: 3840, height: 2160), 12_000_000)
        XCTAssertEqual(OnDeviceConverter.targetBitrate(sourceBitsPerSecond: 30_000_000, codec: .av1, width: 2160, height: 3840), 40_000_000)
        XCTAssertEqual(OnDeviceConverter.targetBitrate(sourceBitsPerSecond: .nan, codec: .hevc, width: 2560, height: 1440), 12_000_000)
    }

    // MARK: Fallback validation

    func testValidFallbackPasses() throws {
        XCTAssertNoThrow(try DirectMediaPolicy.validate(manifest(codec: "vp9", convert: true, fallback: true)))
    }
    func testFallbackFollowsTheSameRulesAsThePrimary() throws {
        let bad: [[String: Any]] = [
            fallbackPayload(url: "https://cdninstagram.com.evil.test/video.mp4"),
            fallbackPayload(headers: ["Cookie": "secret"]),
            fallbackPayload(roles: ["video"]),
            fallbackPayload(roles: ["muxed", "audio"]),
            fallbackPayload(hasAudio: false),
            fallbackPayload(width: 4096, height: 2304),
            fallbackPayload(duration: 3601)
        ]
        for fallback in bad {
            XCTAssertThrowsError(try DirectMediaPolicy.validate(manifest(codec: "vp9", convert: true, fallback: true, fallbackOverride: fallback)), "\(fallback)")
        }
    }

    // MARK: Fixtures

    private func phone(decodes: Set<SourceVideoCodec>, supplemental: Bool = true) -> VideoDecodeCapabilities {
        VideoDecodeCapabilities(supplementalDecodersAvailable: supplemental, decodes: { decodes.contains($0) })
    }
    private func fallbackPayload(url: String = "https://scontent.cdninstagram.com/v/fallback.mp4", headers: [String: String] = [:],
                                 roles: [String] = ["video", "audio"], hasAudio: Bool = true,
                                 width: Int = 720, height: Int = 1280, duration: Double = 12) -> [String: Any] {
        ["assets": roles.map { ["role": $0, "url": $0 == "audio" ? "https://scontent.cdninstagram.com/v/audio.m4a" : url, "headers": headers] },
         "expected": ["duration": duration, "width": width, "height": height, "hasAudio": hasAudio,
                      "videoCodec": "h264", "audioCodec": "aac-lc"]]
    }
    private func manifest(codec: String?, convert: Bool?, fallback: Bool = false, fps: Double? = nil, audioCodec: String? = nil,
                          fallbackOverride: [String: Any]? = nil) throws -> ResolvedMedia {
        var expected: [String: Any] = ["duration": 12, "width": 1080, "height": 1920, "hasAudio": true]
        if let codec { expected["videoCodec"] = codec }
        if let fps { expected["fps"] = fps }
        if let audioCodec { expected["audioCodec"] = audioCodec }
        var delivery: [String: Any] = [
            "kind": "direct", "expected": expected, "maxBytes": 2 * 1024 * 1024 * 1024,
            "assets": [["role": "video", "url": "https://scontent.cdninstagram.com/v/video.mp4", "headers": [String: String]()],
                       ["role": "audio", "url": "https://scontent.cdninstagram.com/v/audio.m4a", "headers": [String: String]()]]
        ]
        if let convert { delivery["convert"] = convert }
        if fallback { delivery["fallback"] = fallbackOverride ?? fallbackPayload() }
        let payload: [String: Any] = ["id": "0123456789abcdef01234567", "title": "Reel", "sourceUrl": "https://www.instagram.com/reel/abc/",
            "platform": "instagram", "expiresAt": ISO8601DateFormatter().string(from: .now.addingTimeInterval(240)), "delivery": delivery]
        return try JSONDecoder().decode(ResolvedMedia.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}
