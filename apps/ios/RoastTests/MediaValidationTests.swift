import XCTest
@testable import Roast

final class MediaValidationTests: XCTestCase {
    func testPublicVideoProviders() {
        for value in ["https://www.instagram.com/reels/Datls4XT4Hy/", "https://youtu.be/test", "https://www.youtube.com/watch?v=test", "https://x.com/user/status/123", "https://www.tiktok.com/@creator/video/123"] {
            XCTAssertTrue(MediaResolver.supports(value), value)
        }
    }

    func testUntrustedLinksAreNotSentToResolver() {
        for value in ["file:///etc/passwd", "http://youtube.com/watch?v=test", "https://youtube.com.evil.example/watch?v=test", "https://youtube.com@evil.example/video", "https://user:password@youtube.com/watch?v=test", "not a link", "https://127.0.0.1/video"] {
            XCTAssertFalse(MediaResolver.supports(value), value)
        }
    }

    func testDisplayTimeHandlesInvalidMediaMetadata() {
        XCTAssertEqual(Double.nan.minuteSecond, "0:00")
        XCTAssertEqual(Double.infinity.minuteSecond, "0:00")
        XCTAssertEqual((-25.0).minuteSecond, "0:00")
        XCTAssertEqual(108.57.minuteSecond, "1:48")
    }
}

