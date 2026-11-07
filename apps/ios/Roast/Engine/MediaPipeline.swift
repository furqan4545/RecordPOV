import AVFoundation
import CoreImage
import CoreMedia
import UIKit

enum StudioCaptureError: LocalizedError {
    case cameraUnavailable
    case microphoneUnavailable
    case cannotConfigureCamera
    case cannotConfigureMicrophone
    case cannotCreateWriter
    case emptyRecording
    case exportUnavailable

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable: return "This device does not have an available camera."
        case .microphoneUnavailable: return "This device does not have an available microphone."
        case .cannotConfigureCamera: return "The camera could not be started."
        case .cannotConfigureMicrophone: return "The microphone could not be started."
        case .cannotCreateWriter: return "The video recorder could not be prepared."
        case .emptyRecording: return "The recording did not contain any video frames."
        case .exportUnavailable: return "The finished video could not be exported."
        }
    }
}

struct StudioRenderRequest {
    var source: CIImage?
    var pip: PiPTransform
    var cameraEnabled: Bool
    var recordingTime: Double?
}

struct StudioRenderResult {
    var image: UIImage?
    var cameraPresent: Bool
    var personDetected: Bool
    var recordingError: String?
}

struct StudioCaptureResult {
    var url: URL
    var duration: Double
}

