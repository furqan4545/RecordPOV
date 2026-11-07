import XCTest
@testable import Roast

final class ImportGuidanceTests: XCTestCase {
    func testIdleShowsNoGuidance() {
        XCTAssertNil(ImportGuidance.current(phase: .idle))
    }

    func testEveryImportStepAsksToKeepTheAppOpenUntilTheVideoIsReady() {
        for phase in [VideoLinkLoadingPhase.preparing, .downloading, .loading] {
            XCTAssertEqual(ImportGuidance.current(phase: phase),
                           ImportGuidance(tone: .stay, symbol: "iphone", text: "Keep RecordPOV open until your video is ready."))
        }
    }

    func testButtonTitlesAndReadyTitle() {
        XCTAssertEqual(VideoLinkLoadingPhase.preparing.buttonTitle, "Getting your video…")
        XCTAssertEqual(VideoLinkLoadingPhase.downloading.buttonTitle, "Downloading…")
        XCTAssertEqual(VideoLinkLoadingPhase.loading.buttonTitle, "Almost ready…")
        XCTAssertEqual(ImportGuidance.readyTitle, "Your video is ready")
    }

    func testPercentTextRoundsDownAndClamps() {
        XCTAssertNil(ImportGuidance.percentText(nil))
        XCTAssertEqual(ImportGuidance.percentText(0), "0%")
        XCTAssertEqual(ImportGuidance.percentText(0.419), "41%")
        XCTAssertEqual(ImportGuidance.percentText(0.29), "29%")
        XCTAssertEqual(ImportGuidance.percentText(0.999), "99%")
        XCTAssertEqual(ImportGuidance.percentText(1.0), "100%")
        XCTAssertEqual(ImportGuidance.percentText(1.7), "100%")
        XCTAssertEqual(ImportGuidance.percentText(-0.2), "0%")
    }

    func testPercentValueMatchesTheVisibleText() {
        XCTAssertNil(ImportGuidance.percentValue(nil))
        for step in 0...100 {
            // The coordinator stores whole percents as step / 100.
            let progress = Double(step) / 100
            XCTAssertEqual(ImportGuidance.percentValue(progress), step)
            XCTAssertEqual(ImportGuidance.percentText(progress), "\(step)%")
        }
    }
}
