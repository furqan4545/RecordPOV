import AVFoundation
import XCTest
@testable import Roast

final class StudioVideoPreparerTests: XCTestCase {
    func testRemoteVideoDownloadsOnceAndIsNativelyPreparedFromDurableStorage() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent("download.mov")
        let storage = root.appendingPathComponent("SourceVideos", isDirectory: true)
        try await AudioSignalFixtures.writeVideo(to: temporary, duration: 0.3)
        let counter = DownloadCounter()
        let result = try await StudioVideoPreparer.prepare(remote, directory: storage, download: { url in
            await counter.increment()
            return (temporary, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let count = await counter.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(result.url.isFileURL)
        XCTAssertEqual(result.url.deletingLastPathComponent(), storage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        let asset = AVURLAsset(url: result.url)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        result.discardBeforeLaunch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.url.path))
    }

    func testPreparingAnExistingLocalVideoNeverDownloadsOrDeletesTheOriginal() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("original.mov")
        try await AudioSignalFixtures.writeVideo(to: local, duration: 0.3)
        let result = try await StudioVideoPreparer.prepare(local, download: { _ in
            throw URLError(.unsupportedURL)
        })
        XCTAssertEqual(result.url, local)
        result.discardBeforeLaunch()
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
    }

    func testCancelDuringNativePreparationDiscardsOnlyTheUnlaunchedDownload() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent("download.mp4")
        let storage = root.appendingPathComponent("SourceVideos", isDirectory: true)
        try Data("synthetic cancellation fixture".utf8).write(to: temporary)
        let gate = ValidationGate()
        let source = remote
        let task = Task {
            try await StudioVideoPreparer.prepare(source, directory: storage, download: { url in
                (temporary, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, validate: { url in await gate.validate(url) })
        }
        let copiedURL = await gate.waitUntilStarted()
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedURL.path))
        task.cancel()
        await gate.finish()
        do {
            _ = try await task.value
            XCTFail("A canceled preparation must not launch the studio.")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copiedURL.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storage.path).isEmpty)
    }

    func testUnplayableDownloadedVideoIsRemovedInsteadOfOpeningStudio() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent("not-video.mp4")
        let storage = root.appendingPathComponent("SourceVideos", isDirectory: true)
        try Data("not a playable video".utf8).write(to: temporary)
        do {
            _ = try await StudioVideoPreparer.prepare(remote, directory: storage, download: { url in
                (temporary, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            XCTFail("A successful HTTP response must still pass native video preparation.")
        } catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storage.path).isEmpty)
    }

    private var remote: URL { URL(string: "https://media.example.test/v1/media/synthetic/file")! }
    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("VideoPreparation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
}

private actor DownloadCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor ValidationGate {
    private var startedURL: URL?
    private var waitingForStart: CheckedContinuation<URL, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    func validate(_ url: URL) async {
        await withCheckedContinuation { continuation in
            completion = continuation
            startedURL = url
            waitingForStart?.resume(returning: url)
            waitingForStart = nil
        }
    }
    func waitUntilStarted() async -> URL {
        if let startedURL { return startedURL }
        return await withCheckedContinuation { waitingForStart = $0 }
    }
    func finish() { completion?.resume(); completion = nil }
}
