import AVFoundation
import CoreImage
import UIKit
import XCTest
@testable import Roast

final class RecordingLifecycleTests: XCTestCase {
    func testCanceledPreparationCannotResumeOrClearANewerAttempt() throws {
        var gate = RecordingStartGate()
        let first = try XCTUnwrap(gate.begin())
        XCTAssertNil(gate.begin(), "A second tap must not replace preparation in progress.")
        gate.cancel()
        XCTAssertFalse(gate.isCurrent(first), "A late permission response cannot start a canceled take.")
        let second = try XCTUnwrap(gate.begin())
        gate.finish(first)
        XCTAssertTrue(gate.isCurrent(second), "Old cleanup must not invalidate a new recording.")
        gate.finish(second)
        XCTAssertNotNil(gate.begin())
    }

    @MainActor func testEveryCountdownNumberReceivesOneFullSecond() async throws {
        for seconds in [3, 5, 10] {
            var ticks: [Int] = []
            var waits: [Duration] = []
            var secondsAtTick: [Int] = []
            try await RecordingCountdown.run(seconds: seconds) {
                ticks.append($0)
                secondsAtTick.append(waits.count)
            } wait: { waits.append($0) }
            XCTAssertEqual(ticks, Array(stride(from: seconds, through: 1, by: -1)))
            XCTAssertEqual(secondsAtTick, Array(0..<seconds))
            XCTAssertEqual(waits, Array(repeating: .seconds(1), count: seconds))
        }
    }

    @MainActor func testOffDoesNotDisplayOrWaitForACountdown() async throws {
        var displayed = false
        var waited = false
        try await RecordingCountdown.run(seconds: 0) { _ in displayed = true }
            wait: { _ in waited = true }
        XCTAssertFalse(displayed)
        XCTAssertFalse(waited)
        XCTAssertEqual(RecordingCountdown.seconds(7), 3)
    }

    @MainActor func testCancellationDuringCountdownNeverReachesRecordingStart() async {
        let clock = SuspendedCountdownClock()
        var ticks: [Int] = []
        var recordingStarted = false
        let task = Task { @MainActor in
            try await RecordingCountdown.run(seconds: 3) { ticks.append($0) }
                wait: { try await clock.wait($0) }
            recordingStarted = true
        }
        while !(await clock.isWaiting) { await Task.yield() }
        task.cancel()
        do { try await task.value; XCTFail("Canceled countdown completed.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(ticks, [3])
        XCTAssertFalse(recordingStarted)
    }

    @MainActor func testSourceEndHoldsPreviewWithoutStoppingTheTake() {
        let engine = StudioEngine()
        defer { engine.isRecording = false; engine.close() }
        let lastFrame = UIImage()
        engine.previewFrame = lastFrame
        engine.hasVideoSource = true
        engine.sourceDuration = 8
        engine.sourceTime = 7.99
        engine.isSourcePlaying = true
        engine.isRecording = true
        engine.elapsed = 15
        engine.sourceDidReachEnd()
        XCTAssertFalse(engine.isSourcePlaying)
        XCTAssertEqual(engine.sourceTime, 8)
        XCTAssertTrue(engine.isRecording)
        XCTAssertFalse(engine.isFinalizing)
        XCTAssertEqual(engine.elapsed, 15)
        XCTAssertTrue(engine.previewFrame === lastFrame)
    }

    func testPreparedWriterCanBeCanceledAndReusedWithoutStartingATake() async throws {
        let frames = StudioFramePipeline()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { frames.cancelRecording(); try? FileManager.default.removeItem(at: folder) }
        let canceled = folder.appendingPathComponent("canceled.mov")
        try await frames.prepareRecording(to: canceled, microphone: false)
        frames.cancelRecording()
        await withCheckedContinuation { continuation in frames.queue.async { continuation.resume() } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: canceled.path))
        do { _ = try await frames.beginPreparedRecording(); XCTFail("Canceled writer started.") }
        catch { }
        try await frames.prepareRecording(to: folder.appendingPathComponent("replacement.mov"), microphone: false)
    }

    func testPreparedFramesAndElapsedTimeAreExcludedFromActualTake() async throws {
        let frames = StudioFramePipeline()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { frames.cancelRecording(); try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("take.mov")
        try await frames.prepareRecording(to: url, microphone: false)
        // An accidental pre-start timestamp must never become a recorded frame.
        await render(frames, at: 99)
        try await Task.sleep(for: .milliseconds(40))
        let earliestStart = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let start = try await frames.beginPreparedRecording()
        XCTAssertGreaterThanOrEqual(start, earliestStart)
        XCTAssertLessThanOrEqual(start, CMClockGetTime(CMClockGetHostTimeClock()).seconds)
        await render(frames, at: 0.1)
        let result = try await frames.finishRecording(at: 0.2)
        let duration = try await AVURLAsset(url: result.url).load(.duration).seconds
        XCTAssertGreaterThan(duration, 0.1)
        XCTAssertLessThan(duration, 0.4, "Preparation/countdown must not appear in the take timeline.")
    }

    private func render(_ frames: StudioFramePipeline, at seconds: Double) async {
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 720, height: 1280))
        await withCheckedContinuation { continuation in
            frames.render(StudioRenderRequest(source: source, pip: PiPTransform(), cameraEnabled: false,
                                               recordingTime: seconds)) { _ in continuation.resume() }
        }
    }
}

private actor SuspendedCountdownClock {
    private var continuation: CheckedContinuation<Void, Error>?
    var isWaiting: Bool { continuation != nil }

    func wait(_ duration: Duration) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: { Task { await self.cancel() } }
    }

    private func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
