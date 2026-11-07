import XCTest
@testable import Roast

final class DraftStoreTests: XCTestCase {
    func testRestoredContainerRebasesCaptureMicrophoneAndSourceFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stored = try makeDraft(in: root)
        let found = try XCTUnwrap(DraftStore(directory: root).list().first?.draft)
        let folder = root.appendingPathComponent(stored.id.uuidString)
        XCTAssertEqual(found.id, stored.id)
        XCTAssertEqual(found.videoURL, folder.appendingPathComponent("capture.mov"))
        XCTAssertEqual(found.microphoneURL, found.videoURL)
        XCTAssertEqual(found.sourceAudioURL, folder.appendingPathComponent("source.m4a"))
        XCTAssertEqual(found.title, "Keep editing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: found.videoURL.path))
    }

    func testReopenKeepsEditsAndRebasesPrivateMusic() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stored = try makeDraft(in: root)
        let folder = root.appendingPathComponent(stored.id.uuidString)
        var edits = TakeEdits(duration: stored.duration)
        edits.trimStart = 1
        edits.trimEnd = 8
        edits.cuts = [EditInterval(start: 3, end: 4)]
        edits.microphoneVolume = 1.3
        edits.sourceVolume = 0.2
        edits.musicVolume = 0.4
        edits.musicURL = stored.videoURL.deletingLastPathComponent().appendingPathComponent("music-kept.wav")
        edits.musicTitle = "My music"
        edits.captions = [TakeCaption(start: 2, end: 3, text: "My correction")]
        try Data("music fixture".utf8).write(to: folder.appendingPathComponent("music-kept.wav"))
        try JSONEncoder().encode(edits).write(to: folder.appendingPathComponent("edits.json"))
        let oldMetadata = try Data(contentsOf: folder.appendingPathComponent("draft.json"))

        let draft = try XCTUnwrap(DraftStore(directory: root).list().first?.draft)
        let reopened = EditorEditStore.load(for: draft)
        XCTAssertEqual(reopened.trimStart, 1)
        XCTAssertEqual(reopened.trimEnd, 8)
        XCTAssertEqual(reopened.cuts, edits.cuts)
        XCTAssertEqual(reopened.microphoneVolume, 1.3)
        XCTAssertEqual(reopened.sourceVolume, 0.2)
        XCTAssertEqual(reopened.musicVolume, 0.4)
        XCTAssertEqual(reopened.captions, edits.captions)
        XCTAssertEqual(reopened.musicURL, folder.appendingPathComponent("music-kept.wav"))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("draft.json")), oldMetadata,
                       "Discovering an unfinished take must not rewrite or discard its original")
        try EditorEditStore.save(reopened, for: draft)
        XCTAssertEqual(EditorEditStore.load(for: draft), reopened)
    }

    func testMostRecentlyEditedDraftSortsFirst() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let edited = try makeDraft(in: root)
        let newerRecording = try makeDraft(in: root)
        let base = Date().addingTimeInterval(1_000)
        let editedFolder = root.appendingPathComponent(edited.id.uuidString)
        let newerFolder = root.appendingPathComponent(newerRecording.id.uuidString)
        try JSONEncoder().encode(TakeEdits(duration: 10)).write(to: editedFolder.appendingPathComponent("edits.json"))
        for url in [editedFolder, editedFolder.appendingPathComponent("draft.json")] {
            try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: url.path)
        }
        for url in [newerFolder, newerFolder.appendingPathComponent("draft.json")] {
            try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(50)], ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(100)],
            ofItemAtPath: editedFolder.appendingPathComponent("edits.json").path)
        XCTAssertEqual(try DraftStore(directory: root).list().map(\.id), [edited.id, newerRecording.id])
    }

    func testMissingExpectedAudioRetainsURLsInsteadOfSilentlyDroppingTheMix() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stored = try makeDraft(in: root)
        let folder = root.appendingPathComponent(stored.id.uuidString)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("source.m4a"))
        var edits = TakeEdits(duration: stored.duration)
        edits.musicURL = stored.videoURL.deletingLastPathComponent().appendingPathComponent("music-missing.wav")
        try JSONEncoder().encode(edits).write(to: folder.appendingPathComponent("edits.json"))

        let draft = try XCTUnwrap(DraftStore(directory: root).list().first?.draft)
        XCTAssertEqual(draft.sourceAudioURL, folder.appendingPathComponent("source.m4a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(draft.sourceAudioURL).path))
        let reopened = EditorEditStore.load(for: draft)
        XCTAssertEqual(reopened.musicURL, folder.appendingPathComponent("music-missing.wav"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(reopened.musicURL).path))
    }

    func testBrokenMetadataOrMissingCaptureCannotHideOtherDrafts() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try makeDraft(in: root)
        let missing = try makeDraft(in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(missing.id.uuidString).appendingPathComponent("capture.mov"))
        let malformed = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
        try Data("broken metadata".utf8).write(to: malformed.appendingPathComponent("draft.json"))
        let wrongIdentity = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: wrongIdentity, withIntermediateDirectories: true)
        try JSONEncoder().encode(valid).write(to: wrongIdentity.appendingPathComponent("draft.json"))
        try Data("capture".utf8).write(to: wrongIdentity.appendingPathComponent("capture.mov"))
        XCTAssertEqual(try DraftStore(directory: root).list().map(\.id), [valid.id])
    }

    func testRefreshingReflectsFinalSaveRemovalAndMissingDraftFolderIsEmpty() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftStore(directory: root)
        let draft = try makeDraft(in: root)
        XCTAssertEqual(try store.list().count, 1)
        try FileManager.default.removeItem(at: root.appendingPathComponent(draft.id.uuidString))
        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertTrue(try DraftStore(directory: root.appendingPathComponent("not-created")).list().isEmpty)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RoastDraftStoreTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func makeDraft(in root: URL) throws -> RecordingDraft {
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("capture fixture".utf8).write(to: folder.appendingPathComponent("capture.mov"))
        try Data("source fixture".utf8).write(to: folder.appendingPathComponent("source.m4a"))
        let oldFolder = URL(fileURLWithPath: "/old-container/Documents/Drafts/\(id.uuidString)")
        let draft = RecordingDraft(id: id, videoURL: oldFolder.appendingPathComponent("capture.mov"),
            microphoneURL: oldFolder.appendingPathComponent("capture.mov"),
            sourceAudioURL: oldFolder.appendingPathComponent("source.m4a"), duration: 10, title: "Keep editing")
        try JSONEncoder().encode(draft).write(to: folder.appendingPathComponent("draft.json"))
        return draft
    }
}
