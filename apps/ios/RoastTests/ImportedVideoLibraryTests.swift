import Foundation
import XCTest
@testable import Roast

@MainActor
final class ImportedVideoLibraryTests: XCTestCase {
    func testImportSurvivesClosingAndDeletingTheTransientDownload() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("download.mov"))
        let storage = root.appendingPathComponent("ImportedVideos")
        let library = ImportedVideoLibrary(directory: storage)
        let originalPage = URL(string: "https://www.instagram.com/reel/example/")!
        let item = try library.add(url: source, title: "Keep this video", sourceURL: originalPage,
                                   platform: "instagram", duration: 14.5)
        XCTAssertNotEqual(item.fileURL, source)
        try FileManager.default.removeItem(at: source)
        let restored = ImportedVideoLibrary(directory: storage)
        let found = try XCTUnwrap(restored.videos.first)
        XCTAssertEqual(found.id, item.id); XCTAssertEqual(found.title, "Keep this video")
        XCTAssertEqual(found.sourceURL, originalPage); XCTAssertEqual(found.platform, "instagram")
        XCTAssertEqual(found.duration, 14.5)
        XCTAssertEqual(try Data(contentsOf: found.fileURL), Data("original video fixture".utf8))
    }

    func testBackgroundJobReplayIsIdempotentEvenAfterItsTransientFileIsGone() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("download.mp4"))
        let library = ImportedVideoLibrary(directory: root.appendingPathComponent("ImportedVideos"))
        let jobID = UUID()
        let first = try library.add(url: source, title: "Original title", importID: jobID)
        try FileManager.default.removeItem(at: source)
        let replay = try library.add(url: source, title: "Do not replace my title", importID: jobID)
        XCTAssertEqual(first, replay); XCTAssertEqual(library.videos.count, 1)
        XCTAssertEqual(try library.add(url: first.fileURL, title: "Existing local copy").id, first.id)
        XCTAssertEqual(library.videos.count, 1)
    }

    func testManifestUsesRelativeFilesAndRestoresAfterTheSandboxDirectoryMoves() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("download.mp4"))
        let old = root.appendingPathComponent("old-container")
        let library = ImportedVideoLibrary(directory: old)
        let item = try library.add(url: source, title: "Restored")
        let raw = try String(contentsOf: old.appendingPathComponent("index.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains(old.path)); XCTAssertFalse(raw.contains("storageDirectory"))
        let moved = root.appendingPathComponent("new-container")
        try FileManager.default.moveItem(at: old, to: moved)
        let restored = ImportedVideoLibrary(directory: moved)
        let found = try XCTUnwrap(restored.videos.first)
        XCTAssertEqual(found.id, item.id)
        XCTAssertEqual(found.fileURL, moved.appendingPathComponent(item.fileName))
        XCTAssertTrue(FileManager.default.fileExists(atPath: found.fileURL.path))
    }

    func testSignedCDNURLsAreNotPersistedAsOriginalSocialLinks() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("download.mp4"))
        let storage = root.appendingPathComponent("ImportedVideos")
        let library = ImportedVideoLibrary(directory: storage)
        let item = try library.add(url: source, title: "Video",
            sourceURL: URL(string: "https://cdn.example.test/video.mp4?signature=private-value"), duration: .nan)
        XCTAssertNil(item.sourceURL); XCTAssertNil(item.duration)
        XCTAssertFalse(try String(contentsOf: storage.appendingPathComponent("index.json"), encoding: .utf8).contains("private-value"))
    }

    func testLegacyRecoveryCopiesBothOldFoldersOnceAndDoesNotResurrectDeletedImports() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let oldRemote = root.appendingPathComponent("SourceVideos"), oldLocal = root.appendingPathComponent("RoastImports")
        try FileManager.default.createDirectory(at: oldRemote, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oldLocal, withIntermediateDirectories: true)
        let remote = try fixture(oldRemote.appendingPathComponent("\(UUID()).mp4"))
        let local = try fixture(oldLocal.appendingPathComponent("\(UUID()).mov"))
        let storage = root.appendingPathComponent("ImportedVideos")
        let library = ImportedVideoLibrary(directory: storage, legacyDirectories: [oldRemote, oldLocal])
        await library.recoverLegacySources()
        XCTAssertEqual(library.videos.count, 2)
        XCTAssertTrue(library.videos.allSatisfy { $0.title == "Imported video" })
        XCTAssertEqual(try Data(contentsOf: remote), Data("original video fixture".utf8))
        XCTAssertEqual(try Data(contentsOf: local), Data("original video fixture".utf8))
        let deleted = try XCTUnwrap(library.videos.first)
        try library.delete(deleted)
        let restored = ImportedVideoLibrary(directory: storage, legacyDirectories: [oldRemote, oldLocal])
        await restored.recoverLegacySources()
        XCTAssertEqual(restored.videos.count, 1)
        XCTAssertFalse(restored.videos.contains(where: { $0.id == deleted.id }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: remote.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
    }

    func testAnUnindexedOwnedVideoIsRecoveredWithoutMovingOrDeletingIt() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("ImportedVideos")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let jobID = UUID()
        let orphan = try fixture(storage.appendingPathComponent("\(jobID).mp4"))
        let library = ImportedVideoLibrary(directory: storage)
        XCTAssertEqual(library.videos.count, 1); XCTAssertEqual(library.videos.first?.id, jobID)
        XCTAssertEqual(library.videos.first?.fileURL, orphan)
        let restored = ImportedVideoLibrary(directory: storage)
        XCTAssertEqual(restored.videos.count, 1)
        XCTAssertEqual(try Data(contentsOf: orphan), Data("original video fixture".utf8))
    }

    func testFailedIndexCommitRollsBackOnlyTheNewCopy() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("download.mp4"))
        let storage = root.appendingPathComponent("ImportedVideos")
        let library = ImportedVideoLibrary(directory: storage)
        try FileManager.default.removeItem(at: storage.appendingPathComponent("index.json"))
        try FileManager.default.createDirectory(at: storage.appendingPathComponent("index.json"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try library.add(url: source, title: "Do not lose the source"))
        XCTAssertTrue(library.videos.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data("original video fixture".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: storage.path).contains(where: { $0.hasSuffix(".mp4") || $0.hasSuffix(".importing") }))
    }

    func testDeletingAnImportDoesNotDeleteTheOriginalOrADraftPinnedCopy() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("download.mp4"))
        let storage = root.appendingPathComponent("ImportedVideos")
        let library = ImportedVideoLibrary(directory: storage)
        let item = try library.add(url: source, title: "Original")
        let draftCopy = root.appendingPathComponent("draft-source.mp4")
        try FileManager.default.copyItem(at: item.fileURL, to: draftCopy)
        try library.delete(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("original video fixture".utf8))
        XCTAssertEqual(try Data(contentsOf: draftCopy), Data("original video fixture".utf8))
        XCTAssertTrue(ImportedVideoLibrary(directory: storage).videos.isEmpty)
    }

    func testUnsafeMissingAndSymlinkedManifestEntriesCannotHideAValidImport() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root.appendingPathComponent("outside.mp4"))
        let storage = root.appendingPathComponent("ImportedVideos")
        let library = ImportedVideoLibrary(directory: storage)
        let valid = try library.add(url: source, title: "Keep")
        let index = storage.appendingPathComponent("index.json")
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [[String: Any]])
        for name in ["../outside.mp4", "linked.mp4", "missing.mp4"] {
            var item = try XCTUnwrap(records.first)
            item["id"] = UUID().uuidString; item["fileName"] = name
            records.append(item)
        }
        try FileManager.default.createSymbolicLink(at: storage.appendingPathComponent("linked.mp4"), withDestinationURL: source)
        try JSONSerialization.data(withJSONObject: records).write(to: index)
        let restored = ImportedVideoLibrary(directory: storage)
        XCTAssertEqual(restored.videos.map(\.id), [valid.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImportedVideoTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @discardableResult private func fixture(_ url: URL) throws -> URL {
        try Data("original video fixture".utf8).write(to: url)
        return url
    }
}
