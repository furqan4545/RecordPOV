import AVFoundation
import XCTest
@testable import Roast

final class EditorPreviewControllerTests: XCTestCase {
    @MainActor func testChaseSeekingSkipsIntermediateTargetsAndKeepsLatestPosition() {
        let seeker = PreviewSeekSpy()
        let preview = controller(seeker: seeker)
        defer { preview.close() }
        preview.beginInteraction(atSource: 1)
        preview.seekSource(to: 2)
        preview.seekSource(to: 4)
        preview.seekSource(to: 7)
        XCTAssertEqual(seeker.targets, [1])
        XCTAssertEqual(preview.sourcePosition, 7)
        seeker.finishNext()
        XCTAssertEqual(seeker.targets, [1, 7])
        seeker.finishNext()
        XCTAssertEqual(preview.sourcePosition, 7)
        XCTAssertTrue(preview.isDragging)
        XCTAssertFalse(preview.isPlaying)
        XCTAssertTrue(preview.player.isMuted)
    }

    @MainActor func testDraggingNeverBuildsAndReleaseBuildsOnceAtCorrectSourceTime() async {
        let seeker = PreviewSeekSpy()
        var builds = 0
        let preview = controller(seeker: seeker) { draft, edits in
            builds += 1
            return previewComposition(edits, duration: draft.duration)
        }
        defer { preview.close() }
        var edits = TakeEdits(duration: 10)
        await preview.prepare(edits: edits)
        seeker.finishNext()
        preview.beginInteraction(atSource: 6)
        for start in [1.0, 2.0, 3.0, 4.0] {
            edits.trimStart = start
            await preview.update(edits: edits)
        }
        XCTAssertEqual(builds, 1)
        edits.trimEnd = 8
        await preview.endInteraction(edits: edits)
        XCTAssertEqual(builds, 2)
        XCTAssertEqual(preview.sourcePosition, 6)
        XCTAssertEqual(preview.outputPosition, 2)
        XCTAssertEqual(preview.timeline.duration, 4)
        XCTAssertFalse(preview.player.isMuted)
        XCTAssertFalse(preview.isPlaying)
        await preview.update(edits: edits)
        XCTAssertEqual(builds, 2, "The persistence task must not duplicate the release rebuild.")
    }

    @MainActor func testRestoringCachedValidEditsClearsPreviousErrorWithoutRebuilding() async {
        let seeker = PreviewSeekSpy()
        var builds = 0
        let preview = controller(seeker: seeker) { draft, edits in
            builds += 1
            if edits.trimEnd == 0 { throw EditorError.emptyEdit }
            return previewComposition(edits, duration: draft.duration)
        }
        defer { preview.close() }
        let valid = TakeEdits(duration: 10)
        await preview.prepare(edits: valid)
        var invalid = valid
        invalid.trimEnd = 0
        await preview.update(edits: invalid)
        XCTAssertNotNil(preview.errorMessage)
        await preview.update(edits: valid)
        XCTAssertNil(preview.errorMessage)
        XCTAssertEqual(preview.timeline.duration, 10)
        XCTAssertEqual(builds, 2)
    }

    @MainActor func testCanceledNonCancellationErrorNeverBecomesCurrentMessage() async throws {
        let builds = PreviewBuildQueue()
        let preview = controller(seeker: PreviewSeekSpy(), builder: builds.build)
        defer { preview.close() }
        let task = Task { await preview.prepare(edits: TakeEdits(duration: 10)) }
        try await waitUntil { builds.pending.count == 1 }
        task.cancel()
        builds.failNext()
        await task.value
        XCTAssertNil(preview.errorMessage)
        XCTAssertFalse(preview.isRebuilding)
    }