/// Camera frames, segmentation, compositing and writer inputs share one serial queue.
/// Preview and recording share the same full-size composite and normalized geometry.
final class StudioFramePipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.roast.frames", qos: .userInteractive)
    static let canvas = CGRect(x: 0, y: 0, width: 720, height: 1280)

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let personMatte = PersonMatteProcessor()
    private var wasCutout = false
    private var cameraBuffer: CVPixelBuffer?
    private var cameraRevision: Int64 = 0
    private var cameraPresentationTime = CMTime.invalid
    private var lastComposite: CIImage?
    private var recorder: StudioAssetRecorder?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            cameraBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            cameraPresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            cameraRevision &+= 1
        } else if output is AVCaptureAudioDataOutput {
            recorder?.appendAudio(sampleBuffer)
        }
    }

    func clearCamera() {
        queue.async {
            self.cameraBuffer = nil
            self.cameraPresentationTime = .invalid
            self.personMatte.reset()
            self.wasCutout = false
        }
    }

    func render(_ request: StudioRenderRequest, completion: @escaping (StudioRenderResult) -> Void) {
        queue.async {
            autoreleasepool {
                let result = self.composite(request)
                self.lastComposite = result.image
                if let time = request.recordingTime {
                    self.recorder?.appendVideo(result.image, at: time, context: self.context,
                                               colorSpace: self.colorSpace)
                }
                let cgImage = self.context.createCGImage(result.image, from: Self.canvas,
                                                        format: .RGBA8, colorSpace: self.colorSpace)
                completion(StudioRenderResult(image: cgImage.map { UIImage(cgImage: $0) },
                                               cameraPresent: result.hasCamera,
                                               personDetected: result.hasPerson,
                                               recordingError: self.recorder?.errorMessage))
            }
        }
    }

    func prepareRecording(to url: URL, microphone: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard self.recorder == nil else { throw StudioCaptureError.cannotCreateWriter }
                    self.recorder = try StudioAssetRecorder(url: url, microphone: microphone, callbackQueue: self.queue)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func beginPreparedRecording() async throws -> Double {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard let recorder = self.recorder else { throw StudioCaptureError.cannotCreateWriter }
                    try recorder.start()
                    if let image = self.lastComposite {
                        recorder.appendVideo(image, at: 0, context: self.context, colorSpace: self.colorSpace)
                    }
                    continuation.resume(returning: recorder.hostStart.seconds)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func beginRecording(to url: URL, microphone: Bool) async throws -> Double {
        try await prepareRecording(to: url, microphone: microphone)
        do { return try await beginPreparedRecording() }
        catch { cancelRecording(); throw error }
    }

    func finishRecording(at time: Double) async throws -> StudioCaptureResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let recorder = self.recorder else {
                    continuation.resume(throwing: StudioCaptureError.emptyRecording)
                    return
                }
                self.recorder = nil
                if let image = self.lastComposite {
                    recorder.appendVideo(image, at: time, context: self.context, colorSpace: self.colorSpace)
                }
                recorder.finish(at: time) { continuation.resume(with: $0) }
            }
        }
    }

    func cancelRecording() {
        queue.async {
            self.recorder?.cancel()
            self.recorder = nil
        }
    }

    private func composite(_ request: StudioRenderRequest) -> (image: CIImage, hasCamera: Bool, hasPerson: Bool) {
        let wantsCutout = request.cameraEnabled && request.pip.style == .cutout
        if wantsCutout != wasCutout {
            personMatte.reset()
            wasCutout = wantsCutout
        }
        let canvas = Self.canvas
        let layout = request.cameraEnabled ? request.pip.layout : .pip
        let background = CIImage(color: CIColor(red: 0.047, green: 0.047, blue: 0.065)).cropped(to: canvas)
        var frame = background
        if !request.pip.isFullScreen || !request.cameraEnabled, let source = request.source,
           source.extent.width > 0, source.extent.height > 0 {
            switch layout {
            case .pip: frame = fit(source, into: canvas, fill: false).composited(over: frame)
            case .split:
                let top = StudioLayoutGeometry.splitRects(canvas: canvas, originalFraction: request.pip.splitRatio).source
                frame = splitOriginal(source, into: top).composited(over: frame)
            case .cameraMain: break
            }
        }
        func withOriginalOverlay(_ base: CIImage) -> CIImage {
            guard !request.pip.isFullScreen, layout == .cameraMain, let source = request.source else { return base }
            return self.originalOverlay(source, transform: request.pip.sourceOverlay, canvas: canvas)
                .composited(over: base).cropped(to: canvas)
        }
        guard request.cameraEnabled, let buffer = cameraBuffer else {
            return (withOriginalOverlay(frame).cropped(to: canvas), false, false)
        }
        var camera = CIImage(cvPixelBuffer: buffer)
        if request.pip.style == .cutout {
            guard let cutout = try? personMatte.cutout(from: buffer, revision: cameraRevision) else {
                return (withOriginalOverlay(frame).cropped(to: canvas), true, false)
            }
            camera = cutout
        }
        if request.pip.isFullScreen || layout == .cameraMain {
            let cameraRect = CameraFramingGeometry.contentRect(source: camera.extent.size,
                viewport: canvas.size, style: .square, framingScale: request.pip.framingScale)
            let fullScreen = fit(camera, into: cameraRect, fill: false).cropped(to: canvas)
            frame = fullScreen.composited(over: background).cropped(to: canvas)
            return (withOriginalOverlay(frame), true, true)
        }
        if layout == .split {
            let areas = StudioLayoutGeometry.splitRects(canvas: canvas, originalFraction: request.pip.splitRatio)
            let local = CGRect(origin: .zero, size: areas.camera.size)
            let cameraRect = CameraFramingGeometry.contentRect(source: camera.extent.size,
                viewport: local.size, style: .square, framingScale: request.pip.framingScale)
            let bottom = fit(camera, into: cameraRect, fill: false).cropped(to: local)
                .transformed(by: .init(translationX: areas.camera.minX, y: areas.camera.minY))
            frame = bottom.composited(over: frame)
            let line = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.12))
                .cropped(to: CGRect(x: canvas.minX, y: areas.source.minY - 1, width: canvas.width, height: 2))
            return (line.composited(over: frame).cropped(to: canvas), true, true)
        }
        let width = canvas.width * 0.34 * request.pip.scale
        let isTall = request.pip.style == .rounded || request.pip.style == .cutout
        let height = width * (isTall ? 1.30 : 1)
        let localRect = CGRect(x: 0, y: 0, width: width, height: height)
        let cameraRect = CameraFramingGeometry.contentRect(source: camera.extent.size,
            viewport: localRect.size, style: request.pip.style, framingScale: request.pip.framingScale)
        var patch = fit(camera, into: cameraRect, fill: false).cropped(to: localRect)
        if request.pip.style != .cutout {
            let radius: CGFloat = request.pip.style == .circle ? width / 2
                : (request.pip.style == .rounded ? width * 0.12 : 0)
            if radius > 0 { patch = rounded(patch, rect: localRect, radius: radius) }
        }
        patch = patch.transformed(by: .init(translationX: -width / 2, y: -height / 2))
            .transformed(by: .init(rotationAngle: -request.pip.rotation))
            .transformed(by: .init(translationX: canvas.width * request.pip.x,
                                  y: canvas.height * (1 - request.pip.y)))
        if request.pip.style != .cutout { frame = shadow(for: patch).composited(over: frame) }
        return (patch.composited(over: frame).cropped(to: canvas), true, true)
    }

    private func originalOverlay(_ source: CIImage, transform: SourceOverlayTransform, canvas: CGRect) -> CIImage {
        let rect = StudioLayoutGeometry.sourceOverlayRect(canvas: canvas,
            sourceAspectRatio: source.extent.width / max(1, source.extent.height), transform: transform)
        let local = CGRect(origin: .zero, size: rect.size)
        var patch = rounded(fit(source, into: local, fill: true).cropped(to: local),
                            rect: local, radius: min(14, local.width * 0.06))
        let angle = transform.rotation.isFinite ? transform.rotation : 0
        patch = patch.transformed(by: .init(translationX: -rect.width / 2, y: -rect.height / 2))
            .transformed(by: .init(rotationAngle: -angle))
            .transformed(by: .init(translationX: rect.midX, y: rect.midY))
        return patch.composited(over: shadow(for: patch)).cropped(to: canvas)
    }

    private func splitOriginal(_ source: CIImage, into pane: CGRect) -> CIImage {
        let content = StudioLayoutGeometry.splitSourceRect(source: source.extent.size, in: pane)
        let foreground = fit(source, into: content, fill: false).cropped(to: pane)
        guard pane.width - content.width > 0.5 || pane.height - content.height > 0.5 else {
            return foreground
        }

        // Blur only a small background copy. The original remains sharp and
        // complete, while the softened, dimmed copy fills aspect-ratio gaps.
        let renderScale = min(1, 192 / max(pane.width, pane.height))
        let smallPane = CGRect(x: 0, y: 0, width: pane.width * renderScale,
                               height: pane.height * renderScale)
        let blurred = fit(source, into: smallPane, fill: true).cropped(to: smallPane)
            .clampedToExtent().applyingGaussianBlur(sigma: 8).cropped(to: smallPane)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.55, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.55, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.55, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .transformed(by: .init(scaleX: 1 / renderScale, y: 1 / renderScale))
            .transformed(by: .init(translationX: pane.minX, y: pane.minY))
            .cropped(to: pane)
        return foreground.composited(over: blurred).cropped(to: pane)
    }

    private func rounded(_ image: CIImage, rect: CGRect, radius: CGFloat) -> CIImage {
        guard let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect), "inputRadius": radius, kCIInputColorKey: CIColor.white,
        ])?.outputImage?.cropped(to: rect) else { return image }
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: rect),
            kCIInputMaskImageKey: mask,
        ])
    }

    private func shadow(for image: CIImage) -> CIImage {
        let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": zero, "inputGVector": zero, "inputBVector": zero,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.38),
        ]).applyingGaussianBlur(sigma: 9).transformed(by: .init(translationX: 0, y: -5))
    }

    private func fit(_ image: CIImage, into rect: CGRect, fill: Bool) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = fill ? max(rect.width / extent.width, rect.height / extent.height)
            : min(rect.width / extent.width, rect.height / extent.height)
        return image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: .init(scaleX: scale, y: scale))
            .transformed(by: .init(translationX: rect.midX - extent.width * scale / 2,
                                  y: rect.midY - extent.height * scale / 2))
    }
}

