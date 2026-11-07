import XCTest
@testable import Roast

final class EditorTimelineTests: XCTestCase {
    func testVoiceCleanupDefaultsOnlyForNewTakesAndExplicitChoicePersists() throws {
        XCTAssertEqual(TakeEdits(duration: 3).voiceCleanupEnabled, true)
        let old = try JSONDecoder().decode(TakeEdits.self, from: Data(#"{"trimStart":0,"trimEnd":3,"cuts":[],"sourceVolume":0.75,"microphoneVolume":1,"musicVolume":0.35,"captionsEnabled":true,"captions":[]}"#.utf8))
        XCTAssertNil(old.voiceCleanupEnabled)
        XCTAssertEqual(old.microphoneVolume, 1, "Explicit saved levels must not be replaced by the new default.")
        var current = TakeEdits(duration: 3)
        current.voiceCleanupEnabled = false
        let restored = try JSONDecoder().decode(TakeEdits.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(restored.voiceCleanupEnabled, false)
        XCTAssertEqual(restored.microphoneVolume, 0.6)
        XCTAssertEqual(restored.sourceVolume, 0.75)
    }

    func testMissingMicrophoneLevelUsesSixtyPercentWithoutDiscardingStoredEdits() throws {
        let stored = Data(#"{"trimStart":1.25,"trimEnd":8.5,"sourceVolume":0.9,"musicVolume":0.2,"captionsEnabled":false}"#.utf8)
        let edits = try JSONDecoder().decode(TakeEdits.self, from: stored)
        XCTAssertEqual(edits.microphoneVolume, 0.6)
        XCTAssertEqual(edits.trimStart, 1.25)
        XCTAssertEqual(edits.trimEnd, 8.5)
        XCTAssertEqual(edits.sourceVolume, 0.9)
        XCTAssertEqual(edits.musicVolume, 0.2)
        XCTAssertFalse(edits.captionsEnabled)
        XCTAssertNil(edits.voiceCleanupEnabled)
        for level in [0.0, 0.65, 1.35] {
            var chosen = edits
            chosen.microphoneVolume = level
            let reopened = try JSONDecoder().decode(TakeEdits.self, from: JSONEncoder().encode(chosen))
            XCTAssertEqual(reopened.microphoneVolume, level)
            XCTAssertEqual(reopened.trimStart, chosen.trimStart)
        }
    }

    func testTrimAndOverlappingCutsProduceOneSharedClock() {
        var edits = TakeEdits(duration: 4)
        edits.trimStart = 0.25
        edits.trimEnd = 3
        edits.cuts = [EditInterval(start: 0.5, end: 1), EditInterval(start: 0.8, end: 2)]
        let timeline = EditorTimeline(duration: 4, edits: edits)
        XCTAssertEqual(timeline.segments.count, 2)
        XCTAssertEqual(timeline.duration, 1.25, accuracy: 0.0001)
        XCTAssertEqual(timeline.segments[0].sourceStart, 0.25)
        XCTAssertEqual(timeline.segments[1].sourceStart, 2)
        XCTAssertEqual(timeline.segments[1].outputStart, 0.25)
        XCTAssertEqual(timeline.sourceTime(atOutput: 0.75), 2.5, accuracy: 0.0001)
        XCTAssertEqual(timeline.outputTime(atSource: 2.5), 0.75, accuracy: 0.0001)
        XCTAssertEqual(timeline.outputTime(atSource: 1), 0.25, accuracy: 0.0001)
    }

    func testCaptionsRemoveCutWordsAndMapMicrophoneTimestamps() {
        var edits = TakeEdits(duration: 4)
        edits.trimStart = 0.25
        edits.trimEnd = 3
        edits.cuts = [EditInterval(start: 0.5, end: 2)]
        let words = [CaptionWord(start: 0.3, end: 0.5, text: "Hello"),
                     CaptionWord(start: 0.7, end: 1, text: "removed"),
                     CaptionWord(start: 2.2, end: 2.5, text: "there")]
        let caption = TakeCaption(start: 0.3, end: 2.5, text: "Hello removed there", words: words)
        let mapped = EditorTimeline(duration: 4, edits: edits).remap([caption])
        XCTAssertEqual(mapped.map(\.text), ["Hello", "there"])
        XCTAssertEqual(mapped[0].start, 0.05, accuracy: 0.0001)
        XCTAssertEqual(mapped[1].start, 0.45, accuracy: 0.0001)
        XCTAssertEqual(mapped[1].end, 0.75, accuracy: 0.0001)
    }

    func testUserCaptionCorrectionsArePreserved() {
        let words = [CaptionWord(start: 1, end: 2, text: "wrong")]
        let caption = TakeCaption(start: 1, end: 2, text: "Corrected by me", words: words)
        var edits = TakeEdits(duration: 3)
        edits.trimStart = 1.5
        let mapped = EditorTimeline(duration: 3, edits: edits).remap([caption])
        XCTAssertEqual(mapped.first?.text, "Corrected by me")
        XCTAssertEqual(mapped.first?.start, 0)
        XCTAssertEqual(mapped.first?.end, 0.5)
    }

    func testInvalidAndOutsideCutsCannotCreateNegativeOrDuplicateTime() {
        var edits = TakeEdits(duration: 3)
        edits.cuts = [EditInterval(start: -.infinity, end: 2), EditInterval(start: 4, end: 5),
                      EditInterval(start: 2, end: 1), EditInterval(start: -5, end: 0)]
        let timeline = EditorTimeline(duration: 3, edits: edits)
        XCTAssertEqual(timeline.duration, 2)
        XCTAssertEqual(timeline.segments.map(\.duration), [1, 1])
        edits.cuts.append(EditInterval(start: 0, end: 3))
        XCTAssertEqual(EditorTimeline(duration: 3, edits: edits).duration, 0)
    }

    func testCaptionGroupingBreaksAtPunctuationAndLongPauses() {
        let words = [CaptionWord(start: 0, end: 0.3, text: "Hello."),
                     CaptionWord(start: 0.4, end: 0.7, text: "My"),
                     CaptionWord(start: 0.8, end: 1, text: "take"),
                     CaptionWord(start: 2.5, end: 2.8, text: "continues")]
        let captions = CaptionGrouping.cues(from: words)
        XCTAssertEqual(captions.map(\.text), ["Hello.", "My take", "continues"])
        XCTAssertEqual(captions.last?.start, 2.5)
    }
}