    @MainActor func testPreparationCanQueuePlaybackWithoutRestartingAndStillAllowsSeeking() async throws {
        let builds = PreviewBuildQueue()
        let seeker = PreviewSeekSpy()
        let draft = RecordingDraft(id: UUID(), videoURL: URL(fileURLWithPath: "/synthetic-preview.mov"),
            microphoneURL: nil, sourceAudioURL: nil, duration: 10, title: "Preparation")
        let edits = TakeEdits(duration: 10)
        let preview = EditorPreviewController(draft: draft, edits: edits, builder: builds.build,
            seeker: seeker.seek, activateAudio: {})
        defer { preview.close() }
        let preparing = Task { await preview.prepare(edits: edits) }
        try await waitUntil { builds.pending.count == 1 }
        XCTAssertTrue(preview.isRebuilding)
        XCTAssertFalse(preview.preparationMessage.isEmpty)
        XCTAssertFalse(preview.isReady(for: edits))
        preview.togglePlayback()
        XCTAssertTrue(preview.isPlaybackPending)
        preview.togglePlayback()
        XCTAssertFalse(preview.isPlaybackPending)
        preview.togglePlayback()
        preview.seekSource(to: 4)
        XCTAssertEqual(preview.sourcePosition, 4)
        XCTAssertEqual(builds.pending.count, 1, "Pressing Play during preparation must queue intent, not start another build.")
        builds.succeedNext()
        await preparing.value
        seeker.finishNext() // The raw item seek was invalidated by installing the prepared item.
        seeker.finishNext()
        XCTAssertTrue(preview.isReady(for: edits))
        XCTAssertFalse(preview.isPlaybackPending)
        XCTAssertTrue(preview.isPlaying)
        XCTAssertEqual(preview.sourcePosition, 4)
    }

    @MainActor func testSavingRequiresSuccessfulPreparationOfTheLatestEdits() async throws {
        let builds = PreviewBuildQueue()
        let preview = controller(seeker: PreviewSeekSpy(), builder: builds.build)
        defer { preview.close() }
        let initial = TakeEdits(duration: 10)
        XCTAssertFalse(preview.isReady(for: initial))
        let preparing = Task { await preview.prepare(edits: initial) }
        try await waitUntil { builds.pending.count == 1 }
        XCTAssertFalse(preview.isReady(for: initial))
        builds.succeedNext()
        await preparing.value
        XCTAssertTrue(preview.isReady(for: initial))
        var changed = initial
        changed.trimEnd = 6
        XCTAssertFalse(preview.isReady(for: changed), "A just-edited value must not use the old composition's readiness during debounce.")
        let updating = Task { await preview.update(edits: changed) }
        try await waitUntil { builds.pending.count == 1 }
        builds.failNext()
        await updating.value
        XCTAssertFalse(preview.isRebuilding)
        XCTAssertFalse(preview.isReady(for: changed))
        XCTAssertNotNil(preview.errorMessage, "Preparation failures remain visible while Save stays gated.")
    }

    @MainActor func testPlayRetriesFailedPreparationOnTheFirstTap() async throws {
        let builds = PreviewBuildQueue()
        let seeker = PreviewSeekSpy()
        let preview = controller(seeker: seeker, builder: builds.build)
        defer { preview.close() }
        let edits = TakeEdits(duration: 10)
        let preparing = Task { await preview.prepare(edits: edits) }
        try await waitUntil { builds.pending.count == 1 }
        preview.togglePlayback()
        XCTAssertTrue(preview.isPlaybackPending)
        builds.failNext()
        await preparing.value
        XCTAssertFalse(preview.isPlaying)
        XCTAssertNotNil(preview.errorMessage)
        preview.togglePlayback()
        try await waitUntil { builds.pending.count == 1 }
        XCTAssertTrue(preview.isPlaybackPending)
        builds.succeedNext()
        try await waitUntil { !preview.isRebuilding }
        seeker.finishNext()
        XCTAssertTrue(preview.isPlaying)
        XCTAssertNil(preview.errorMessage)
    }

