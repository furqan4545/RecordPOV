import Foundation
import XCTest
@testable import Roast

final class ImportJournalRestorationTests: XCTestCase {
    private struct Record: Codable, Equatable { let id: UUID; let stage: String }

    func testRestoredImportsDoNotClaimToDownloadBeforeMediaHasResolved() {
        for stage in ["resolving", "downloading", "preparing"] {
            XCTAssertEqual(VideoLinkLoadingPhase.resuming(hasResolvedMedia: false, stage: stage), .preparing)
        }
        XCTAssertEqual(VideoLinkLoadingPhase.resuming(hasResolvedMedia: true, stage: "downloading"), .downloading)
        XCTAssertEqual(VideoLinkLoadingPhase.resuming(hasResolvedMedia: true, stage: "preparing"), .loading)
    }

    func testLockedStorageDefersEvenWhenTheJournalAppearsMissing() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("pending.json")
        guard case .deferred = MediaImportJournal.read(Record.self, from: file, protectedDataAvailable: false) else {
            return XCTFail("A locked container must not authorize pruning OS transfers.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testMissingIsReportedOnlyAfterProtectedDataBecomesAvailable() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        guard case .missing = MediaImportJournal.read(Record.self, from: folder.appendingPathComponent("pending.json"), protectedDataAvailable: true) else {
            return XCTFail("An accessible, absent journal is an explicit missing result.")
        }
    }

    func testAValidJournalRestoresWithoutRewritingItsBytes() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("pending.json")
        let record = Record(id: UUID(), stage: "downloading")
        let bytes = try JSONEncoder().encode(record)
        try bytes.write(to: file)
        guard case .loaded(let loaded) = MediaImportJournal.read(Record.self, from: file, protectedDataAvailable: true) else {
            return XCTFail("The persisted job must be restored.")
        }
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testCorruptAndSchemaInvalidJournalsStayUnreadableAndAreKept() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("pending.json")
        for bytes in [Data("partial JSON {".utf8), Data(#"{"id":"not-a-uuid","stage":"downloading"}"#.utf8)] {
            try bytes.write(to: file)
            guard case .unreadable = MediaImportJournal.read(Record.self, from: file, protectedDataAvailable: true) else {
                return XCTFail("A decode failure must not be treated as no pending transfer.")
            }
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testAnUnreadableFilesystemObjectIsNotClassifiedAsAnAbsentJournal() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("pending.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        guard case .unreadable = MediaImportJournal.read(Record.self, from: file, protectedDataAvailable: true) else {
            return XCTFail("A filesystem read error must preserve existing transfer ownership.")
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testJournalWriteFailurePropagatesInsteadOfClaimingADurableTransfer() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("transfers.json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        XCTAssertThrowsError(try MediaImportJournal.write(["state": "running"], to: destination))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testAnEncodingFailurePreservesThePreviouslyCommittedJournal() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("transfers.json")
        try MediaImportJournal.write(["state": "running"], to: file)
        let committed = try Data(contentsOf: file)
        XCTAssertThrowsError(try MediaImportJournal.write(["invalid": Double.nan], to: file))
        XCTAssertEqual(try Data(contentsOf: file), committed)
    }

    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportJournalTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
