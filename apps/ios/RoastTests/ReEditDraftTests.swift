import XCTest
@testable import Roast

final class ReEditDraftTests: XCTestCase {
    func testLegacyTakeWithoutDraftFieldStillDecodes() throws {
        let legacy = Data(#"{"id":"1DCDFDA4-569E-46A1-B01B-BE7DD45F5FFA","fileName":"take.mp4","title":"Old take","createdAt":0,"duration":12,"kind":"Roast"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SavedTake.self, from: legacy).draftID)
    }

    @MainActor func testSavedVideoKeepsItsDraftUntilTheLastVideoFromItIsDeleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = DraftStore(directory: root.appendingPathComponent("Drafts", isDirectory: true))
        let draftID = try makeDraft(in: drafts.directory)
        let takes = root.appendingPathComponent("Takes", isDirectory: true)
        let library = TakeLibrary(directory: takes, draftStore: drafts)
        let first = try library.add(url: try video(in: root), title: "First", duration: 1, draftID: draftID)
        let second = try library.add(url: try video(in: root), title: "Second", duration: 1, draftID: draftID)

        let reloaded = TakeLibrary(directory: takes, draftStore: drafts)
        XCTAssertEqual(Set(reloaded.takes.compactMap(\.draftID)), [draftID], "The link survives a relaunch.")

        try library.delete(first)
        XCTAssertEqual(try drafts.list().map(\.id), [draftID], "Another saved video still comes from this draft.")
        try library.delete(second)
        XCTAssertTrue(try drafts.list().isEmpty, "Deleting the last saved video deletes its draft.")
    }

    private func makeDraft(in directory: URL) throws -> UUID {
        let id = UUID()
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let capture = folder.appendingPathComponent("capture.mov")
        try Data([1, 2, 3]).write(to: capture)
        let draft = RecordingDraft(id: id, videoURL: capture, microphoneURL: nil, sourceAudioURL: nil,
                                   duration: 2, title: "Draft")
        try JSONEncoder().encode(draft).write(to: folder.appendingPathComponent("draft.json"))
        return id
    }

    private func video(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }
}