    @MainActor func testPlayCommitsJustChangedEditsAndWaitsInsteadOfPlayingTheOlderComposition() async throws {
        let builds = PreviewBuildQueue()
        let seeker = PreviewSeekSpy()
        let draft = RecordingDraft(id: UUID(), videoURL: URL(fileURLWithPath: "/synthetic-preview.mov"),
            microphoneURL: nil, sourceAudioURL: nil, duration: 10, title: "Latest edits")
        let initial = TakeEdits(duration: 10)
        let preview = EditorPreviewController(draft: draft, edits: initial, builder: builds.build,
            seeker: seeker.seek, activateAudio: {})
        defer { preview.close() }
        let preparing = Task { await preview.prepare(edits: initial) }
        try await waitUntil { builds.pending.count == 1 }
        builds.succeedNext()
        await preparing.value
        seeker.finishNext()
        var changed = initial
        changed.trimEnd = 6
        // The tap can arrive before the view's debounced preview update.
        preview.togglePlayback(edits: changed)
        try await waitUntil { builds.pending.count == 1 }
        XCTAssertTrue(preview.isPlaybackPending)
        XCTAssertFalse(preview.isPlaying, "The previous composition must not start while newer edits are preparing.")
        XCTAssertEqual(builds.pending[0].edits, changed)
        builds.succeedNext()
        try await waitUntil { !preview.isRebuilding }
        seeker.finishNext()
        XCTAssertTrue(preview.isReady(for: changed))
        XCTAssertTrue(preview.isPlaying)
        XCTAssertEqual(preview.timeline.duration, 6)
    }

    @MainActor func testOldCompositionSeekCannotStartPlaybackWhileNewEditsBuild() async throws {
        let builds = PreviewBuildQueue()
        let seeker = PreviewSeekSpy()
        let preview = playbackController(builder: builds.build, seeker: seeker.seek)
        defer { preview.close() }
        let initial = TakeEdits(duration: 10)
        let preparing = Task { await preview.prepare(edits: initial) }
        try await waitUntil { builds.pending.count == 1 }
        builds.succeedNext()
        await preparing.value // Keep A's installation seek pending.
        var changed = initial
        changed.trimEnd = 6
        let rebuilding = Task { await preview.update(edits: changed) }
        try await waitUntil { builds.pending.count == 1 }
        preview.togglePlayback(edits: changed)
        seeker.finishNext() // A is still the current item while B is preparing.
        XCTAssertFalse(preview.isPlaying)
        XCTAssertTrue(preview.isPlaybackPending)
        builds.succeedNext()
        await rebuilding.value
        seeker.finishNext()
        XCTAssertTrue(preview.isPlaying)
        XCTAssertTrue(preview.isReady(for: changed))
        XCTAssertEqual(preview.timeline.duration, 6)
    }

    @MainActor func testOldCompositionEndCannotClearQueuedPlaybackOrMovePositionDuringRebuild() async throws {
        let builds = PreviewBuildQueue()
        let seeker = PreviewSeekSpy()
        let preview = playbackController(builder: builds.build, seeker: seeker.seek)
        defer { preview.close() }
        let initial = TakeEdits(duration: 10)
        let preparing = Task { await preview.prepare(edits: initial) }
        try await waitUntil { builds.pending.count == 1 }
        builds.succeedNext()
        await preparing.value
        seeker.finishNext()
        preview.seekSource(to: 2)
        seeker.finishNext()
        let oldItem = try XCTUnwrap(preview.player.currentItem)
        var changed = initial
        changed.trimStart = 1
        changed.trimEnd = 6
        let rebuilding = Task { await preview.update(edits: changed) }
        try await waitUntil { builds.pending.count == 1 }
        preview.togglePlayback(edits: changed)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
        try await Task.sleep(for: .milliseconds(20)) // Allow the observer's main-actor callback.
        XCTAssertTrue(preview.isPlaybackPending)
        XCTAssertFalse(preview.isPlaying)
        XCTAssertEqual(preview.sourcePosition, 2)
        XCTAssertEqual(preview.outputPosition, 2)
        builds.succeedNext()
        await rebuilding.value
        seeker.finishNext()
        XCTAssertTrue(preview.isPlaying)
        XCTAssertEqual(preview.sourcePosition, 2)
        XCTAssertEqual(preview.outputPosition, 1)
    }

