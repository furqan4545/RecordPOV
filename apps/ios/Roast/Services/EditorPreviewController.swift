import AVFoundation
import Foundation
import Observation

/// Dragging uses the original capture as a muted, directly seekable proxy.
/// Only a committed edit builds the mixed/captioned composition.
@MainActor @Observable
final class EditorPreviewController {
    typealias Builder = @MainActor (RecordingDraft, TakeEdits) async throws -> EditorComposition
    typealias Seeker = @MainActor (Double, @escaping @MainActor (Bool) -> Void) -> Void
    typealias ActivateAudio = @MainActor () throws -> Void

    let player: AVPlayer
    private(set) var timeline: EditorTimeline
    private(set) var sourcePosition: Double
    private(set) var outputPosition = 0.0
    private(set) var isPlaying = false
    private(set) var isDragging = false
    private(set) var isRebuilding = false
    var errorMessage: String?

    var isPlaybackPending: Bool { playbackIntent && isRebuilding }
    var preparationMessage: String {
        if composition != nil { return "Updating preview…" }
        let hasAudio = draft.microphoneURL != nil || draft.sourceAudioURL != nil || edits.musicURL != nil
        return hasAudio ? "Preparing video and audio…" : "Preparing video preview…"
    }

    func isReady(for currentEdits: TakeEdits) -> Bool {
        !closed && !isRebuilding && !isDragging && composition != nil && composedEdits == currentEdits
    }

