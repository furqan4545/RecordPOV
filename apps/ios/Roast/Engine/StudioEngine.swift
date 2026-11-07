import AVFoundation
import CoreImage
import ImageIO
import Observation
import SwiftUI
import UIKit

/// The studio's native capture/composition boundary. Preview and export use the
/// same pixel compositor, so camera placement never changes when a take is saved.
@MainActor
@Observable
final class StudioEngine {
    var previewFrame: UIImage?
    var isCameraEnabled = false
    private(set) var isSwitchingCamera = false
    private(set) var cameraPosition: AVCaptureDevice.Position = .front
    var isRecording = false
    var isStarting = false
    private(set) var countdownRemaining: Int?
    var isCountingDown: Bool { countdownRemaining != nil }
    var isFinalizing = false
    var elapsed: TimeInterval = 0
    var errorMessage: String?
    var statusMessage: String?
    var cameraAvailable: Bool
    var isSourcePlaying = false
    var sourceDuration: Double = 0
    var sourceTime: Double = 0
    var sourceTitle = "Choose a video or photo"
    var hasVideoSource = false
    var pip = PiPTransform()
    var isCameraFullScreen: Bool { pip.isFullScreen }
    var sourceAspectRatio: Double {
        guard let extent = sourceFrame?.extent, extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { return 9.0 / 16.0 }
        return extent.width / extent.height
    }

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let frames: StudioFramePipeline
    @ObservationIgnored private let capture: StudioCameraCapture
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var isRendering = false
    @ObservationIgnored private var sourceFrame: CIImage?
    @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private var sourceURL: URL?
    @ObservationIgnored private var sourceTransform = CGAffineTransform.identity
    @ObservationIgnored private var sourceLoadID = UUID()
    @ObservationIgnored private var seekID = UUID()
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var recordHostStart: Double?
    @ObservationIgnored private var sourceAudioTimeline = StudioSourceAudioTimeline()
    @ObservationIgnored private var scopedURLs: [URL] = []
    @ObservationIgnored private var downloadedSources: [URL: URL] = [:]
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var closeRequested = false
    @ObservationIgnored private var microphoneEnabled = false
    @ObservationIgnored private let microphoneSession = StudioMicrophoneSession()
    @ObservationIgnored private var audioRouteTask: Task<Void, Never>?
    @ObservationIgnored private var recordingStartGate = RecordingStartGate()
    @ObservationIgnored private var countdownTask: Task<Void, Error>?
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?
    @ObservationIgnored private var sourceEndObserver: NSObjectProtocol?
    @ObservationIgnored private var audioRouteObserver: NSObjectProtocol?
    @ObservationIgnored private var didApplyDefaultCamera = false