/// AVCaptureSession configuration and startRunning must not block the UI thread.
final class StudioCameraCapture: @unchecked Sendable {
    var onStatus: ((String?, Bool) -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.roast.camera", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let frames: StudioFramePipeline
    private var observers: [NSObjectProtocol] = []
    private var isShutDown = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var rotationToken = UUID()
    private var aspectCalibration = CameraAspectCalibration()
    private var cameraSelectionID: UUID { aspectCalibration.generation }
    private var aspectRequestID: UUID { aspectCalibration.requestID }
    private var aspectCalibrationScheduled = false
    private var defaultConnectionRotation: CGFloat?
    private var prefersLandscape = false
    private var dynamicAspectConfigured = false
    private var aspectUpdatePending = false
    private var aspectError: String?

    init(frames: StudioFramePipeline) {
        self.frames = frames
        session.automaticallyConfiguresApplicationAudioSession = false
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(frames, queue: frames.queue)
        audioOutput.setSampleBufferDelegate(frames, queue: frames.queue)
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.videoInput != nil || self.audioInput != nil else { return }
                self.frames.clearCamera()
                self.onStatus?("Camera or microphone is temporarily unavailable.", false)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
        ) { [weak self] _ in self?.onStatus?(nil, false) })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                // An unused AVCaptureSession can report unavailable hardware in the
                // simulator. A photo/video preview must not surface a camera error
                // before the person has enabled a camera or microphone input.
                guard let self, self.videoInput != nil || self.audioInput != nil else { return }
                self.frames.clearCamera()
                self.onStatus?("Camera or microphone capture stopped. Enable your camera again before continuing.", true)
            }
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    /// Layout changes only crop the selected square sensor. They never rebuild
    /// the session, detach delegates, change microphone inputs, or restart capture.
    func setPreferredLayout(_ layout: StudioLayout, isFullScreen: Bool = false) {
        let landscape = layout == .split && !isFullScreen
        queue.async {
            guard !self.isShutDown, self.prefersLandscape != landscape else { return }
            self.prefersLandscape = landscape
            guard self.dynamicAspectConfigured, let device = self.videoInput?.device else { return }
            do { try self.requestPreferredAspectRatio(on: device) }
            catch {
                self.aspectUpdatePending = false
                self.aspectError = error.localizedDescription
                self.onStatus?("Camera framing couldn’t be changed. Your camera is still available.", false)
            }
        }
    }

    func setCamera(enabled: Bool, position: AVCaptureDevice.Position = .front) async throws {
        try await configure {
            self.trace("setCamera.begin enabled=\(enabled) position=\(position.rawValue)")
            let replacement: AVCaptureDeviceInput?
            if enabled {
                self.trace("discovery.begin")
                let device = position == .front
                    ? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .front)
                        ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                    : AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                self.trace("discovery.end type=\(device?.deviceType.rawValue ?? "none")")
                guard let device else {
                    throw StudioCaptureError.cameraUnavailable
                }
                self.trace("input.create.begin")
                replacement = try AVCaptureDeviceInput(device: device)
                self.trace("input.create.end")
            } else {
                replacement = nil
            }
            let previousInput = self.videoInput
            let previousPreset = self.session.sessionPreset
            let previousZoom = previousInput?.device.videoZoomFactor
            let previousFormat = previousInput?.device.activeFormat
            let previousMinimumFrameDuration = previousInput?.device.activeVideoMinFrameDuration
            let previousMaximumFrameDuration = previousInput?.device.activeVideoMaxFrameDuration
            let previousDynamicAspect = self.dynamicAspectConfigured
            let hadVideoOutput = self.session.outputs.contains(self.videoOutput)

            // Old-device callbacks must drain before a new camera is exposed. The
            // frame queue never synchronously calls the configuration queue.
            self.clearRotationCoordinator()
            self.invalidateAspectConfiguration()
            self.trace("frames.drain.begin")
            self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
            self.frames.clearCamera()
            self.frames.queue.sync {}
            self.trace("frames.drain.end")

            var configurationOpen = true
            self.trace("configuration.begin")
            self.session.beginConfiguration()
            do {
                if let old = previousInput { self.session.removeInput(old) }
                self.videoInput = nil
                // The old camera's preset must not prevent a different camera
                // from being attached. Choose the output preset after attaching.
                self.trace("preset.high.begin")
                if self.session.canSetSessionPreset(.high) { self.session.sessionPreset = .high }
                self.trace("preset.high.end")
                if let replacement {
                    self.trace("input.attach.begin")
                    guard self.session.canAddInput(replacement) else {
                        throw StudioCaptureError.cannotConfigureCamera
                    }
                    self.session.addInput(replacement)
                    self.videoInput = replacement
                    self.trace("input.attach.end")
                    if !self.session.outputs.contains(self.videoOutput) {
                        self.trace("output.attach.begin")
                        guard self.session.canAddOutput(self.videoOutput) else {
                            throw StudioCaptureError.cannotConfigureCamera
                        }
                        self.session.addOutput(self.videoOutput)
                        self.trace("output.attach.end")
                    }
                    if !self.configureSquareFrontFormat(for: replacement.device) {
                        self.trace("preset.720.begin")
                        if self.session.canSetSessionPreset(.hd1280x720) {
                            self.session.sessionPreset = .hd1280x720
                        }
                        self.trace("preset.720.end")
                    }
                }
                self.trace("configuration.commit.begin")
                self.session.commitConfiguration()
                self.trace("configuration.commit.end")
                configurationOpen = false
                if let replacement {
                    let zoom: CGFloat = position == .front ? replacement.device.minAvailableVideoZoomFactor : 1
                    self.trace("zoom.begin requested=\(zoom)")
                    try self.setZoom(zoom, on: replacement.device)
                    self.trace("zoom.end")
                    // Connections are rebuilt by commitConfiguration. Configure
                    // the committed connection, not a possibly retired one.
                    try self.configureVideoConnection(for: replacement)
                    self.trace("delegate.attach")
                    self.videoOutput.setSampleBufferDelegate(self.frames, queue: self.frames.queue)
                }
                try self.updateRunningState()
                if self.dynamicAspectConfigured, let device = self.videoInput?.device {
                    try self.requestPreferredAspectRatio(on: device, force: true)
                }
                self.scheduleAspectCalibration()
                self.trace("setCamera.end")
            } catch {
                let failure = error as NSError
                self.trace("setCamera.error domain=\(failure.domain) code=\(failure.code)")
                self.clearRotationCoordinator()
                self.invalidateAspectConfiguration()
                // Turning the camera off is a privacy choice. A microphone-only
                // restart failure must never restore the removed camera input.
                if !enabled {
                    if configurationOpen { self.session.commitConfiguration() }
                    self.frames.clearCamera()
                    throw error
                }
                if !configurationOpen { self.session.beginConfiguration() }
                if let current = self.videoInput, self.session.inputs.contains(current) {
                    self.session.removeInput(current)
                }
                self.videoInput = nil
                if !hadVideoOutput, self.session.outputs.contains(self.videoOutput) {
                    self.session.removeOutput(self.videoOutput)
                }
                if self.session.canSetSessionPreset(.high) { self.session.sessionPreset = .high }
                if let previousInput, self.session.canAddInput(previousInput) {
                    self.session.addInput(previousInput)
                    self.videoInput = previousInput
                }
                if self.session.canSetSessionPreset(previousPreset) {
                    self.session.sessionPreset = previousPreset
                }
                if previousPreset == .inputPriority, let device = previousInput?.device,
                   let previousFormat {
                    do {
                        try device.lockForConfiguration()
                        device.activeFormat = previousFormat
                        if let previousMinimumFrameDuration { device.activeVideoMinFrameDuration = previousMinimumFrameDuration }
                        if let previousMaximumFrameDuration { device.activeVideoMaxFrameDuration = previousMaximumFrameDuration }
                        device.unlockForConfiguration()
                        self.dynamicAspectConfigured = previousDynamicAspect
                    } catch {
                        self.dynamicAspectConfigured = false
                    }
                }
                self.session.commitConfiguration()
                if let restored = self.videoInput {
                    if let previousZoom { try? self.setZoom(previousZoom, on: restored.device) }
                    do {
                        try self.configureVideoConnection(for: restored)
                        self.videoOutput.setSampleBufferDelegate(self.frames, queue: self.frames.queue)
                    } catch {
                        self.frames.clearCamera()
                    }
                }
                try? self.updateRunningState()
                if self.dynamicAspectConfigured, let device = self.videoInput?.device {
                    try? self.requestPreferredAspectRatio(on: device, force: true)
                    self.scheduleAspectCalibration()
                }
                throw error
            }
        }
    }

    func setMicrophone(enabled: Bool) async throws {
        try await configure {
            if enabled && self.audioInput != nil { return }
            let replacement: AVCaptureDeviceInput?
            if enabled {
                guard let device = AVCaptureDevice.default(for: .audio) else {
                    throw StudioCaptureError.microphoneUnavailable
                }
                replacement = try AVCaptureDeviceInput(device: device)
            } else { replacement = nil }
            self.session.beginConfiguration()
            if let old = self.audioInput { self.session.removeInput(old) }
            self.audioInput = nil
            if let input = replacement {
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    throw StudioCaptureError.cannotConfigureMicrophone
                }
                self.session.addInput(input)
                self.audioInput = input
                if !self.session.outputs.contains(self.audioOutput), self.session.canAddOutput(self.audioOutput) {
                    self.session.addOutput(self.audioOutput)
                }
            }
            self.session.commitConfiguration()
            try self.updateRunningState()
        }
    }

    func shutdown() {
        queue.async {
            self.isShutDown = true
            self.invalidateAspectConfiguration()
            self.clearRotationCoordinator()
            self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
            self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            if let input = self.videoInput { self.session.removeInput(input) }
            if let input = self.audioInput { self.session.removeInput(input) }
            self.videoInput = nil
            self.audioInput = nil
            self.session.commitConfiguration()
            self.frames.clearCamera()
        }
    }

    #if DEBUG
    /// Metadata only: never starts capture, returns pixels, or writes a file.
    func debugCameraSnapshot() async -> [String: Any] {
        let configuration: [String: Any] = await withCheckedContinuation { continuation in
            queue.async {
                let device = self.videoInput?.device
                let connection = self.videoOutput.connection(with: .video)
                let position: String
                switch device?.position {
                case .front: position = "front"
                case .back: position = "back"
                default: position = "none"
                }
                var snapshot: [String: Any] = [:]
                snapshot["selectedPosition"] = position
                snapshot["deviceName"] = device?.localizedName ?? ""
                snapshot["deviceID"] = device?.uniqueID ?? ""
                snapshot["deviceType"] = device?.deviceType.rawValue ?? ""
                snapshot["cameraConfigured"] = self.videoInput != nil
                snapshot["sessionRunning"] = self.session.isRunning
                snapshot["shutdown"] = self.isShutDown
                snapshot["preset"] = self.session.sessionPreset.rawValue
                snapshot["zoom"] = device?.videoZoomFactor ?? 0
                snapshot["minZoom"] = device?.minAvailableVideoZoomFactor ?? 0
                snapshot["maxZoom"] = device?.maxAvailableVideoZoomFactor ?? 0
                snapshot["connectionRotation"] = connection?.videoRotationAngle ?? -1
                snapshot["connectionMirrored"] = connection?.isVideoMirrored ?? false
                snapshot["connectionActive"] = connection?.isActive ?? false
                snapshot["connectionEnabled"] = connection?.isEnabled ?? false
                snapshot["coordinatorCaptureRotation"] = self.rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? -1
                snapshot["centerStageActive"] = device?.isCenterStageActive ?? false
                snapshot["preferredCameraAspect"] = self.prefersLandscape ? "16x9" : "9x16"
                snapshot["dynamicAspectConfigured"] = self.dynamicAspectConfigured
                snapshot["aspectUpdatePending"] = self.aspectUpdatePending
                snapshot["aspectError"] = self.aspectError ?? ""
                snapshot["cameraSelectionID"] = self.cameraSelectionID.uuidString
                snapshot["aspectMappingResolved"] = self.aspectCalibration.axesTransposed != nil
                snapshot["dynamicAxesTransposed"] = self.aspectCalibration.axesTransposed ?? false
                snapshot["defaultConnectionRotation"] = self.defaultConnectionRotation ?? -1
                snapshot["aspectFirstAppliedTime"] = self.aspectCalibration.firstAppliedTime ?? -1
                let matches = self.videoInput.map { input in
                    connection?.inputPorts.contains(where: { $0.input === input }) ?? false
                } ?? false
                snapshot["connectionMatchesSelectedInput"] = matches
                if let device {
                    let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                    snapshot["formatWidth"] = dimensions.width
                    snapshot["formatHeight"] = dimensions.height
                    snapshot["fieldOfView"] = device.activeFormat.videoFieldOfView
                    #if os(iOS) && !targetEnvironment(macCatalyst)
                    snapshot["activeDynamicAspect"] = device.dynamicAspectRatio?.rawValue ?? ""
                    snapshot["dynamicWidth"] = Int(device.dynamicDimensions.width)
                    snapshot["dynamicHeight"] = Int(device.dynamicDimensions.height)
                    snapshot["supportedDynamicAspects"] = device.activeFormat.supportedDynamicAspectRatios.map(\.rawValue)
                    if let ratio = device.dynamicAspectRatio {
                        snapshot["dynamicFieldOfViewUncorrected"] = device.activeFormat.videoFieldOfView(
                            for: ratio, geometricDistortionCorrected: false)
                    }
                    snapshot["square1280Formats"] = device.formats.compactMap { format -> [String: Any]? in
                        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        guard size.width == 1280, size.height == 1280,
                              !format.supportedDynamicAspectRatios.isEmpty else { return nil }
                        return ["width": size.width, "height": size.height,
                                "aspects": format.supportedDynamicAspectRatios.map(\.rawValue),
                                "pixelFormat": CMFormatDescriptionGetMediaSubType(format.formatDescription),
                                "maximumFrameRate": format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0,
                                "fieldOfView": format.videoFieldOfView]
                    }
                    #endif
                }
                continuation.resume(returning: snapshot)
            }
        }
        let delivery = await frames.debugCameraBufferSnapshot()
        return configuration.merging(delivery) { _, current in current }
    }
    #endif

    private func updateRunningState() throws {
        if !session.inputs.isEmpty && !session.isRunning {
            trace("session.startRunning.begin")
            session.startRunning()
            trace("session.startRunning.end running=\(session.isRunning)")
        }
        if !session.inputs.isEmpty && !session.isRunning {
            throw videoInput == nil ? StudioCaptureError.cannotConfigureMicrophone
                : StudioCaptureError.cannotConfigureCamera
        }
        if session.inputs.isEmpty && session.isRunning { session.stopRunning() }
    }

    private func setZoom(_ requested: CGFloat, on device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.cancelVideoZoomRamp()
        device.videoZoomFactor = min(device.maxAvailableVideoZoomFactor,
                                     max(device.minAvailableVideoZoomFactor, requested))
    }

    private func invalidateAspectConfiguration() {
        aspectCalibration.reset()
        aspectCalibrationScheduled = false
        defaultConnectionRotation = nil
        dynamicAspectConfigured = false
        aspectUpdatePending = false
        aspectError = nil
    }

    /// Called inside the existing session configuration transaction, before its
    /// initial startRunning. Unsupported cameras keep the established 720p path.
    private func configureSquareFrontFormat(for device: AVCaptureDevice) -> Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard device.position == .front, device.deviceType == .builtInUltraWideCamera,
              session.canSetSessionPreset(.inputPriority) else { return false }
        let candidates = device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width == 1280 && size.height == 1280
                && format.supportedDynamicAspectRatios.contains(.ratio9x16)
                && format.supportedDynamicAspectRatios.contains(.ratio16x9)
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }.sorted { left, right in
            let left8Bit = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                .contains(CMFormatDescriptionGetMediaSubType(left.formatDescription))
            let right8Bit = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                .contains(CMFormatDescriptionGetMediaSubType(right.formatDescription))
            return left8Bit != right8Bit ? left8Bit : left.videoFieldOfView > right.videoFieldOfView
        }
        guard let format = candidates.first else { return false }
        do {
            session.sessionPreset = .inputPriority
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
            dynamicAspectConfigured = true
            trace("format.square1280.configured")
            return true
        } catch {
            invalidateAspectConfiguration()
            trace("format.square1280.fallback")
            return false
        }
        #else
        return false
        #endif
    }

    private func requestPreferredAspectRatio(on device: AVCaptureDevice,
                                             force: Bool = false, retryAllowed: Bool = true) throws {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let sensorLandscape = aspectCalibration.sensorLandscape(forOutputLandscape: prefersLandscape)
        let ratio: AVCaptureDevice.AspectRatio = sensorLandscape ? .ratio16x9 : .ratio9x16
        guard dynamicAspectConfigured, device.activeFormat.supportedDynamicAspectRatios.contains(ratio) else { return }
        if !force, !aspectUpdatePending, device.dynamicAspectRatio == ratio { return }
        let selection = cameraSelectionID
        let request = aspectCalibration.beginRequest()
        let deviceID = device.uniqueID
        aspectUpdatePending = true
        aspectError = nil
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        trace("aspect.request \(ratio.rawValue)")
        // Do not await this completion before startRunning: its timestamp refers
        // to the first delivered buffer. Completions rejoin our serial queue.
        device.setDynamicAspectRatio(ratio) { [weak self] time, error in
            self?.queue.async { [weak self] in
                guard let self, !self.isShutDown, self.cameraSelectionID == selection,
                      self.aspectRequestID == request,
                      self.videoInput?.device.uniqueID == deviceID else { return }
                self.aspectUpdatePending = false
                self.aspectError = error?.localizedDescription
                var applied = false
                if error == nil,
                   let deviceClock = self.videoInput?.ports.first(where: { $0.mediaType == .video })?.clock,
                   let sessionClock = self.session.synchronizationClock {
                    let converted = CMSyncConvertTime(time, from: deviceClock, to: sessionClock)
                    applied = self.aspectCalibration.applied(at: converted.seconds,
                                                             generation: selection, request: request)
                }
                if !applied, retryAllowed {
                    // Startup can interrupt the first crop request. Retry once
                    // after the session is running, without rebuilding it.
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                        guard let self, !self.isShutDown, self.cameraSelectionID == selection,
                              self.aspectRequestID == request, self.session.isRunning,
                              let current = self.videoInput, current.device.uniqueID == deviceID else { return }
                        do { try self.requestPreferredAspectRatio(on: current.device, force: true, retryAllowed: false) }
                        catch { self.aspectError = error.localizedDescription }
                    }
                } else if !applied {
                    self.aspectError = self.aspectError ?? "Camera framing timing is unavailable."
                    self.onStatus?("Camera framing couldn’t be changed. Your camera is still available.", false)
                } else {
                    self.scheduleAspectCalibration()
                }
                self.trace("aspect.complete \(ratio.rawValue) error=\(error != nil)")
            }
        }
        #endif
    }

    private func scheduleAspectCalibration(attempt: Int = 0) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard dynamicAspectConfigured, aspectCalibration.axesTransposed == nil,
              !aspectCalibrationScheduled, session.isRunning else { return }
        let selection = cameraSelectionID
        let request = aspectRequestID
        aspectCalibrationScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self, !self.isShutDown, self.cameraSelectionID == selection else { return }
            self.frames.readCameraMetadata { [weak self] metadata in
                self?.queue.async { [weak self] in
                    guard let self, !self.isShutDown, self.cameraSelectionID == selection else { return }
                    self.aspectCalibrationScheduled = false
                    guard self.dynamicAspectConfigured, self.aspectCalibration.axesTransposed == nil,
                          let device = self.videoInput?.device else { return }
                    guard self.aspectRequestID == request else { self.scheduleAspectCalibration(); return }
                    let size = device.dynamicDimensions
                    if !self.aspectUpdatePending,
                       let transposed = self.aspectCalibration.observe(width: metadata.width, height: metadata.height,
                            sensorWidth: Int(size.width), sensorHeight: Int(size.height), frameTime: metadata.time,
                            generation: selection, request: request) {
                        self.trace("aspect.axes.transposed=\(transposed)")
                        do { try self.requestPreferredAspectRatio(on: device, force: true) }
                        catch { self.aspectError = error.localizedDescription }
                    } else if attempt < 15 { self.scheduleAspectCalibration(attempt: attempt + 1) }
                }
            }
        }
        #endif
    }

    private func configureVideoConnection(for input: AVCaptureDeviceInput) throws {
        clearRotationCoordinator()
        trace("rotation.coordinator.init.begin")
        let coordinator = AVCaptureDevice.RotationCoordinator(device: input.device, previewLayer: nil)
        trace("rotation.coordinator.init.end")
        rotationCoordinator = coordinator
        trace("rotation.bootstrap.begin")
        let angle = initialCaptureRotation(coordinator)
        defaultConnectionRotation = videoOutput.connection(with: .video)?.videoRotationAngle
        trace("rotation.bootstrap.end angle=\(angle)")
        try applyVideoRotation(angle, for: input)
        trace("rotation.apply.end")
        let token = rotationToken
        let deviceID = input.device.uniqueID
        // The coordinator delivers KVO on the main queue. Device/session state
        // stays on our configuration queue, with a token rejecting retired lenses.
        trace("rotation.observe.begin")
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture,
            options: [.new]) { [weak self] _, change in
                guard let angle = change.newValue else { return }
                self?.queue.async { [weak self] in
                    guard let self, !self.isShutDown, self.rotationToken == token,
                          let current = self.videoInput, current.device.uniqueID == deviceID,
                          let connection = self.videoOutput.connection(with: .video),
                          abs(connection.videoRotationAngle - angle) > 0.001 else { return }
                    self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
                    self.frames.clearCamera()
                    self.frames.queue.sync {}
                    do { try self.applyVideoRotation(angle, for: current) }
                    catch { self.onStatus?("Camera orientation could not be updated. Try switching cameras again.", true) }
                    self.videoOutput.setSampleBufferDelegate(self.frames, queue: self.frames.queue)
                }
            }
        trace("rotation.observe.end")
    }

    private func clearRotationCoordinator() {
        trace("rotation.clear.begin")
        rotationObservation?.invalidate()
        rotationObservation = nil
        rotationCoordinator = nil
        rotationToken = UUID()
        trace("rotation.clear.end")
    }

    private func trace(_ phase: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["ROAST_CAMERA_DIAGNOSTICS"] == "1" else { return }
        let line = "ROAST_CAMERA_CAPTURE \(phase)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        #endif
    }

    private func initialCaptureRotation(_ coordinator: AVCaptureDevice.RotationCoordinator) -> CGFloat {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 27.0, *) {
            // The app's canvas is portrait. This per-device calibration is ready
            // before the first gravity update, including portrait-mounted sensors.
            return coordinator.videoRotationAngleRelative(toDeviceOrientation: .portrait)
        }
        #endif
        return coordinator.videoRotationAngleForHorizonLevelCapture
    }

    private func applyVideoRotation(_ angle: CGFloat, for input: AVCaptureDeviceInput) throws {
        guard let connection = videoOutput.connection(with: .video),
              connection.inputPorts.contains(where: { $0.input === input }),
              angle.isFinite else {
            throw StudioCaptureError.cannotConfigureCamera
        }
        let normalized = (angle.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let quarterTurn = ((normalized / 90).rounded() * 90).truncatingRemainder(dividingBy: 360)
        let supported = connection.isVideoRotationAngleSupported(normalized) ? normalized : quarterTurn
        guard connection.isVideoRotationAngleSupported(supported) else {
            throw StudioCaptureError.cannotConfigureCamera
        }
        // Data output physically rotates/mirrors buffers. Keep compositor/Vision
        // orientation .up; front and back sensors can require DIFFERENT angles.
        connection.videoRotationAngle = supported
        let axesChanged = aspectCalibration.updateRotation(Double(supported))
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = input.device.position == .front
        } else if input.device.position == .front {
            throw StudioCaptureError.cannotConfigureCamera
        }
        connection.isEnabled = true
        if axesChanged, dynamicAspectConfigured { try requestPreferredAspectRatio(on: input.device, force: true) }
    }

    private func configure(_ body: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard !self.isShutDown else { throw CancellationError() }
                    try body()
                    continuation.resume()
                }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

