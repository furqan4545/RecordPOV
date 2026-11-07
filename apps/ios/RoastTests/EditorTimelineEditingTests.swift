import XCTest
@testable import Roast

final class EditorTimelineEditingTests: XCTestCase {
    func testActualReportedValidIntervalIsPreservedExactly() {
        var edits = TakeEdits(duration: 28.2666666667)
        edits.trimEnd = 18.5225413084
        let result = EditorTimelineEditing.normalized(edits, duration: 28.2666666667)
        XCTAssertEqual(result, edits)
        XCTAssertEqual(EditorTimeline(duration: 28.2666666667, edits: result).duration, 18.5225413084, accuracy: 0.000001)
    }

    func testCrossingHandlesKeepMinimumDurationAndOtherEndpoint() {
        var edits = TakeEdits(duration: 10)
        edits.trimStart = 2
        edits.trimEnd = 8
        let start = EditorTimelineEditing.trimmingStart(to: 9, edits: edits, duration: 10)
        XCTAssertEqual(start.trimStart, 7.8, accuracy: 0.000001)
        XCTAssertEqual(start.trimEnd, 8)
        let end = EditorTimelineEditing.trimmingEnd(to: 1, edits: edits, duration: 10)
        XCTAssertEqual(end.trimStart, 2)
        XCTAssertEqual(end.trimEnd, 2.2, accuracy: 0.000001)
    }

    func testContinuousTrimClearsLegacyCutsAndPreservesMixAndCaptionChoices() {
        var edits = TakeEdits(duration: 10)
        edits.cuts = [EditInterval(start: 0, end: 10)]
        edits.microphoneVolume = 0.4
        edits.sourceVolume = 0.8
        edits.musicURL = URL(fileURLWithPath: "/music.m4a")
        edits.captions = [TakeCaption(start: 1, end: 2, text: "Keep this text")]
        let result = EditorTimelineEditing.trimmingStart(to: 3, edits: edits, duration: 10)
        XCTAssertTrue(result.cuts.isEmpty)
        XCTAssertEqual(result.trimStart, 3)
        XCTAssertEqual(result.microphoneVolume, edits.microphoneVolume)
        XCTAssertEqual(result.sourceVolume, edits.sourceVolume)
        XCTAssertEqual(result.musicURL, edits.musicURL)
        XCTAssertEqual(result.captions, edits.captions)
    }

    func testInvalidBoundsAndTinyClipStayFiniteAndNonempty() {
        var edits = TakeEdits(duration: 0.1)
        edits.trimStart = .infinity
        edits.trimEnd = -.infinity
        let result = EditorTimelineEditing.normalized(edits, duration: 0.1)
        XCTAssertEqual(result.trimStart, 0)
        XCTAssertEqual(result.trimEnd, 0.1)
        let moved = EditorTimelineEditing.trimmingEnd(to: -50, edits: result, duration: 0.1)
        XCTAssertEqual(moved.trimEnd, 0.1)
        XCTAssertEqual(EditorTimelineEditing.boundedSourceTime(.nan, duration: 3), 0)
        XCTAssertEqual(EditorTimelineEditing.boundedSourceTime(100, duration: 3), 3)
    }
}
