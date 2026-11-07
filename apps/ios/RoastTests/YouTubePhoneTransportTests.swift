import Foundation
import XCTest
@testable import Roast

final class YouTubePhoneTransportTests: XCTestCase {
    func testOnlyApprovedDNSHostnamesAndTLSportAreAccepted() {
        for host in ["youtube.com", "www.youtube.com", "rr1---sn-123.googlevideo.com", "i.ytimg.com", "youtubei.googleapis.com"] {
            XCTAssertEqual(YouTubeRelayPolicy.allowedHost(host, port: 443), host)
        }
        XCTAssertEqual(YouTubeRelayPolicy.allowedHost("WWW.YouTube.COM", port: 443), "www.youtube.com")
        for host in ["youtube.com.evil.test", "notyoutube.com", "youtubei.googleapis.com.evil.test", "evil.googleapis.com",
                     "127.0.0.1", "[::1]", "::1", "localhost", "youtube.com.", " www.youtube.com", "youtube.com\n",
                     "user@youtube.com", "youtube.com/path", "youtube.com:443", "you%74ube.com", "yоutube.com",
                     "foo..youtube.com", "-foo.youtube.com", "foo-.youtube.com", "", String(repeating: "a", count: 64) + ".youtube.com"] {
            XCTAssertNil(YouTubeRelayPolicy.allowedHost(host, port: 443), host)
        }
        for port in [0, 22, 53, 80, 8443, 65536] { XCTAssertNil(YouTubeRelayPolicy.allowedHost("youtube.com", port: port)) }
    }

    func testPublicAddressesIncludeDeliberatelyValidatedDNS64AndMappedIPv4() {
        for address in ["1.1.1.1", "8.8.8.8", "142.250.70.14", "172.217.1.1", "192.0.73.1", "100.63.255.255", "100.128.0.1",
                        "2001:4860:4860::8888", "2606:4700:4700::1111", "2607:f8b0:4000::1",
                        "64:ff9b::808:808", "::ffff:8.8.8.8", "::ffff:808:808"] {
            XCTAssertTrue(YouTubeRelayPolicy.isPublicAddress(address), address)
        }
    }

    func testPrivateReservedAndTransitionAddressesCannotReachThePhoneNetwork() {
        for address in ["0.1.2.3", "10.1.2.3", "100.64.0.1", "100.127.255.254", "127.0.0.1", "169.254.169.254",
                        "172.16.0.1", "172.31.255.254", "192.0.0.1", "192.0.2.1", "192.88.99.1", "192.168.1.1",
                        "198.18.0.1", "198.19.0.1", "198.51.100.1", "203.0.113.1", "224.0.0.1", "255.255.255.255",
                        "::", "::1", "fc00::1", "fd12::1", "fe80::1", "fec0::1", "ff02::1", "fe80::1%en0",
                        "::ffff:127.0.0.1", "::ffff:c0a8:101", "::ffff:a9fe:a9fe", "2001::1", "2001:20::1",
                        "2001:db8::1", "2002:7f00:1::1", "3fff:1::1", "3ffe::1", "64:ff9b::7f00:1",
                        "64:ff9b::c0a8:101", "64:ff9b::c000:201", "64:ff9b:1::808:808", "garbage"] {
            XCTAssertFalse(YouTubeRelayPolicy.isPublicAddress(address), address)
        }
    }

    func testBinaryFramesRoundTripWithNetworkByteOrderAndMaximumPayload() throws {
        let payload = Data(repeating: 0xa5, count: YouTubeRelayPolicy.maximumPayload)
        let frame = try YouTubeRelayFrame.encode(id: 0x01020304, payload: payload)
        XCTAssertEqual(Array(frame.prefix(5)), [1, 1, 2, 3, 4])
        let decoded = try YouTubeRelayFrame.decode(frame)
        XCTAssertEqual(decoded.id, 0x01020304)
        XCTAssertEqual(decoded.payload, payload)
        let maximumID = try YouTubeRelayFrame.encode(id: .max, payload: Data([1]))
        XCTAssertEqual(try YouTubeRelayFrame.decode(maximumID).id, UInt32.max)
    }

    func testMalformedEmptyOversizedAndUnknownVersionFramesAreRejected() {
        for frame in [Data(), Data([1, 0, 0, 0, 1]), Data([2, 0, 0, 0, 1, 1]), Data([1, 0, 0, 0, 0, 1]),
                      Data([1, 0, 0, 0, 1]) + Data(repeating: 1, count: YouTubeRelayPolicy.maximumPayload + 1)] {
            XCTAssertThrowsError(try YouTubeRelayFrame.decode(frame))
        }
        XCTAssertThrowsError(try YouTubeRelayFrame.encode(id: 0, payload: Data([1])))
        XCTAssertThrowsError(try YouTubeRelayFrame.encode(id: 1, payload: Data()))
    }