fileprivate struct StudioCameraFrameMetadata: Sendable {
    let width: Int
    let height: Int
    let time: Double
}

fileprivate extension StudioFramePipeline {
    /// Only scalar dimensions/time cross queues; camera pixels stay here.
    func readCameraMetadata(_ completion: @escaping @Sendable (StudioCameraFrameMetadata) -> Void) {
        queue.async {
            completion(StudioCameraFrameMetadata(width: self.cameraBuffer.map(CVPixelBufferGetWidth) ?? 0,
                height: self.cameraBuffer.map(CVPixelBufferGetHeight) ?? 0,
                time: self.cameraPresentationTime.seconds))
        }
    }
}

#if DEBUG
fileprivate extension StudioFramePipeline {
    func debugCameraBufferSnapshot() async -> [String: Any] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: [
                    "bufferAvailable": self.cameraBuffer != nil,
                    "bufferRevision": self.cameraRevision,
                    "bufferWidth": self.cameraBuffer.map { CVPixelBufferGetWidth($0) } ?? 0,
                    "bufferHeight": self.cameraBuffer.map { CVPixelBufferGetHeight($0) } ?? 0,
                    "bufferPresentationTime": self.cameraPresentationTime.seconds.isFinite ? self.cameraPresentationTime.seconds : -1,
                ])
            }
        }
    }
}

