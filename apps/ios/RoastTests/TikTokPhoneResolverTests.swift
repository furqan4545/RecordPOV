import Foundation
import XCTest
@testable import Roast

final class TikTokPhoneResolverTests: XCTestCase {
    private let id = "7412345678901234567"
    private let cookie = "msToken=abc; tt_chain_token=def"

    func testH264OnlyPageBecomesADirectlyPlayableManifestWithThePageCookie() throws {
        let html = try page(item(bitrates: [stream("h264", 720, 1280, bitrate: 1_200_000, host: "v19-webapp-prime"),
                                            stream("h264", 540, 960, bitrate: 600_000)]))
        let media = try TikTokPhoneResolver.manifest(page: html, videoID: id, cookie: cookie)
        let delivery = try XCTUnwrap(media.delivery)
        XCTAssertEqual(media.platform, "tiktok")
        XCTAssertEqual(media.qualityVersion, 2)
        XCTAssertEqual(media.title, "A fixture clip")
        XCTAssertEqual(media.duration, 15)
        XCTAssertEqual(media.sourceUrl.absoluteString, "https://www.tiktok.com/@creator/video/\(id)")
        XCTAssertEqual(delivery.kind, "direct")
        XCTAssertEqual(delivery.convert, false)
        XCTAssertNil(delivery.fallback)
        XCTAssertEqual(delivery.maxBytes, DirectMediaPolicy.byteLimit)
        XCTAssertEqual(delivery.assets?.first?.url.host, "v19-webapp-prime.tiktok.com", "The largest H.264 raster is the playable set")
        XCTAssertEqual(delivery.assets?.first?.headers["Cookie"], cookie)
        XCTAssertEqual(delivery.assets?.first?.headers["Referer"], "https://www.tiktok.com/")
        XCTAssertEqual(delivery.assets?.first?.headers["User-Agent"], TikTokPhoneResolver.userAgent)
        XCTAssertEqual(delivery.expected?.width, 720)
        XCTAssertEqual(delivery.expected?.height, 1280)
        XCTAssertEqual(delivery.expected?.hasAudio, true)
        XCTAssertEqual(delivery.expected?.videoCodec, "unknown")
        XCTAssertEqual(delivery.expected?.audioCodec, "unknown")
        XCTAssertNoThrow(try DirectMediaPolicy.validate(media))
        XCTAssertFalse(DirectMediaPolicy.expiresSoon(media))
    }

    func testBetterHEVCOriginalIsConvertedWithTheH264AsFallback() throws {
        let html = try page(item(bitrates: [stream("bytevc1", 1080, 1920, bitrate: 2_000_000, host: "v19-webapp-prime"),
                                            stream("h264", 720, 1280, bitrate: 1_200_000)]))
        let media = try TikTokPhoneResolver.manifest(page: html, videoID: id, cookie: cookie)
        let delivery = try XCTUnwrap(media.delivery)
        XCTAssertEqual(delivery.convert, true)
        XCTAssertEqual(delivery.assets?.first?.url.host, "v19-webapp-prime.tiktok.com")
        XCTAssertEqual(delivery.expected?.width, 1080)
        XCTAssertEqual(delivery.fallback?.expected.width, 720)
        XCTAssertEqual(delivery.fallback?.assets.first?.headers["Cookie"], cookie)
        XCTAssertNoThrow(try DirectMediaPolicy.validate(media))
        XCTAssertEqual(ImportPlan.choose(delivery, capabilities: VideoDecodeCapabilities(supplementalDecodersAvailable: true, decodes: { _ in false })), .primary)
    }

    func testNothingAbove1080pIsUsedAndThe1080pH264PlaysDirectly() throws {
        let html = try page(item(bitrates: [stream("bytevc1", 2160, 3840, bitrate: 6_000_000, host: "v19-webapp-prime"),
                                            stream("h264", 1080, 1920, bitrate: 2_500_000)]))
        let delivery = try XCTUnwrap(TikTokPhoneResolver.manifest(page: html, videoID: id, cookie: cookie).delivery)
        XCTAssertEqual(delivery.convert, false)
        XCTAssertNil(delivery.fallback)
        XCTAssertEqual(delivery.expected?.width, 1080)
        XCTAssertEqual(delivery.assets?.first?.url.host, "v16-webapp-prime.tiktok.com")
    }

    func testHEVCWithTheSameRasterKeepsThePlayableH264() throws {
        let html = try page(item(bitrates: [stream("h265_hvc1", 720, 1280, bitrate: 900_000, host: "v19-webapp-prime"),
                                            stream("h264", 720, 1280, bitrate: 1_200_000)]))
        let delivery = try XCTUnwrap(TikTokPhoneResolver.manifest(page: html, videoID: id, cookie: cookie).delivery)
        XCTAssertEqual(delivery.convert, false)
        XCTAssertEqual(delivery.assets?.first?.url.host, "v16-webapp-prime.tiktok.com")
    }