    func testCreditCannotBeInventedReplayedOrExceedTheBoundedWindow() throws {
        var credit = YouTubeRelayCredit()
        XCTAssertThrowsError(try credit.acknowledge(1))
        for _ in 0..<8 { try credit.consume(32_768) }
        XCTAssertEqual(credit.available, 0)
        XCTAssertThrowsError(try credit.consume(1))
        try credit.acknowledge(32_768)
        XCTAssertEqual(credit.available, 32_768)
        try credit.consume(32_768)
        for _ in 0..<8 { try credit.acknowledge(32_768) }
        XCTAssertEqual(credit.available, YouTubeRelayPolicy.window)
        XCTAssertThrowsError(try credit.acknowledge(1))
        for invalid in [0, -1, 32_769, Int.max] {
            XCTAssertThrowsError(try credit.consume(invalid))
            XCTAssertThrowsError(try credit.acknowledge(invalid))
        }
        XCTAssertEqual(credit.available, YouTubeRelayPolicy.window)
    }

    func testEachDirectionHasIndependentCredit() throws {
        var upstream = YouTubeRelayCredit(), downstream = YouTubeRelayCredit()
        try upstream.consume(100)
        try downstream.consume(200)
        try downstream.acknowledge(200)
        XCTAssertEqual(upstream.available, YouTubeRelayPolicy.window - 100)
        XCTAssertEqual(downstream.available, YouTubeRelayPolicy.window)
        XCTAssertThrowsError(try downstream.acknowledge(100))
    }

    func testTicketRequiresMatchingSecureOriginExactPathAndAnUnexpiredBoundedLease() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let base = URL(string: "https://api.recordpov.app")!
        let valid = ticket(expires: now.addingTimeInterval(630))
        XCTAssertEqual(try valid.validate(api: base, now: now), 630, accuracy: 0.001)
        XCTAssertEqual(try ticket(expires: now.addingTimeInterval(5_000)).validate(api: base, now: now), 630)
        XCTAssertThrowsError(try ticket(expires: now.addingTimeInterval(-1)).validate(api: base, now: now))
        for url in ["ws://api.recordpov.app/v1/media/youtube/sessions/test_session_1234/socket",
                    "wss://evil.example/v1/media/youtube/sessions/test_session_1234/socket",
                    "wss://api.recordpov.app:8443/v1/media/youtube/sessions/test_session_1234/socket",
                    "wss://user@api.recordpov.app/v1/media/youtube/sessions/test_session_1234/socket",
                    "wss://api.recordpov.app/v1/media/youtube/sessions/wrong/socket",
                    "wss://api.recordpov.app/v1/media/youtube/sessions/test_session_1234/socket?token=secret"] {
            XCTAssertThrowsError(try ticket(socket: url, expires: now.addingTimeInterval(30)).validate(api: base, now: now), url)
        }
        XCTAssertThrowsError(try valid.validate(api: URL(string: "http://api.recordpov.app")!, now: now))
    }

    @MainActor func testOverlappingForegroundLeasesRestoreOnlyAfterTheLastOwnerAndIgnoreStaleRelease() {
        var disabled = false
        let manager = YouTubeRelayIdleLease(read: { disabled }, write: { disabled = $0 })
        let first = manager.acquire(), second = manager.acquire()
        manager.release(first)
        XCTAssertTrue(disabled)
        manager.release(second)
        XCTAssertFalse(disabled)
        let next = manager.acquire()
        manager.release(second)
        XCTAssertTrue(disabled)
        manager.release(next)
        XCTAssertFalse(disabled)
    }

    @MainActor func testForegroundLeasePreservesAnAlreadyDisabledIdleTimer() {
        var disabled = true
        let manager = YouTubeRelayIdleLease(read: { disabled }, write: { disabled = $0 })
        let lease = manager.acquire()
        manager.release(lease)
        XCTAssertTrue(disabled)
    }

    private func ticket(socket: String = "wss://api.recordpov.app/v1/media/youtube/sessions/test_session_1234/socket",
                        expires: Date) -> YouTubePhoneSessionTicket {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return YouTubePhoneSessionTicket(sessionId: "test_session_1234", token: String(repeating: "a", count: 43),
                                         socketUrl: URL(string: socket)!, expiresAt: formatter.string(from: expires))
    }
}