extension StudioFramePipeline {
    /// Test fixtures enter through the same serial state used by camera delivery.
    /// This does not construct, configure, or start any capture device/session.
    func debugInjectCameraBuffer(_ buffer: CVPixelBuffer) async {
        let fixture = DebugCameraBuffer(buffer: buffer)
        await withCheckedContinuation { continuation in
            queue.async {
                self.cameraBuffer = fixture.buffer
                self.cameraRevision &+= 1
                continuation.resume()
            }
        }
    }
}

/// The fixture is filled before transfer and read-only after entering the queue.
private struct DebugCameraBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}
#endif

/// All mutable recorder state is confined to callbackQueue.
final class StudioAssetRecorder: @unchecked Sendable {
    private(set) var hostStart = CMTime.invalid
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let url: URL
    private var lastVideoTime = CMTime.invalid
    private var lastAudioEnd = CMTime.zero
    private var audioTimeOffset: CMTime?
    private var hasAudioSamples = false
    private let callbackQueue: DispatchQueue
    private var pendingAudio: [CMSampleBuffer] = []
    private var pendingFinish: (Double, (Result<StudioCaptureResult, Error>) -> Void)?
    private var audioFailure: String?
    private var finishing = false
    private var audioDrainScheduled = false

    var errorMessage: String? {
        audioFailure ?? (writer.status == .failed ? (writer.error?.localizedDescription ?? "Recording stopped unexpectedly.") : nil)
    }