    func testUnavailableAgeRestrictedLongAndUnusablePagesExplainWhy() throws {
        XCTAssertEqual(message(try page(["statusCode": 10204, "statusMsg": "item doesn't exist"])), TikTokPhoneResolver.unavailableMessage)
        XCTAssertEqual(message(try page(item(bitrates: [stream("h264", 720, 1280, bitrate: 1)], classified: true))), TikTokPhoneResolver.ageRestrictedMessage)
        XCTAssertEqual(message(try page(item(bitrates: [stream("h264", 720, 1280, bitrate: 1)], duration: 3601))), "Choose a video under 60 minutes.")
        XCTAssertEqual(message("<html><body>Please wait…</body></html>"), TikTokPhoneResolver.unusableMessage)
        XCTAssertEqual(message(try page(item(bitrates: [], playAddr: nil))), TikTokPhoneResolver.unusableMessage)
    }

    func testVideoIDsComeFromCanonicalLinksAndShortLinksMustBeFollowed() {
        XCTAssertEqual(TikTokPhoneResolver.videoID(in: URL(string: "https://www.tiktok.com/@someone/video/\(id)?is_from_webapp=1&sender_device=pc")!), id)
        XCTAssertEqual(TikTokPhoneResolver.videoID(in: URL(string: "https://m.tiktok.com/@i/video/\(id)")!), id)
        for raw in ["https://vt.tiktok.com/ZSabc123/", "https://vm.tiktok.com/ZMdef456/", "https://www.tiktok.com/t/ZTghi789/",
                    "https://www.tiktok.com/@someone", "https://www.tiktok.com/@someone/video/notanumber", "https://example.com/@a/video/\(id)"] {
            XCTAssertNil(TikTokPhoneResolver.videoID(in: URL(string: raw)!), raw)
        }
        XCTAssertTrue(TikTokPhoneResolver.handles(URL(string: "https://vt.tiktok.com/ZSabc123/")!))
        XCTAssertFalse(TikTokPhoneResolver.handles(URL(string: "https://tiktok.com.evil.test/@a/video/\(id)")!))
    }

    func testCookieHeaderIsAllowedOnlyForTikTok() throws {
        let tiktok = URL(string: "https://v16-webapp-prime.tiktok.com/video/tos/a.mp4")!
        let request = try DirectMediaPolicy.request(.init(role: "muxed", url: tiktok, headers: ["Cookie": cookie, "Referer": "https://www.tiktok.com/"]), platform: "tiktok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), cookie)
        XCTAssertFalse(request.httpShouldHandleCookies)
        for (platform, raw) in [("youtube", "https://rr1---sn.test.googlevideo.com/videoplayback"), ("instagram", "https://scontent.cdninstagram.com/v/a.mp4"), ("x", "https://video.twimg.com/a.mp4")] {
            XCTAssertThrowsError(try DirectMediaPolicy.request(.init(role: "muxed", url: URL(string: raw)!, headers: ["Cookie": cookie]), platform: platform), platform)
        }
    }

    func testWebappPrimeHostsFollowTheNumberedPatternOnly() {
        for host in ["v16-webapp-prime.tiktok.com", "v19-webapp-prime.tiktok.com", "v45-webapp-prime.tiktok.com"] {
            XCTAssertTrue(DirectMediaPolicy.allows(URL(string: "https://\(host)/video/a.mp4")!, platform: "tiktok"), host)
        }
        for host in ["v-webapp-prime.tiktok.com", "v16a-webapp-prime.tiktok.com", "xv16-webapp-prime.tiktok.com", "v16-webapp-prime.tiktok.com.evil.test", "www.tiktok.com"] {
            XCTAssertFalse(DirectMediaPolicy.allows(URL(string: "https://\(host)/video/a.mp4")!, platform: "tiktok"), host)
        }
        XCTAssertFalse(DirectMediaPolicy.allows(URL(string: "https://v16-webapp-prime.tiktok.com/video/a.mp4")!, platform: "youtube"))
    }

    // MARK: Fixtures

    private func stream(_ codec: String, _ width: Int, _ height: Int, bitrate: Int, host: String = "v16-webapp-prime") -> [String: Any] {
        ["CodecType": codec, "Bitrate": bitrate,
         "PlayAddr": ["Width": width, "Height": height, "UrlList": ["https://\(host).tiktok.com/video/tos/\(codec)-\(width).mp4?sig=1"]]]
    }
    private func item(bitrates: [[String: Any]], duration: Int = 15,
                      playAddr: String? = "https://v16-webapp-prime.tiktok.com/video/tos/play.mp4?sig=1", classified: Bool = false) -> [String: Any] {
        var video: [String: Any] = ["width": 576, "height": 1024, "duration": duration, "bitrateInfo": bitrates]
        if let playAddr { video["playAddr"] = playAddr }
        return ["statusCode": 0, "statusMsg": "ok",
                "itemInfo": ["itemStruct": ["id": id, "desc": "  A fixture clip ", "author": ["uniqueId": "creator"],
                                             "isContentClassified": classified, "video": video]]]
    }
    private func page(_ detail: [String: Any]) throws -> String {
        let json = try JSONSerialization.data(withJSONObject: ["__DEFAULT_SCOPE__": ["webapp.video-detail": detail]])
        return #"<html><head><script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">"#
            + String(decoding: json, as: UTF8.self) + "</script></head><body></body></html>"
    }
    private func message(_ html: String) -> String? {
        do { _ = try TikTokPhoneResolver.manifest(page: html, videoID: id, cookie: cookie); return nil }
        catch { return error.localizedDescription }
    }
}