    @MainActor func testQueuedPlaybackStartsWhenPreparedItemSeekCompletesSynchronously() async throws {
        let builds = PreviewBuildQueue()
        let preview = playbackController(builder: builds.build, seeker: { _, complete in complete(true) })
        defer { preview.close() }
        let edits = TakeEdits(duration: 10)
        let preparing = Task { await preview.prepare(edits: edits) }
        try await waitUntil { builds.pending.count == 1 }
        preview.togglePlayback(edits: edits)
        XCTAssertTrue(preview.isPlaybackPending)
        builds.succeedNext()
        await preparing.value
        XCTAssertTrue(preview.isReady(for: edits))
        XCTAssertTrue(preview.isPlaying)
        XCTAssertFalse(preview.isPlaybackPending)
    }

    @MainActor func testLateBuildCannotReplaceTheMutedDragProxy() async throws {
        let builds = PreviewBuildQueue()
        let preview = controller(seeker: PreviewSeekSpy(), builder: builds.build)
        defer { preview.close() }
        let task = Task { await preview.prepare(edits: TakeEdits(duration: 10)) }
        try await waitUntil { builds.pending.count == 1 }
        preview.beginInteraction(atSource: 7)
        let proxy = preview.player.currentItem
        builds.succeedNext()
        await task.value
        XCTAssertTrue(preview.player.currentItem === proxy)
        XCTAssertTrue(preview.player.isMuted)
        XCTAssertTrue(preview.isDragging)
        XCTAssertEqual(preview.sourcePosition, 7)
    }

    @MainActor func testNewBuildWinsWhenOldMetadataCompletesLast() async throws {
        let builds = PreviewBuildQueue()
        let preview = controller(seeker: PreviewSeekSpy(), builder: builds.build)
        defer { preview.close() }
        let first = Task { await preview.prepare(edits: TakeEdits(duration: 10)) }
        try await waitUntil { builds.pending.count == 1 }
        var changed = TakeEdits(duration: 10)
        changed.trimStart = 2
        changed.trimEnd = 9
        let second = Task { await preview.update(edits: changed) }
        try await waitUntil { builds.pending.count == 2 }
        builds.succeed(at: 1)
        await second.value
        let current = preview.player.currentItem
        builds.succeedNext()
        await first.value
        XCTAssertTrue(preview.player.currentItem === current)
        XCTAssertEqual(preview.timeline.duration, 7)
        XCTAssertNil(preview.errorMessage)
    }

    @MainActor func testCachedRestoreInvalidatesAPendingFailure() async throws {
        let builds = PreviewBuildQueue()
        let preview = controller(seeker: PreviewSeekSpy(), builder: builds.build)
        defer { preview.close() }
        let valid = TakeEdits(duration: 10)
        let initial = Task { await preview.prepare(edits: valid) }
        try await waitUntil { builds.pending.count == 1 }
        builds.succeedNext()
        await initial.value
        var other = valid
        other.trimEnd = 5
        let pending = Task { await preview.update(edits: other) }
        try await waitUntil { builds.pending.count == 1 }
        await preview.update(edits: valid)
        builds.failNext()
        await pending.value
        XCTAssertNil(preview.errorMessage)
        XCTAssertEqual(preview.timeline.duration, 10)
        XCTAssertFalse(preview.isRebuilding)
    }

    @MainActor func testOldItemSeekCompletionCannotUnlockTheNewItemSeek() async {
        let seeker = PreviewSeekSpy()
        let preview = controller(seeker: seeker)
        defer { preview.close() }
        await preview.prepare(edits: TakeEdits(duration: 10))
        preview.beginInteraction(atSource: 3)
        XCTAssertEqual(seeker.targets, [0, 3])
        seeker.finishNext() // Old composition seek, now canceled by replacement.
        preview.seekSource(to: 8)
        XCTAssertEqual(seeker.targets, [0, 3])
        seeker.finishNext()
        XCTAssertEqual(seeker.targets, [0, 3, 8])
    }