    @ObservationIgnored private let draft: RecordingDraft
    @ObservationIgnored private let rawAsset: AVURLAsset
    @ObservationIgnored private let rawItem: AVPlayerItem
    @ObservationIgnored private let build: Builder
    @ObservationIgnored private let seek: Seeker
    @ObservationIgnored private let activateAudio: ActivateAudio
    @ObservationIgnored private var edits: TakeEdits
    @ObservationIgnored private var composedEdits: TakeEdits?
    @ObservationIgnored private var buildingEdits: TakeEdits?
    @ObservationIgnored private var composition: EditorComposition?
    @ObservationIgnored private var buildTask: Task<EditorComposition, Error>?
    @ObservationIgnored private var rebuildID = UUID()
    @ObservationIgnored private var itemID = UUID()
    @ObservationIgnored private var rawPreview = true
    @ObservationIgnored private var seekInFlight = false
    @ObservationIgnored private var pendingSeek: Double?
    private var playbackIntent = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var periodicObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init(draft: RecordingDraft, edits: TakeEdits, player: AVPlayer = AVPlayer(),
         builder: @escaping Builder = EditorExporter.composition, seeker: Seeker? = nil,
         activateAudio: ActivateAudio? = nil) {
        self.draft = draft
        self.edits = edits
        self.player = player
        self.build = builder
        self.timeline = EditorTimeline(duration: draft.duration, edits: edits)
        self.sourcePosition = EditorTimelineEditing.boundedSourceTime(edits.trimStart, duration: draft.duration)
        let asset = AVURLAsset(url: draft.videoURL)
        self.rawAsset = asset
        self.rawItem = AVPlayerItem(asset: asset)
        self.seek = seeker ?? { seconds, completion in
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                Task { @MainActor in completion(finished) }
            }
        }
        self.activateAudio = activateAudio ?? {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        }
        player.actionAtItemEnd = .pause
        player.isMuted = true
        player.replaceCurrentItem(with: rawItem)
        periodicObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.observePlayback() }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    guard let self, !self.closed, let item = notification.object as? AVPlayerItem,
                          self.player.currentItem === item, !self.rawPreview,
                          self.isReady(for: self.edits) else { return }
                    self.pause()
                    self.outputPosition = self.timeline.duration
                    self.sourcePosition = self.timeline.sourceTime(atOutput: self.timeline.duration)
                }
            }
    }

    func prepare(edits: TakeEdits) async { await update(edits: edits) }

    func beginInteraction(atSource seconds: Double? = nil) {
        guard !closed else { return }
        errorMessage = nil
        if !isDragging {
            if !seekInFlight { observePlayback() }
            isDragging = true
            pause()
            rebuildID = UUID()
            buildTask?.cancel()
            buildTask = nil
            buildingEdits = nil
            isRebuilding = false
            if !rawPreview { replaceItem(rawItem, raw: true) }
            player.isMuted = true
        }
        seekSource(to: seconds ?? sourcePosition)
    }

    func seekSource(to seconds: Double) {
        guard !closed else { return }
        sourcePosition = EditorTimelineEditing.boundedSourceTime(seconds, duration: draft.duration)
        outputPosition = timeline.outputTime(atSource: sourcePosition)
        enqueueSeek(rawPreview ? sourcePosition : outputPosition)
    }

    func seekOutput(to seconds: Double) {
        guard !closed else { return }
        outputPosition = EditorTimelineEditing.boundedSourceTime(seconds, duration: timeline.duration)
        sourcePosition = timeline.sourceTime(atOutput: outputPosition)
        enqueueSeek(rawPreview ? sourcePosition : outputPosition)
    }

    func endInteraction(edits: TakeEdits) async {
        guard !closed else { return }
        isDragging = false
        await update(edits: edits)
    }

    func update(edits: TakeEdits) async {
        guard !closed, !Task.isCancelled else { return }
        self.edits = edits
        errorMessage = nil
        guard !isDragging else { return }
        if edits == composedEdits, let composition {
            rebuildID = UUID()
            buildTask?.cancel()
            buildTask = nil
            buildingEdits = nil
            isRebuilding = false
            if rawPreview { install(composition) }
            else if playbackIntent, !seekInFlight { player.play(); isPlaying = true }
            return
        }
        if isRebuilding, buildingEdits == edits, buildTask?.isCancelled == false { return }
        let id = UUID()
        rebuildID = id
        buildingEdits = edits
        buildTask?.cancel()
        let task = Task { @MainActor in try await self.build(self.draft, edits) }
        buildTask = task
        isRebuilding = true
        player.pause()
        isPlaying = false
        errorMessage = nil
        defer {
            if rebuildID == id { isRebuilding = false; buildingEdits = nil; buildTask = nil }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard !closed, !isDragging, rebuildID == id else { return }
            composition = result
            composedEdits = edits
            errorMessage = nil
            // Installation may complete its seek synchronously. Publish the
            // completed build first so only that current item can resume Play.
            isRebuilding = false
            buildingEdits = nil
            buildTask = nil
            install(result)
        } catch is CancellationError { }
        catch {
            if !closed, !Task.isCancelled, rebuildID == id {
                pause()
                errorMessage = error.localizedDescription
            }
        }
    }

    func togglePlayback(edits currentEdits: TakeEdits? = nil) {
        guard !closed, !isDragging else { return }
        if let currentEdits { edits = currentEdits }
        if playbackIntent || player.rate > 0 { pause(); return }
        do { try activateAudio() }
        catch { errorMessage = "Preview sound couldn’t start. Try playing again."; return }
        playbackIntent = true
        let requestedEdits = edits
        if isRebuilding {
            if buildingEdits != requestedEdits { Task { await self.update(edits: requestedEdits) } }
            return
        }
        if rawPreview || composedEdits != requestedEdits {
            Task { await self.update(edits: requestedEdits) }
        } else if outputPosition >= timeline.duration - 0.04 { seekOutput(to: 0) }
        else if !seekInFlight { player.play(); isPlaying = true }
    }

    func pause() {
        playbackIntent = false
        player.pause()
        isPlaying = false
    }

    func close() {
        guard !closed else { return }
        closed = true
        pause()
        rebuildID = UUID()
        buildTask?.cancel()
        buildTask = nil
        itemID = UUID()
        player.currentItem?.cancelPendingSeeks()
        pendingSeek = nil
        seekInFlight = false
        if let periodicObserver { player.removeTimeObserver(periodicObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        periodicObserver = nil
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    private func install(_ composed: EditorComposition) {
        let source = sourcePosition
        timeline = composed.timeline
        outputPosition = timeline.outputTime(atSource: source)
        sourcePosition = timeline.sourceTime(atOutput: outputPosition)
        replaceItem(composed.playerItem(), raw: false)
        player.isMuted = false
        enqueueSeek(outputPosition)
    }

    private func replaceItem(_ item: AVPlayerItem, raw: Bool) {
        itemID = UUID()
        player.currentItem?.cancelPendingSeeks()
        seekInFlight = false
        pendingSeek = nil
        rawPreview = raw
        player.replaceCurrentItem(with: item)
    }

    private func enqueueSeek(_ seconds: Double) {
        let duration = rawPreview ? draft.duration : timeline.duration
        pendingSeek = min(max(0, seconds), max(0, duration - 1.0 / 600))
        drainSeek()
    }

    private func drainSeek() {
        guard !closed, !seekInFlight, let seconds = pendingSeek else { return }
        pendingSeek = nil
        seekInFlight = true
        let id = itemID
        seek(seconds) { [weak self] finished in
            guard let self, !self.closed, self.itemID == id else { return }
            self.seekInFlight = false
            if self.pendingSeek != nil { self.drainSeek() }
            else if finished, self.playbackIntent, !self.rawPreview,
                    self.isReady(for: self.edits) {
                self.player.play()
                self.isPlaying = true
            }
        }
    }

    private func observePlayback() {
        guard !closed, !isDragging, !seekInFlight, player.rate > 0 else { return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        if rawPreview {
            sourcePosition = EditorTimelineEditing.boundedSourceTime(current, duration: draft.duration)
            outputPosition = timeline.outputTime(atSource: sourcePosition)
        } else {
            outputPosition = EditorTimelineEditing.boundedSourceTime(current, duration: timeline.duration)
            sourcePosition = timeline.sourceTime(atOutput: outputPosition)
        }
        isPlaying = player.rate > 0
    }
}
