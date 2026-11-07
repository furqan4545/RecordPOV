import XCTest
@testable import Roast

final class DirectMediaExpiryTests: XCTestCase {
    func testMissingExpiryCountsAsExpiringSoon() throws {
        XCTAssertTrue(DirectMediaPolicy.expiresSoon(try manifest(expiry: nil)))
    }
    func testUnparseableExpiryCountsAsExpiringSoon() throws {
        XCTAssertTrue(DirectMediaPolicy.expiresSoon(try manifest(expiry: "tomorrow")))
        XCTAssertTrue(DirectMediaPolicy.expiresSoon(try manifest(expiry: "")))
    }
    func testPastExpiryIsExpiringSoon() throws {
        XCTAssertTrue(DirectMediaPolicy.expiresSoon(try manifest(expiry: "2020-01-01T00:00:00Z")))
    }
    func testExpiryInsideTheMarginIsExpiringSoon() throws {
        let soon = ISO8601DateFormatter().string(from: .now.addingTimeInterval(5))
        XCTAssertTrue(DirectMediaPolicy.expiresSoon(try manifest(expiry: soon)))
        let later = ISO8601DateFormatter().string(from: .now.addingTimeInterval(30))
        XCTAssertFalse(DirectMediaPolicy.expiresSoon(try manifest(expiry: later)))
        XCTAssertTrue(DirectMediaPolicy.expiresSoon(try manifest(expiry: later), margin: 60))
    }
    func testFarFutureExpiryIsNotExpiringSoon() throws {
        let plain = ISO8601DateFormatter().string(from: .now.addingTimeInterval(300))
        XCTAssertFalse(DirectMediaPolicy.expiresSoon(try manifest(expiry: plain)))
        let fractional = ISO8601DateFormatter.fractional.string(from: .now.addingTimeInterval(300))
        XCTAssertFalse(DirectMediaPolicy.expiresSoon(try manifest(expiry: fractional)))
    }
    private func manifest(expiry: String?) throws -> ResolvedMedia {
        let assets: [[String: Any]] = [["role": "muxed", "url": "https://video.twimg.com/muxed.mp4", "headers": [String: String]()]]
        var payload: [String: Any] = ["id": "0123456789abcdef01234567", "title": "Fixture", "sourceUrl": "https://x.com/example/status/123456789", "platform": "x",
            "delivery": ["kind": "direct", "assets": assets, "expected": ["duration": 0.6, "width": 64, "height": 96, "hasAudio": false], "maxBytes": 1_000_000]]
        if let expiry { payload["expiresAt"] = expiry }
        return try JSONDecoder().decode(ResolvedMedia.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}