    init(url: URL, microphone: Bool, callbackQueue: DispatchQueue) throws {
        self.url = url
        self.callbackQueue = callbackQueue
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 720, AVVideoHeightKey: 1280,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 720, kCVPixelBufferHeightKey as String: 1280,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ])
        guard writer.canAdd(video) else { throw StudioCaptureError.cannotCreateWriter }
        writer.add(video)
        if microphone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw StudioCaptureError.cannotCreateWriter }
            writer.add(input)
            audio = input
        } else { audio = nil }
    }

    func start() throws {
        guard writer.status == .unknown else { throw StudioCaptureError.cannotCreateWriter }
        guard writer.startWriting() else { throw writer.error ?? StudioCaptureError.cannotCreateWriter }
        hostStart = CMClockGetTime(CMClockGetHostTimeClock())
        writer.startSession(atSourceTime: .zero)
    }

    func appendVideo(_ image: CIImage, at seconds: Double, context: CIContext, colorSpace: CGColorSpace) {
        guard writer.status == .writing, video.isReadyForMoreMediaData else { return }
        let time = CMTime(value: Int64((max(0, seconds) * 30).rounded(.down)), timescale: 30)
        guard !lastVideoTime.isValid || time > lastVideoTime else { return }
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        }
        guard let buffer else { return }
        context.render(image, to: buffer, bounds: StudioFramePipeline.canvas, colorSpace: colorSpace)
        if adaptor.append(buffer, withPresentationTime: time) { lastVideoTime = time }
    }

    @discardableResult
    func appendAudio(_ sample: CMSampleBuffer) -> Bool {
        guard audio != nil, writer.status == .writing, !finishing, pendingFinish == nil,
              audioFailure == nil else { return false }
        let original = CMSampleBufferGetPresentationTimeStamp(sample)
        guard original.isValid else { return false }
        if audioTimeOffset == nil {
            // AVCapture normally uses the host clock. Accommodate devices whose
            // audio timestamp epoch differs, without aligning audio to queue delay.
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
            audioTimeOffset = abs((original - hostNow).seconds) < 60
                ? hostStart : original - (hostNow - hostStart)
        }
        guard let offset = audioTimeOffset, (original - offset).seconds >= 0 else { return false }
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0,
            arrayToFill: nil, entriesNeededOut: &count) == noErr, count > 0 else { return false }
        var timings = Array(repeating: CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count,
            arrayToFill: &timings, entriesNeededOut: &count) == noErr else { return false }
        for index in timings.indices {
            timings[index].presentationTimeStamp = timings[index].presentationTimeStamp - offset
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = timings[index].decodeTimeStamp - offset
            }
        }
        var shifted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
            sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timings,
            sampleBufferOut: &shifted) == noErr, let shifted else { return false }
        guard pendingAudio.count < 256 else {
            audioFailure = "The microphone couldn’t keep up. Try recording again."
            return false
        }
        pendingAudio.append(shifted)
        drainAudio()
        return true
    }

    func finish(at seconds: Double, completion: @escaping (Result<StudioCaptureResult, Error>) -> Void) {
        pendingFinish = (seconds, completion)
        drainAudio()
        // Retain the recorder while encoder backpressure drains. Fail visibly
        // instead of silently dropping microphone buffers if it never recovers.
        callbackQueue.asyncAfter(deadline: .now() + 3) { [self] in
            guard let pending = pendingFinish else { return }
            pendingFinish = nil
            writer.cancelWriting()
            pending.1(.failure(StudioCaptureError.microphoneUnavailable))
        }
    }

    private func drainAudio() {
        if let audio {
            while !pendingAudio.isEmpty, audio.isReadyForMoreMediaData, writer.status == .writing {
                let sample = pendingAudio.removeFirst()
                guard audio.append(sample) else {
                    audioFailure = writer.error?.localizedDescription ?? "The microphone audio couldn’t be saved."
                    break
                }
                hasAudioSamples = true
                let duration = CMSampleBufferGetDuration(sample)
                lastAudioEnd = CMSampleBufferGetPresentationTimeStamp(sample)
                    + (duration.isValid ? duration : CMTime(seconds: 0.02, preferredTimescale: 600))
            }
        }
        if pendingFinish != nil, pendingAudio.isEmpty || errorMessage != nil { finishWriter() }
        if !pendingAudio.isEmpty, writer.status == .writing, audioFailure == nil,
           !audioDrainScheduled, !finishing {
            audioDrainScheduled = true
            callbackQueue.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in
                guard let self else { return }
                self.audioDrainScheduled = false
                self.drainAudio()
            }
        }
    }

    private func finishWriter() {
        guard let pending = pendingFinish else { return }
        pendingFinish = nil
        let (seconds, completion) = pending
        finishing = true
        if audioFailure != nil {
            writer.cancelWriting()
            completion(.failure(StudioCaptureError.microphoneUnavailable))
            return
        }
        guard writer.status == .writing, lastVideoTime.isValid else {
            completion(.failure(writer.error ?? StudioCaptureError.emptyRecording))
            return
        }
        guard audio == nil || hasAudioSamples else {
            writer.cancelWriting()
            completion(.failure(StudioCaptureError.microphoneUnavailable))
            return
        }
        let requestedEnd = CMTime(value: Int64((max(seconds, lastAudioEnd.seconds) * 30).rounded(.up)), timescale: 30)
        let end = max(requestedEnd, lastVideoTime + CMTime(value: 1, timescale: 30))
        writer.endSession(atSourceTime: end)
        video.markAsFinished()
        audio?.markAsFinished()
        writer.finishWriting {
            if self.writer.status == .completed {
                completion(.success(StudioCaptureResult(url: self.url, duration: end.seconds)))
            } else {
                completion(.failure(self.writer.error ?? StudioCaptureError.cannotCreateWriter))
            }
        }
    }

    func cancel() {
        pendingAudio = []
        if let pending = pendingFinish {
            pendingFinish = nil
            pending.1(.failure(CancellationError()))
        }
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}