    @MainActor func testActualPlayerSeeksOriginalDuringDragWithoutRebuilding() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("synthetic.mov")
        try await AudioSignalFixtures.writeVideo(to: url, duration: 3)
        let draft = RecordingDraft(id: UUID(), videoURL: url, microphoneURL: nil,
                                   sourceAudioURL: nil, duration: 3, title: "Synthetic seek")
        var builds = 0
        var edits = TakeEdits(duration: 3)
        let preview = EditorPreviewController(draft: draft, edits: edits, builder: { draft, edits in
            builds += 1
            return try await EditorExporter.composition(draft: draft, edits: edits)
        })
        defer { preview.close(); try? FileManager.default.removeItem(at: folder) }
        await preview.prepare(edits: edits)
        preview.beginInteraction(atSource: 0)
        preview.seekSource(to: 1.2)
        try await waitUntil { abs(preview.player.currentTime().seconds - 1.2) < 0.05 }
        XCTAssertTrue(preview.isDragging)
        XCTAssertTrue(preview.player.isMuted)
        XCTAssertEqual(builds, 1)
        edits.trimStart = 0.5
        edits.trimEnd = 2.5
        await preview.endInteraction(edits: edits)
        try await waitUntil { abs(preview.player.currentTime().seconds - 0.7) < 0.05 }
        XCTAssertEqual(builds, 2)
        XCTAssertEqual(preview.sourcePosition, 1.2, accuracy: 0.001)
        XCTAssertEqual(preview.outputPosition, 0.7, accuracy: 0.001)
        XCTAssertFalse(preview.isPlaying)
    }

    @MainActor private func controller(seeker: PreviewSeekSpy,
        builder: @escaping EditorPreviewController.Builder = { draft, edits in previewComposition(edits, duration: draft.duration) }) -> EditorPreviewController {
        let draft = RecordingDraft(id: UUID(), videoURL: URL(fileURLWithPath: "/synthetic-preview.mov"),
                                   microphoneURL: nil, sourceAudioURL: nil, duration: 10, title: "Test")
        return EditorPreviewController(draft: draft, edits: TakeEdits(duration: 10), builder: builder, seeker: seeker.seek)
    }

    @MainActor private func playbackController(builder: @escaping EditorPreviewController.Builder,
        seeker: @escaping EditorPreviewController.Seeker) -> EditorPreviewController {
        let draft = RecordingDraft(id: UUID(), videoURL: URL(fileURLWithPath: "/synthetic-preview.mov"),
            microphoneURL: nil, sourceAudioURL: nil, duration: 10, title: "Queued playback")
        return EditorPreviewController(draft: draft, edits: TakeEdits(duration: 10),
            builder: builder, seeker: seeker, activateAudio: {})
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Preview did not reach the requested state within five seconds.")
    }
}

@MainActor private func previewComposition(_ edits: TakeEdits, duration: Double) -> EditorComposition {
    EditorComposition(asset: AVMutableComposition(), audioMix: AVMutableAudioMix(), videoComposition: nil,
                      timeline: EditorTimeline(duration: duration, edits: edits), retainedAssets: [])
}

@MainActor private final class PreviewSeekSpy {
    var targets: [Double] = []
    private var completions: [@MainActor (Bool) -> Void] = []
    func seek(_ seconds: Double, completion: @escaping @MainActor (Bool) -> Void) {
        targets.append(seconds)
        completions.append(completion)
    }
    func finishNext() { if !completions.isEmpty { completions.removeFirst()(true) } }
}

@MainActor private final class PreviewBuildQueue {
    struct Pending {
        let edits: TakeEdits
        let duration: Double
        let continuation: CheckedContinuation<EditorComposition, Error>
    }
    var pending: [Pending] = []
    func build(_ draft: RecordingDraft, _ edits: TakeEdits) async throws -> EditorComposition {
        try await withCheckedThrowingContinuation { pending.append(Pending(edits: edits, duration: draft.duration, continuation: $0)) }
    }
    func failNext() { pending.removeFirst().continuation.resume(throwing: EditorError.emptyEdit) }
    func succeedNext() { succeed(at: 0) }
    func succeed(at index: Int) {
        let request = pending.remove(at: index)
        request.continuation.resume(returning: previewComposition(request.edits, duration: request.duration))
    }
}
