import XCTest
@testable import Roast

final class SourceLinkIdentityTests: XCTestCase {
    func testYouTubeShareWatchShortAndEmbedURLsIdentifyTheSameVideo() {
        let original = "https://youtu.be/bkPwFqa89gE?si=tracking"
        for value in ["https://www.youtube.com/watch?v=bkPwFqa89gE&t=20", "https://m.youtube.com/shorts/bkPwFqa89gE", "https://www.youtube.com/embed/bkPwFqa89gE", "https://www.youtube.com/live/bkPwFqa89gE"] {
            XCTAssertTrue(SourceLinkIdentity.same(value, as: original))
        }
        XCTAssertFalse(SourceLinkIdentity.same("https://youtu.be/jNQXAC9IVRw", as: original))
    }
    func testInstagramTrackingAndTrailingSlashesDoNotRequestAnotherDownload() {
        XCTAssertTrue(SourceLinkIdentity.same("  https://www.instagram.com/reel/DfR0-RNR-Y8/?cplk=tracking \n", as: "https://instagram.com/reels/DfR0-RNR-Y8"))
        XCTAssertTrue(SourceLinkIdentity.same("https://instagram.com/p/DfR0-RNR-Y8/", as: "https://instagram.com/reel/DfR0-RNR-Y8/"))
        XCTAssertFalse(SourceLinkIdentity.same("https://instagram.com/reel/DdxcpXIzats/", as: "https://instagram.com/reel/DfR0-RNR-Y8/"))
    }
    func testXUsesTheStatusIDRatherThanUserNameHostOrTracking() {
        XCTAssertTrue(SourceLinkIdentity.same("https://x.com/historyinmemes/status/1790637656616943991?s=20", as: "https://twitter.com/i/status/1790637656616943991"))
        XCTAssertFalse(SourceLinkIdentity.same("https://x.com/example/status/1790637656616943992", as: "https://x.com/example/status/1790637656616943991"))
    }
    func testTikTokKeepsDifferentVideoIDsAndOpaqueShortLinksDistinct() {
        XCTAssertTrue(SourceLinkIdentity.same("https://www.tiktok.com/@newname/video/6742501081818877190?share=1", as: "https://www.tiktok.com/@oldname/video/6742501081818877190"))
        XCTAssertTrue(SourceLinkIdentity.same("https://vm.tiktok.com/Zabc/?share=1", as: "https://vm.tiktok.com/Zabc/"))
        XCTAssertFalse(SourceLinkIdentity.same("https://vm.tiktok.com/Zabc/", as: "https://vm.tiktok.com/Zdef/"))
    }
    func testEmptyAndInvalidLinksCannotSelectAnExistingVideo() {
        for value in ["", "not a link", "http://youtu.be/bkPwFqa89gE", "https://user:password@youtu.be/bkPwFqa89gE"] {
            XCTAssertFalse(SourceLinkIdentity.same(value, as: "https://youtu.be/bkPwFqa89gE"))
        }
        XCTAssertFalse(SourceLinkIdentity.same("https://youtu.be/bkPwFqa89gE", as: nil))
    }
}
