import Photos
import XCTest
@testable import Roast

final class PhotoLibrarySaverTests: XCTestCase {
    func testLegacyTakeWithoutPhotosFieldStillDecodes() throws {
        let legacy = Data(#"{"id":"1DCDFDA4-569E-46A1-B01B-BE7DD45F5FFA","fileName":"take.mp4","title":"Old take","createdAt":0,"duration":12,"kind":"Roast"}"#.utf8)
        let take = try JSONDecoder().decode(SavedTake.self, from: legacy)
        XCTAssertNil(take.photoAssetIdentifier)
        XCTAssertEqual(take.title, "Old take")
    }

    @MainActor func testFirstSaveRequestsPermissionAndReturnsCommittedIdentifier() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory)
        let writer = FakePhotoWriter(status: .notDetermined)
        let saver = PhotoLibrarySaver(writer: writer)

        let identifier = try await saver.saveVideo(at: source)

        XCTAssertEqual(identifier, "asset/fixture")
        XCTAssertEqual(writer.authorizationRequests, 1)
        XCTAssertEqual(writer.createdURLs, [source])
    }

    @MainActor func testDeniedAccessKeepsAppCopyAndRetryClearsFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory)
        let writer = FakePhotoWriter(status: .denied)
        let library = TakeLibrary(directory: directory.appendingPathComponent("Takes"),
                                  photoSaver: PhotoLibrarySaver(writer: writer))
        let take = try library.add(url: source, title: "Keep this", duration: 4)

        do {
            try await library.saveToPhotos(take)
            XCTFail("Denied Photos access must be reported")
        } catch { XCTAssertEqual(error as? PhotoSaveError, .permissionDenied) }

        XCTAssertFalse(library.isSavedToPhotos(take))
        XCTAssertFalse(library.isSavingToPhotos(take))
        XCTAssertNotNil(library.photoSaveError(for: take))
        XCTAssertEqual(writer.authorizationRequests, 0)
        XCTAssertTrue(writer.createdURLs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Takes/\(take.fileName)").path))

        writer.authorizationStatus = .authorized
        try await library.saveToPhotos(take)
        XCTAssertTrue(library.isSavedToPhotos(take))
        XCTAssertNil(library.photoSaveError(for: take))
        XCTAssertEqual(writer.createdURLs.count, 1)
    }

    @MainActor func testNilCreationRequestIsNotReportedAsSaved() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = FakePhotoWriter()
        writer.identifier = nil
        let library = TakeLibrary(directory: directory.appendingPathComponent("Takes"),
                                  photoSaver: PhotoLibrarySaver(writer: writer))
        let take = try library.add(url: fixture(in: directory), title: "Nil request", duration: 4)

        do {
            try await library.saveToPhotos(take)
            XCTFail("A nil asset request must fail even when Photos reports a successful transaction")
        } catch { XCTAssertEqual(error as? PhotoSaveError, .creationFailed) }

        XCTAssertFalse(library.isSavedToPhotos(take))
        XCTAssertNotNil(library.photoSaveError(for: take))
        XCTAssertEqual(library.takes.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Takes/\(take.fileName)").path))
    }

    @MainActor func testPhotosTransactionFailurePreservesTakeAndCanBeRetried() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = FakePhotoWriter()
        writer.creationError = CocoaError(.fileWriteOutOfSpace)
        let library = TakeLibrary(directory: directory.appendingPathComponent("Takes"),
                                  photoSaver: PhotoLibrarySaver(writer: writer))
        let take = try library.add(url: fixture(in: directory), title: "Retry", duration: 4)

        do {
            try await library.saveToPhotos(take)
            XCTFail("A failed transaction must fail")
        } catch { XCTAssertEqual(error as? PhotoSaveError, .creationFailed) }
        XCTAssertFalse(library.isSavedToPhotos(take))
        XCTAssertFalse(library.isSavingToPhotos(take))

        writer.creationError = nil
        try await library.saveToPhotos(take)
        XCTAssertTrue(library.isSavedToPhotos(take))
        XCTAssertNil(library.photoSaveError(for: take))
    }

    @MainActor func testConcurrentAutoSaveAndRetryShareOneTransaction() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = FakePhotoWriter()
        writer.holdCreation = true
        let library = TakeLibrary(directory: directory.appendingPathComponent("Takes"),
                                  photoSaver: PhotoLibrarySaver(writer: writer))
        let take = try library.add(url: fixture(in: directory), title: "One copy", duration: 4)
        let first = Task { try await library.saveToPhotos(take) }
        for _ in 0..<100 where writer.pendingCreation == nil { await Task.yield() }
        XCTAssertNotNil(writer.pendingCreation)
        XCTAssertTrue(library.isSavingToPhotos(take))
        XCTAssertFalse(library.isSavedToPhotos(take))

        var secondStarted = false
        let second = Task {
            secondStarted = true
            try await library.saveToPhotos(take)
        }
        for _ in 0..<100 where !secondStarted { await Task.yield() }
        XCTAssertEqual(writer.createdURLs.count, 1)
        XCTAssertThrowsError(try library.delete(take)) { error in
            XCTAssertEqual(error as? PhotoSaveError, .saveInProgress)
        }

        writer.finishCreation()
        try await first.value
        try await second.value
        XCTAssertEqual(writer.createdURLs.count, 1)
        XCTAssertTrue(library.isSavedToPhotos(take))
        XCTAssertFalse(library.isSavingToPhotos(take))
    }

    @MainActor func testSavedStatusSurvivesReopenAndStaleSnapshotCannotDuplicate() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("Takes")
        let writer = FakePhotoWriter()
        let library = TakeLibrary(directory: storage, photoSaver: PhotoLibrarySaver(writer: writer))
        let take = try library.add(url: fixture(in: directory), title: "Already saved", duration: 4)
        try await library.saveToPhotos(take)

        XCTAssertNil(take.photoAssetIdentifier, "The preview's original value is intentionally stale")
        XCTAssertTrue(library.isSavedToPhotos(take))
        XCTAssertEqual(library.takes.first?.photoAssetIdentifier, "asset/fixture")
        let reopened = TakeLibrary(directory: storage, photoSaver: PhotoLibrarySaver(writer: writer))
        XCTAssertTrue(reopened.isSavedToPhotos(take))
        try await reopened.saveToPhotos(take)
        XCTAssertEqual(writer.createdURLs.count, 1)
    }

    @MainActor func testReceiptRecoversSuccessfulSaveAfterIndexWriteFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("Takes")
        let index = storage.appendingPathComponent("index.json")
        let writer = FakePhotoWriter()
        let library = TakeLibrary(directory: storage, photoSaver: PhotoLibrarySaver(writer: writer))
        let take = try library.add(url: fixture(in: directory), title: "Recover status", duration: 4)
        let previousIndex = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)

        try await library.saveToPhotos(take)
        XCTAssertTrue(library.isSavedToPhotos(take))

        try FileManager.default.removeItem(at: index)
        try previousIndex.write(to: index)
        let reopened = TakeLibrary(directory: storage, photoSaver: PhotoLibrarySaver(writer: writer))
        XCTAssertTrue(reopened.isSavedToPhotos(take))
        try await reopened.saveToPhotos(take)
        XCTAssertEqual(writer.createdURLs.count, 1)
    }

    @MainActor func testMissingSourceFailsBeforePermissionOrPhotosChanges() async throws {
        let writer = FakePhotoWriter(status: .notDetermined)
        let saver = PhotoLibrarySaver(writer: writer)
        do {
            _ = try await saver.saveVideo(at: URL(fileURLWithPath: "/missing-roast-test-\(UUID()).mp4"))
            XCTFail("A missing file must not start a Photos transaction")
        } catch { XCTAssertEqual(error as? PhotoSaveError, .videoUnavailable) }
        XCTAssertEqual(writer.authorizationRequests, 0)
        XCTAssertTrue(writer.createdURLs.isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RoastPhotosTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fixture(in directory: URL) throws -> URL {
        let source = directory.appendingPathComponent("source.mp4")
        try Data("Fake video bytes: only the injected writer sees this file.".utf8).write(to: source)
        return source
    }
}

@MainActor
private final class FakePhotoWriter: PhotoLibraryWriting {
    var authorizationStatus: PHAuthorizationStatus
    var authorizationResult: PHAuthorizationStatus = .authorized
    private(set) var authorizationRequests = 0
    private(set) var createdURLs: [URL] = []
    var identifier: String? = "asset/fixture"
    var creationError: Error?
    var holdCreation = false
    private(set) var pendingCreation: CheckedContinuation<String?, Error>?

    init(status: PHAuthorizationStatus = .authorized) { authorizationStatus = status }

    func requestAuthorization() async -> PHAuthorizationStatus {
        authorizationRequests += 1
        authorizationStatus = authorizationResult
        return authorizationResult
    }

    func createVideo(at fileURL: URL) async throws -> String? {
        createdURLs.append(fileURL)
        if let creationError { throw creationError }
        if holdCreation {
            return try await withCheckedThrowingContinuation { pendingCreation = $0 }
        }
        return identifier
    }

    func finishCreation() {
        pendingCreation?.resume(returning: identifier)
        pendingCreation = nil
    }
}