    init() {
        let frames = StudioFramePipeline()
        self.frames = frames
        self.capture = StudioCameraCapture(frames: frames)
        cameraAvailable = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .front) != nil
            || AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
        capture.onStatus = { [weak self] message, isError in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if isError { self.errorMessage = message }
                else if let message { self.statusMessage = message }
                else if self.statusMessage == "Camera or microphone is temporarily unavailable." {
                    self.statusMessage = nil
                }
            }
        }
        player.actionAtItemEnd = .pause
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancelCountdown() }
        }
        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.microphoneEnabled, !self.closed else { return }
                self.audioRouteTask?.cancel()
                self.audioRouteTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.microphoneSession.verifyEchoCancellation()
                    guard !Task.isCancelled, self.microphoneEnabled, !self.closed else { return }
                    self.updateEchoGuidance()
                }
            }
        }
        sourceEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, !self.closed,
                      let item = notification.object as? AVPlayerItem,
                      self.player.currentItem === item else { return }
                self.sourceDidReachEnd()
            }
        }
        renderTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                self?.renderTick()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    func loadVideo(_ url: URL, title: String) async throws {
        if isStarting { cancelCountdown() }
        let requestID = UUID()
        sourceLoadID = requestID
        let scoped = url.startAccessingSecurityScopedResource()
        if scoped { scopedURLs.append(url) }
        do {
            let localURL = try await localVideoURL(url)
            let asset = AVURLAsset(url: localURL)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw StudioCaptureError.emptyRecording
            }
            let duration = try await asset.load(.duration).seconds
            let transform = try await track.load(.preferredTransform)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 1280)
            let thumbnail = try? await generator.image(at: .zero)
            guard sourceLoadID == requestID, !closed else { throw CancellationError() }

            flushSourceAudio()
            player.pause()
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            let item = AVPlayerItem(asset: asset)
            item.add(output)
            player.replaceCurrentItem(with: item)
            videoOutput = output
            sourceURL = localURL
            sourceTransform = transform
            sourceFrame = thumbnail.map { CIImage(cgImage: $0.image) }
            sourceDuration = duration.isFinite ? max(0, duration) : 0
            sourceTime = 0
            sourceTitle = title
            hasVideoSource = true
            isSourcePlaying = false
            isSeeking = false
            errorMessage = nil
            statusMessage = "Video ready. Play or pause it while you record."
            output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
            sourceAudioTimeline.discontinuity()
        } catch {
            if scoped {
                url.stopAccessingSecurityScopedResource()
                if let index = scopedURLs.lastIndex(of: url) { scopedURLs.remove(at: index) }
            }
            throw error
        }
    }

    func loadImage(_ image: UIImage, title: String) {
        if isStarting { cancelCountdown() }
        sourceLoadID = UUID()
        flushSourceAudio()
        player.pause()
        player.replaceCurrentItem(with: nil)
        videoOutput = nil
        sourceURL = nil
        sourceTime = 0
        sourceDuration = 0
        isSourcePlaying = false
        isSeeking = false
        hasVideoSource = false
        sourceTitle = title
        sourceFrame = image.studioCIImage
        sourceAudioTimeline.discontinuity()
        statusMessage = "Background ready."
        errorMessage = nil
    }

    /// Called once when a person enters Studio. Creating an engine for previews,
    /// tests, or diagnostics never activates capture by itself.
    func startDefaultCameraIfNeeded() async {
        guard !didApplyDefaultCamera, !closed, !closeRequested else { return }
        didApplyDefaultCamera = true
        guard cameraAvailable else { return }
        await enableCamera()
    }

    func enableCamera() async {
        didApplyDefaultCamera = true
        guard !closed, !closeRequested, !isSwitchingCamera, !isStarting, !isFinalizing else { return }
        isSwitchingCamera = true
        defer { isSwitchingCamera = false }
        guard cameraAvailable else {
            #if targetEnvironment(simulator)
            errorMessage = "The simulator has no camera. Use an iPhone to record your reaction."
            #else
            errorMessage = "This device does not have an available camera."
            #endif
            return
        }
        guard await cameraPermission() else {
            errorMessage = "Allow camera access in Settings to record your reaction."
            return
        }
        guard !closed, !closeRequested, !Task.isCancelled else { return }
        do {
            capture.setPreferredLayout(pip.layout, isFullScreen: pip.isFullScreen)
            try await capture.setCamera(enabled: true, position: cameraPosition)
            guard !closed, !closeRequested else { capture.shutdown(); return }
            guard !Task.isCancelled else {
                try? await capture.setCamera(enabled: false)
                return
            }
            isCameraEnabled = true
            errorMessage = nil
            statusMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disableCamera() {
        guard !closed, !isSwitchingCamera, !isStarting, !isFinalizing else { return }
        didApplyDefaultCamera = true
        isSwitchingCamera = true
        isCameraEnabled = false
        pip.isFullScreen = false
        frames.clearCamera()
        Task {
            defer { isSwitchingCamera = false }
            do { try await capture.setCamera(enabled: false) }
            catch { if !closed { errorMessage = error.localizedDescription } }
        }
        if statusMessage == "Finding you…" { statusMessage = nil }
    }

    func switchCamera() async {
        guard isCameraEnabled, !closed, !closeRequested, !isSwitchingCamera,
              !isStarting, !isFinalizing else { return }
        isSwitchingCamera = true
        defer { isSwitchingCamera = false }
        let next: AVCaptureDevice.Position = cameraPosition == .front ? .back : .front
        do {
            capture.setPreferredLayout(pip.layout, isFullScreen: pip.isFullScreen)
            try await capture.setCamera(enabled: true, position: next)
            guard !closed, !closeRequested else { capture.shutdown(); return }
            cameraPosition = next
            errorMessage = nil
        } catch { if !closed { errorMessage = error.localizedDescription } }
    }

    #if DEBUG
    /// Explicit device check: camera metadata only, with no recording or microphone.
    static func runCameraDiagnostics() async {
        let runID = ProcessInfo.processInfo.environment["ROAST_DIAGNOSTIC_RUN_ID"] ?? UUID().uuidString
        func writeProgress(_ phase: String) {
            let progress: [String: Any] = ["runIdentifier": runID, "phase": phase,
                                           "timestamp": ISO8601DateFormatter().string(from: .now)]
            if let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
               let data = try? JSONSerialization.data(withJSONObject: progress, options: [.sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("CameraDiagnostic.json"), options: .atomic)
            }
            print("ROAST_CAMERA_DIAGNOSTIC \(phase)")
        }
        writeProgress("creatingEngine")
        let engine = StudioEngine()
        defer { engine.close() }
        // No segmentation or recording is needed to inspect camera metadata.
        engine.pip.style = .square
        writeProgress("engineCreated")
        var stages: [[String: Any]] = []
        var lastRevision: Int64 = -1
        for (index, expected) in ["front", "back", "front"].enumerated() {
            writeProgress("configuring_\(expected)_\(index)")
            if index == 0 { await engine.enableCamera() }
            else { await engine.switchCamera() }
            writeProgress("waitingForFrames_\(expected)_\(index)")
            var snapshot: [String: Any] = [:]
            for _ in 0..<40 {
                snapshot = await engine.capture.debugCameraSnapshot()
                if snapshot["bufferAvailable"] as? Bool == true,
                   (snapshot["bufferRevision"] as? Int64 ?? 0) >= lastRevision + 6 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            snapshot["expectedPosition"] = expected
            snapshot["enginePosition"] = engine.cameraPosition == .front ? "front" : "back"
            snapshot["engineEnabled"] = engine.isCameraEnabled
            if let error = engine.errorMessage { snapshot["error"] = error }
            let revision = snapshot["bufferRevision"] as? Int64 ?? 0
            snapshot["passed"] = snapshot["selectedPosition"] as? String == expected
                && snapshot["connectionMatchesSelectedInput"] as? Bool == true
                && snapshot["connectionActive"] as? Bool == true
                && snapshot["connectionEnabled"] as? Bool == true
                && snapshot["sessionRunning"] as? Bool == true
                && snapshot["bufferAvailable"] as? Bool == true
                && revision >= lastRevision + 6
                && snapshot["connectionMirrored"] as? Bool == (expected == "front")
                && engine.errorMessage == nil
            lastRevision = revision
            stages.append(snapshot)
        }
        let layouts: [(String, StudioLayout, Bool, Bool)] = [
            ("frontSplit", .split, false, true),
            ("frontFullScreen", .split, true, false),
            ("frontRestoreSplit", .split, false, true),
            ("frontStage", .cameraMain, false, false),
            ("frontPiP", .pip, false, false),
        ]
        for (label, layout, fullScreen, landscape) in layouts {
            writeProgress("configuring_\(label)")
            var pip = engine.pip
            pip.layout = layout
            pip.isFullScreen = fullScreen
            engine.setPiP(pip)
            let width = landscape ? 1280 : 720
            let height = landscape ? 720 : 1280
            #if os(iOS) && !targetEnvironment(macCatalyst)
            let expectedAspect = (landscape ? AVCaptureDevice.AspectRatio.ratio16x9 : .ratio9x16).rawValue
            let transposedAspect = (landscape ? AVCaptureDevice.AspectRatio.ratio9x16 : .ratio16x9).rawValue
            #else
            let expectedAspect = landscape ? "16x9" : "9x16"
            let transposedAspect = landscape ? "9x16" : "16x9"
            #endif
            func matches(_ snapshot: [String: Any]) -> Bool {
                let transposed = snapshot["dynamicAxesTransposed"] as? Bool == true
                let applied = snapshot["aspectFirstAppliedTime"] as? Double ?? -1
                return snapshot["dynamicAspectConfigured"] as? Bool == true
                    && snapshot["aspectMappingResolved"] as? Bool == true
                    && snapshot["activeDynamicAspect"] as? String == (transposed ? transposedAspect : expectedAspect)
                    && snapshot["aspectUpdatePending"] as? Bool == false
                    && snapshot["aspectError"] as? String == ""
                    && snapshot["dynamicWidth"] as? Int == (transposed ? height : width)
                    && snapshot["dynamicHeight"] as? Int == (transposed ? width : height)
                    && snapshot["bufferWidth"] as? Int == width
                    && snapshot["bufferHeight"] as? Int == height
                    && applied >= 0 && (snapshot["bufferPresentationTime"] as? Double ?? -1) >= applied
                    && (snapshot["bufferRevision"] as? Int64 ?? 0) >= lastRevision + 6
            }
            var snapshot: [String: Any] = [:]
            for _ in 0..<40 {
                snapshot = await engine.capture.debugCameraSnapshot()
                if matches(snapshot) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            snapshot["stage"] = label
            snapshot["expectedPosition"] = "front"
            snapshot["expectedAspect"] = snapshot["dynamicAxesTransposed"] as? Bool == true ? transposedAspect : expectedAspect
            snapshot["expectedBufferWidth"] = width
            snapshot["expectedBufferHeight"] = height
            snapshot["expectedFullScreen"] = fullScreen
            snapshot["expectedLayout"] = layout.rawValue
            snapshot["passed"] = matches(snapshot)
                && snapshot["selectedPosition"] as? String == "front"
                && snapshot["connectionMatchesSelectedInput"] as? Bool == true
                && snapshot["connectionActive"] as? Bool == true
                && snapshot["connectionEnabled"] as? Bool == true
                && snapshot["sessionRunning"] as? Bool == true
                && snapshot["connectionMirrored"] as? Bool == true
                && engine.isCameraEnabled && engine.errorMessage == nil
            lastRevision = snapshot["bufferRevision"] as? Int64 ?? lastRevision
            stages.append(snapshot)
        }
        try? await engine.capture.setCamera(enabled: false)
        let afterStop = await engine.capture.debugCameraSnapshot()
        var result: [String: Any] = [
            "runIdentifier": runID,
            "timestamp": ISO8601DateFormatter().string(from: .now),
            "stages": stages,
            "expectedStageCount": 8,
            "passed": stages.count == 8 && stages.allSatisfy { $0["passed"] as? Bool == true }
                && afterStop["sessionRunning"] as? Bool == false
                && afterStop["cameraConfigured"] as? Bool == false,
            "microphoneEnabled": false,
            "mediaRecorded": false,
        ]
        result["afterStop"] = afterStop
        if let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("CameraDiagnostic.json"), options: .atomic)
        }
    }
    #endif

    func togglePlayback() {
        guard hasVideoSource, !isStarting, !isFinalizing, !closed else { return }
        flushSourceAudio()
        if isSourcePlaying {
            player.pause()
            isSourcePlaying = false
        } else {
            if sourceDuration > 0 && sourceTime >= sourceDuration - 0.04 { seek(to: 0) }
            player.play()
            isSourcePlaying = true
        }
        sourceAudioTimeline.discontinuity()
    }

    func seek(to seconds: Double) {
        guard hasVideoSource, !isStarting, !isFinalizing, !closed else { return }
        flushSourceAudio()
        sourceAudioTimeline.discontinuity()
        let target = min(max(0, seconds), sourceDuration)
        let id = UUID()
        seekID = id
        isSeeking = true
        sourceTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.seekID == id else { return }
                self.isSeeking = false
                if finished { self.sourceTime = target }
                self.sourceAudioTimeline.discontinuity()
            }
        }
    }

    func resetPiP() {
        let style = pip.style
        let framing = pip.framingScale
        let fullScreen = pip.isFullScreen
        let layout = pip.layout
        let splitRatio = pip.splitRatio
        let sourceOverlay = pip.sourceOverlay
        pip = PiPTransform()
        pip.style = style
        pip.framingScale = framing
        pip.isFullScreen = fullScreen
        pip.layout = layout
        pip.splitRatio = splitRatio
        pip.sourceOverlay = sourceOverlay
    }

    func toggleCameraFullScreen() {
        guard isCameraEnabled, !closed, !closeRequested, !isSwitchingCamera,
              !isStarting, !isFinalizing else { return }
        pip.isFullScreen.toggle()
        capture.setPreferredLayout(pip.layout, isFullScreen: pip.isFullScreen)
    }

    func setPiP(_ transform: PiPTransform) {
        let previousLayout = pip.layout
        let previousFullScreen = pip.isFullScreen
        var value = transform
        if value.layout != previousLayout, value.style == .cutout { value.style = .rounded }
        value.x = value.x.isFinite ? min(1, max(0, value.x)) : 0.74
        value.y = value.y.isFinite ? min(1, max(0, value.y)) : 0.75
        value.scale = value.scale.isFinite ? min(2.5, max(0.35, value.scale)) : 1
        value.rotation = value.rotation.isFinite ? value.rotation : 0
        value.framingScale = value.framingScale.isFinite ? min(2.5, max(0.55, value.framingScale)) : 1
        value.splitRatio = value.splitRatio.isFinite ? min(0.8, max(0.2, value.splitRatio)) : 0.7
        value.sourceOverlay.x = value.sourceOverlay.x.isFinite ? min(1, max(0, value.sourceOverlay.x)) : 0.76
        value.sourceOverlay.y = value.sourceOverlay.y.isFinite ? min(1, max(0, value.sourceOverlay.y)) : 0.23
        value.sourceOverlay.scale = value.sourceOverlay.scale.isFinite ? min(2.5, max(0.5, value.sourceOverlay.scale)) : 1
        value.sourceOverlay.rotation = value.sourceOverlay.rotation.isFinite ? value.sourceOverlay.rotation : 0
        pip = value
        if isCameraEnabled, previousLayout != value.layout || previousFullScreen != value.isFullScreen {
            capture.setPreferredLayout(value.layout, isFullScreen: value.isFullScreen)
        }
    }

    func startRecording(delaySeconds: Int = 3) async {
        guard !isStarting, !isRecording, !isFinalizing, !isSwitchingCamera, !closed, !closeRequested else { return }
        guard sourceFrame != nil || isCameraEnabled else {
            errorMessage = "Choose a background or enable your camera first."
            return
        }
        guard let attempt = recordingStartGate.begin() else { return }
        isStarting = true
        defer {
            recordingStartGate.finish(attempt)
            countdownTask = nil
            countdownRemaining = nil
            isStarting = false
        }
        errorMessage = nil
        statusMessage = nil
        elapsed = 0
        pauseSourcePlayback()
        var prepared = false
        do {
            let permission = await microphonePermission()
            try requireRecordingStart(attempt)
            guard permission else {
                errorMessage = "Allow microphone access in Settings to record your reaction."
                return
            }
            try microphoneSession.configureForRecording()
            try await capture.setMicrophone(enabled: true)
            microphoneEnabled = true
            try requireRecordingStart(attempt)
            _ = await microphoneSession.verifyEchoCancellation()
            try requireRecordingStart(attempt)
            updateEchoGuidance()
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RoastCaptures", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            try await frames.prepareRecording(to: url, microphone: true)
            prepared = true
            try requireRecordingStart(attempt)
            if hasVideoSource, sourceDuration > 0, sourceTime >= sourceDuration - 0.04 {
                let id = UUID()
                seekID = id
                isSeeking = true
                let finished = await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                if seekID == id { isSeeking = false }
                try requireRecordingStart(attempt)
                guard finished, seekID == id else { throw CancellationError() }
                sourceTime = 0
            }

            let task = Task { @MainActor [weak self] in
                try await RecordingCountdown.run(seconds: delaySeconds) { remaining in
                    self?.countdownRemaining = remaining
                }
            }
            countdownTask = task
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try requireRecordingStart(attempt)
            countdownRemaining = nil
            let hostTime = try await frames.beginPreparedRecording()
            try requireRecordingStart(attempt)
            recordHostStart = hostTime
            sourceAudioTimeline.reset()
            sourceAudioTimeline.discontinuity()
            elapsed = 0
            isRecording = true
            if hasVideoSource {
                player.play()
                isSourcePlaying = true
            }
            captureSourceAudio(at: 0)
            return
        } catch is CancellationError {
            // Canceling setup/countdown never creates a take or resumes playback.
        } catch {
            if !closed, recordingStartGate.isCurrent(attempt) {
                errorMessage = "Could not start recording: \(error.localizedDescription)"
            }
        }
        if prepared { frames.cancelRecording() }
        try? await capture.setMicrophone(enabled: false)
        microphoneEnabled = false
        microphoneSession.stopMonitoring()
        audioRouteTask?.cancel()
    }

    /// Also invalidates permission/setup work that is currently suspended.
    /// isStarting remains true until cleanup finishes, preventing a second start.
    func cancelCountdown() {
        guard isStarting else { return }
        recordingStartGate.cancel()
        countdownTask?.cancel()
        countdownRemaining = nil
    }

    private func requireRecordingStart(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard recordingStartGate.isCurrent(attempt), !closed, !closeRequested,
              UIApplication.shared.applicationState != .background else { throw CancellationError() }
    }

    private func pauseSourcePlayback() {
        flushSourceAudio()
        player.pause()
        isSourcePlaying = false
        sourceAudioTimeline.discontinuity()
    }

    /// Ending the source only holds its final frame; the take keeps its own clock.
    func sourceDidReachEnd() {
        pauseSourcePlayback()
        sourceTime = sourceDuration
    }

    func finishForEditing() async -> RecordingDraft? {
        guard let result = await finalizeRecording(mixedOutput: false) else { return nil }
        return result.draft
    }

    func finishRecording() async -> URL? {
        await finalizeRecording(mixedOutput: true)?.mixedURL
    }

    private func finalizeRecording(mixedOutput: Bool) async -> (draft: RecordingDraft, mixedURL: URL?)? {
        guard isRecording, !isFinalizing else { return nil }
        pauseSourcePlayback()
        let duration = recordingElapsed
        let microphoneRequired = microphoneEnabled
        elapsed = duration
        isRecording = false
        isFinalizing = true
        recordHostStart = nil
        sourceAudioTimeline.discontinuity()
        let slices = sourceAudioTimeline.slices
        var captureWasSaved = false
        defer {
            isFinalizing = false
            microphoneSession.stopMonitoring()
            audioRouteTask?.cancel()
        }
        do {
            let result = try await frames.finishRecording(at: duration)
            captureWasSaved = true
            try? await capture.setMicrophone(enabled: false)
            microphoneEnabled = false
            let draft = try await RecordingAudioComposer.makeDraft(captureURL: result.url,
                duration: result.duration, title: sourceTitle, sourceAudio: slices,
                microphoneRequired: microphoneRequired)
            try? FileManager.default.removeItem(at: result.url)
            var mixedURL: URL?
            if mixedOutput {
                let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Takes", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
                mixedURL = try await RecordingAudioComposer.exportMixed(draft, to: destination)
                // Compatibility callers receive one self-contained movie; an old
                // discard action must not leave its isolated microphone draft behind.
                try? FileManager.default.removeItem(at: draft.videoURL.deletingLastPathComponent())
            }
            elapsed = result.duration
            if statusMessage == nil || statusMessage == "Finding you…" {
                statusMessage = mixedOutput ? "Your video is ready." : "Your video is ready to edit."
            }
            return (draft, mixedURL)
        } catch {
            errorMessage = "Could not prepare the video: \(error.localizedDescription)"
            if captureWasSaved { appendStatus("Your captured video and microphone recording have been kept.") }
            try? await capture.setMicrophone(enabled: false)
            microphoneEnabled = false
            return nil
        }
    }

    /// Closing a studio never silently discards an active take.
    func close() {
        guard !closed, !closeRequested else { return }
        cancelCountdown()
        closeRequested = true
        if isRecording {
            Task { @MainActor in
                _ = await self.finishRecording()
                self.shutdown()
            }
        } else if isFinalizing {
            Task { @MainActor in
                while self.isFinalizing { try? await Task.sleep(for: .milliseconds(100)) }
                self.shutdown()
            }
        } else { shutdown() }
    }

    private func shutdown() {
        recordingStartGate.cancel()
        countdownTask?.cancel()
        countdownRemaining = nil
        closed = true
        renderTask?.cancel()
        renderTask = nil
        player.pause()
        isSourcePlaying = false
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let sourceEndObserver { NotificationCenter.default.removeObserver(sourceEndObserver) }
        if let audioRouteObserver { NotificationCenter.default.removeObserver(audioRouteObserver) }
        backgroundObserver = nil
        sourceEndObserver = nil
        audioRouteObserver = nil
        audioRouteTask?.cancel()
        microphoneSession.stopMonitoring()
        capture.shutdown()
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
        scopedURLs = []
        if !isFinalizing {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private var recordingElapsed: Double {
        guard let recordHostStart else { return elapsed }
        return max(0, CMClockGetTime(CMClockGetHostTimeClock()).seconds - recordHostStart)
    }

    private func renderTick() {
        guard !closed else { return }
        if hasVideoSource, !isSeeking {
            let time = player.currentTime()
            if time.seconds.isFinite { sourceTime = min(sourceDuration, max(0, time.seconds)) }
            if let output = videoOutput, output.hasNewPixelBuffer(forItemTime: time),
               let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                let image = CIImage(cvPixelBuffer: buffer).transformed(by: sourceTransform)
                sourceFrame = image.transformed(by: .init(translationX: -image.extent.minX,
                                                         y: -image.extent.minY))
            }
            if isSourcePlaying, sourceDuration > 0, sourceTime >= sourceDuration - 0.015, player.rate == 0 {
                sourceDidReachEnd()
            }
        }
        if isRecording {
            elapsed = recordingElapsed
            captureSourceAudio(at: elapsed)
        }
        guard !isRendering else { return }
        isRendering = true
        let request = StudioRenderRequest(source: sourceFrame, pip: pip,
            cameraEnabled: isCameraEnabled, recordingTime: isRecording ? elapsed : nil)
        frames.render(request) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isRendering = false
                guard !self.closed else { return }
                self.previewFrame = result.image
                if self.isCameraEnabled, self.pip.style == .cutout,
                   result.cameraPresent, !result.personDetected {
                    if self.statusMessage == nil { self.statusMessage = "Finding you…" }
                } else if self.statusMessage == "Finding you…" { self.statusMessage = nil }
                if let error = result.recordingError, self.isRecording {
                    self.errorMessage = "Recording stopped: \(error)"
                    self.pauseSourcePlayback()
                    self.isRecording = false
                    self.recordHostStart = nil
                    self.frames.cancelRecording()
                    Task {
                        try? await self.capture.setMicrophone(enabled: false)
                        self.microphoneEnabled = false
                        self.microphoneSession.stopMonitoring()
                        self.audioRouteTask?.cancel()
                    }
                }
            }
        }
    }

    private func cameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private func microphonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func localVideoURL(_ url: URL) async throws -> URL {
        guard !url.isFileURL else { return url }
        if let local = downloadedSources[url], FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        let (download, response) = try await URLSession.shared.download(from: url)
        if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            throw URLError(.badServerResponse)
        }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SourceVideos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suffix = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let destination = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
        try FileManager.default.moveItem(at: download, to: destination)
        downloadedSources[url] = destination
        return destination
    }

    private func flushSourceAudio() {
        if isRecording { captureSourceAudio(at: recordingElapsed) }
    }

    private func appendStatus(_ message: String) {
        if let current = statusMessage, !current.isEmpty {
            if !current.contains(message) { statusMessage = current + " " + message }
        } else { statusMessage = message }
    }

    private func updateEchoGuidance() {
        let warning = "Use headphones to keep the video sound out of your microphone."
        if microphoneSession.snapshot.needsHeadphonesGuidance {
            appendStatus(warning)
        } else if let current = statusMessage, current.contains(warning) {
            let remaining = current.replacingOccurrences(of: warning, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = remaining.isEmpty ? nil : remaining
        }
    }

    /// Original clip audio is rebuilt offline from actual player progress.
    private func captureSourceAudio(at outputTime: Double) {
        guard hasVideoSource, let url = sourceURL, !isSeeking else {
            sourceAudioTimeline.discontinuity()
            return
        }
        sourceAudioTimeline.capture(url: url, sourceTime: player.currentTime().seconds,
                                    outputTime: outputTime, playing: isSourcePlaying)
    }
}

private extension UIImage {
    var studioCIImage: CIImage? {
        let raw = ciImage ?? cgImage.map { CIImage(cgImage: $0) }
        let orientation: CGImagePropertyOrientation
        switch imageOrientation {
        case .up: orientation = .up
        case .upMirrored: orientation = .upMirrored
        case .down: orientation = .down
        case .downMirrored: orientation = .downMirrored
        case .left: orientation = .left
        case .leftMirrored: orientation = .leftMirrored
        case .right: orientation = .right
        case .rightMirrored: orientation = .rightMirrored
        @unknown default: orientation = .up
        }
        guard let image = raw?.oriented(orientation) else { return nil }
        return image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}
