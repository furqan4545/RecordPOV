import PhotosUI
import SwiftUI

private struct StudioAsset: Identifiable {
    let id = UUID()
    let source: StudioLaunch.Source
    var position: Double = 0
    var wasPlaying = false
    var title: String {
        switch source { case let .video(_, title), let .image(_, title): title }
    }
    var symbol: String {
        switch source { case .video: "play.rectangle"; case .image: "photo" }
    }
}

struct StudioView: View {
    let launch: StudioLaunch
    let library: TakeLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("recordingDelaySeconds") private var recordingDelaySeconds = 3
    @State private var engine = StudioEngine()
    @State private var selectedMedia: PhotosPickerItem?
    @State private var savedTake: SavedTake?
    @State private var editingDraft: RecordingDraft?
    @State private var completedEdit: SavedTake?
    @State private var resumeCameraAfterEditor = false
    @State private var isLoading = true
    @State private var isSavingTake = false
    @State private var confirmLeaving = false
    @State private var importError: String?
    @State private var sources: [StudioAsset] = []
    @State private var selectedSourceID: UUID?

    private var controlsBusy: Bool { engine.isStarting || engine.isFinalizing || isSavingTake }

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            StudioCanvas(engine: engine, isLoading: isLoading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if sources.count > 1 { sourceTray }
            playbackControls
            if engine.isCameraEnabled && engine.pip.layout == .pip && !engine.pip.isFullScreen { styleControls }
            else if engine.isCameraEnabled && (engine.pip.isFullScreen || engine.pip.layout == .cameraMain) { fullCameraStyleControls }
            if engine.isCameraEnabled { cameraFramingControls }
            if let message = importError ?? engine.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    InlineError(message: message).accessibilityIdentifier("studioErrorMessage")
                    Spacer(minLength: 0)
                    Button { importError = nil; engine.errorMessage = nil } label: {
                        Image(systemName: "xmark").font(.caption).frame(width: 32, height: 32)
                    }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
                }
            }
            if let status = engine.statusMessage {
                Text(status).font(.caption).foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            recordingControls
        }
        .padding(.horizontal, 18).padding(.top, 2).padding(.bottom, 8)
        .background(RoastTheme.ink.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task {
            if sources.isEmpty {
                await addSource(launch.source)
                await engine.startDefaultCameraIfNeeded()
            }
        }
        .task(id: selectedMedia) {
            guard let item = selectedMedia else { return }
            do {
                let source = try await importMedia(item)
                await addSource(source.source)
                selectedMedia = nil
            } catch { importError = "This file couldn’t be opened. Try another video or photo." }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || (phase == .inactive && engine.isCountingDown) {
                engine.cancelCountdown()
            }
        }
        .onDisappear {
            if editingDraft == nil && savedTake == nil { engine.cancelCountdown(); engine.close() }
        }
        .interactiveDismissDisabled(engine.isRecording || controlsBusy)
        .confirmationDialog("Save your video before leaving?", isPresented: $confirmLeaving, titleVisibility: .visible) {
            Button("Finish and edit") { Task { await finishRecording() } }
            Button("Discard video", role: .destructive) {
                Task {
                    if let url = await engine.finishRecording() { try? FileManager.default.removeItem(at: url) }
                    dismiss()
                }
            }
            Button("Keep recording", role: .cancel) { }
        }
        .sheet(item: $savedTake, onDismiss: resumeCameraPreview) { TakeDetailView(take: $0, library: library) }
        .fullScreenCover(item: $editingDraft, onDismiss: {
            if let take = completedEdit { completedEdit = nil; savedTake = take }
            else { resumeCameraPreview() }
        }) { draft in
            EditorView(draft: draft, library: library) { take in
                completedEdit = take
            }
        }
        .sensoryFeedback(.selection, trigger: engine.pip.style)
        .sensoryFeedback(.selection, trigger: engine.countdownRemaining)
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            Button {
                if engine.isRecording { confirmLeaving = true }
                else { engine.cancelCountdown(); dismiss() }
            } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34).background(.white.opacity(0.07), in: Circle())
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(engine.isFinalizing || isSavingTake)
            .accessibilityLabel("Close studio").accessibilityIdentifier("closeStudioButton")
            VStack(alignment: .leading, spacing: 2) {
                Text("Studio").font(.system(size: 17, weight: .semibold))
                Text(engine.sourceTitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                if engine.isRecording { Circle().fill(.red).frame(width: 5, height: 5) }
                Text(engine.elapsed.minuteSecond).font(.system(size: 13, weight: .medium, design: .monospaced))
                    .monospacedDigit().foregroundStyle(.white.opacity(0.75))
            }
            .accessibilityLabel(engine.isRecording ? "Recording, \(engine.elapsed.minuteSecond)" : "Ready to record")
            layoutControl
            delayControl
        }
    }

    private var delayControl: some View {
        Menu {
            Picker("Recording delay", selection: $recordingDelaySeconds) {
                Text("Off").tag(0)
                Text("3 seconds").tag(3)
                Text("5 seconds").tag(5)
                Text("10 seconds").tag(10)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "timer").font(.system(size: 14, weight: .medium))
                Text(recordingDelaySeconds == 0 ? "Off" : "\(recordingDelaySeconds)s")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(.white.opacity(0.07), in: Capsule()).frame(minHeight: 44)
        }
        .buttonStyle(.plain).disabled(controlsBusy || engine.isRecording)
        .accessibilityLabel("Recording delay")
        .accessibilityValue(recordingDelaySeconds == 0 ? "Off" : "\(recordingDelaySeconds) seconds")
        .accessibilityIdentifier("recordingDelayMenu")
    }

    private var layoutControl: some View {
        Menu {
            Picker("Video layout", selection: Binding(get: { engine.pip.layout }, set: { layout in
                var pip = engine.pip; pip.layout = layout; engine.setPiP(pip)
            })) {
                ForEach(StudioLayout.allCases) { layout in
                    Label(layout.label, systemImage: layout.symbol).tag(layout)
                }
            }
            if engine.isCameraEnabled && engine.pip.layout != .pip {
                Toggle("Remove camera background", isOn: Binding(get: { engine.pip.style == .cutout }, set: { enabled in
                    var pip = engine.pip; pip.style = enabled ? .cutout : .rounded; engine.setPiP(pip)
                }))
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: engine.pip.layout.symbol).font(.system(size: 12, weight: .medium))
                Text(engine.pip.layout.shortLabel).font(.system(size: 11, weight: .medium))
            }.padding(.horizontal, 9).frame(height: 32)
                .background(.white.opacity(0.07), in: Capsule()).frame(minHeight: 44)
        }.buttonStyle(.plain).disabled(controlsBusy)
            .accessibilityLabel("Video layout").accessibilityValue(engine.pip.layout.label)
            .accessibilityIdentifier("studioLayoutMenu")
    }

    private var sourceTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sources) { source in
                    Button { Task { await selectSource(source.id) } } label: {
                        Label(source.title, systemImage: source.symbol)
                            .font(.system(size: 11, weight: .medium)).lineLimit(1).frame(maxWidth: 145)
                            .padding(.horizontal, 10).frame(height: 32)
                            .foregroundStyle(selectedSourceID == source.id ? RoastTheme.ink : .white.opacity(0.7))
                            .background(selectedSourceID == source.id ? RoastTheme.lime : .white.opacity(0.06), in: Capsule())
                    }.buttonStyle(.plain).disabled(isLoading || controlsBusy)
                        .accessibilityLabel("Switch to \(source.title)")
                        .accessibilityAddTraits(selectedSourceID == source.id ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder private var playbackControls: some View {
        if engine.hasVideoSource {
            HStack(spacing: 9) {
                Button { engine.togglePlayback() } label: {
                    Image(systemName: engine.isSourcePlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold)).frame(width: 36, height: 36)
                        .background(.white.opacity(0.07), in: Circle()).frame(width: 44, height: 44)
                }.buttonStyle(.plain).disabled(controlsBusy)
                    .accessibilityLabel(engine.isSourcePlaying ? "Pause source video; keep recording your reaction" : "Play source video")
                    .accessibilityIdentifier("sourcePlaybackButton")
                Slider(value: Binding(get: { min(engine.sourceTime, max(0.01, engine.sourceDuration)) },
                                      set: { engine.seek(to: $0) }), in: 0...max(0.01, engine.sourceDuration))
                    .tint(RoastTheme.lime).disabled(controlsBusy).accessibilityLabel("Source video position")
                Text(engine.sourceTime.minuteSecond).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55)).monospacedDigit().frame(minWidth: 32)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                Text("Photo")
                Spacer()
                Text("Add media as you talk")
            }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).frame(height: 30)
        }
    }

    private var styleControls: some View {
        HStack(spacing: 3) {
            ForEach(PiPStyle.allCases) { style in
                let selected = engine.isCameraEnabled && engine.pip.style == style
                Button {
                    var pip = engine.pip
                    pip.style = style
                    engine.setPiP(pip)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: style.symbol).font(.system(size: 14, weight: .medium))
                        Text(style.label).font(.system(size: 11, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? RoastTheme.ink : .white.opacity(0.6))
                    .frame(maxWidth: .infinity).frame(height: 38)
                    .background(selected ? RoastTheme.lime : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(controlsBusy || !engine.isCameraEnabled)
                    .accessibilityLabel(style == .cutout ? "Cutout: remove your camera background on-device" : "\(style.label) camera shape")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("pipStyle_\(style.rawValue)")
            }
        }.padding(4).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
    }

    /// Full screen and Stage show the whole camera, so only Camera and Cutout change how it looks.
    private var fullCameraStyleControls: some View {
        HStack(spacing: 3) {
            ForEach([false, true], id: \.self) { cutout in
                let selected = (engine.pip.style == .cutout) == cutout
                Button {
                    var pip = engine.pip
                    pip.style = cutout ? .cutout : (pip.style == .cutout ? .rounded : pip.style)
                    engine.setPiP(pip)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: cutout ? PiPStyle.cutout.symbol : "video").font(.system(size: 14, weight: .medium))
                        Text(cutout ? PiPStyle.cutout.label : "Camera").font(.system(size: 11, weight: selected ? .semibold : .medium))
                    }
                    .foregroundStyle(selected ? RoastTheme.ink : .white.opacity(0.6))
                    .frame(maxWidth: .infinity).frame(height: 38)
                    .background(selected ? RoastTheme.lime : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(controlsBusy)
                    .accessibilityLabel(cutout ? "Cutout: remove your camera background on-device" : "Camera: show your full camera")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier(cutout ? "fullCameraStyle_cutout" : "fullCameraStyle_camera")
            }
        }.padding(4).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
    }

    private var cameraFramingControls: some View {
        let minimum = engine.pip.style == .cutout && !engine.pip.isFullScreen && engine.pip.layout == .pip ? 0.55 : 1.0
        return HStack(spacing: 9) {
            Text("Wider").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Slider(value: Binding(get: { max(minimum, engine.pip.framingScale) }, set: { value in
                var pip = engine.pip; pip.framingScale = value; engine.setPiP(pip)
            }), in: minimum...2.5).tint(RoastTheme.lime)
                .accessibilityLabel("Camera framing")
                .accessibilityValue("\(Int(max(minimum, engine.pip.framingScale) * 100)) percent")
                .accessibilityIdentifier("cameraFramingSlider")
            Text("Closer").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Button {
                var pip = engine.pip; pip.framingScale = 1; engine.setPiP(pip)
            } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 12, weight: .medium))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.65))
                .accessibilityLabel("Reset camera framing").accessibilityIdentifier("resetCameraFramingButton")
        }.disabled(engine.isSwitchingCamera || controlsBusy)
    }

    private var recordingControls: some View {
        HStack(alignment: .center) {
            PhotosPicker(selection: $selectedMedia, matching: .any(of: [.videos, .images]), photoLibrary: .shared()) {
                secondaryControl("photo.badge.plus", title: "Add media")
            }.buttonStyle(.plain).disabled(isLoading || controlsBusy).accessibilityIdentifier("addStudioMediaButton")
            Spacer()
            VStack(spacing: 7) {
                Button {
                    if engine.isCountingDown { engine.cancelCountdown() }
                    else {
                        Task {
                            if engine.isRecording { await finishRecording() }
                            else { await engine.startRecording(delaySeconds: recordingDelaySeconds) }
                        }
                    }
                } label: {
                    ZStack {
                        Circle().stroke(.white.opacity(0.7), lineWidth: 2).frame(width: 64, height: 64)
                        if engine.isCountingDown {
                            Image(systemName: "xmark").font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                        } else if engine.isStarting || engine.isFinalizing || isSavingTake {
                            ProgressView().tint(.white)
                        } else if engine.isRecording {
                            RoundedRectangle(cornerRadius: 5).fill(.red).frame(width: 24, height: 24)
                        } else { Circle().fill(RoastTheme.lime).frame(width: 52, height: 52) }
                    }.contentShape(Circle())
                }.buttonStyle(.plain)
                    .disabled((isLoading && !engine.isRecording) || engine.isFinalizing || isSavingTake || (engine.isStarting && !engine.isCountingDown)
                              || (engine.isSwitchingCamera && !engine.isRecording))
                    .accessibilityLabel(engine.isCountingDown ? "Cancel countdown" : engine.isStarting ? "Preparing recording" : engine.isFinalizing || isSavingTake ? "Preparing editor" : engine.isRecording ? "Finish recording and edit" : "Start recording")
                    .accessibilityIdentifier("recordTakeButton")
                Text(engine.isCountingDown ? "Cancel" : engine.isStarting ? "Getting ready…" : engine.isFinalizing || isSavingTake ? "Preparing…" : engine.isRecording ? "Done" : "Record")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            }
            Spacer()
            Button {
                Task {
                    if engine.isCameraEnabled { await engine.switchCamera() }
                    else { await engine.enableCamera() }
                }
            } label: {
                secondaryControl(engine.isCameraEnabled ? "arrow.triangle.2.circlepath.camera" : "video.badge.plus",
                                 title: engine.isCameraEnabled ? "Flip" : "Camera", loading: engine.isSwitchingCamera)
            }.buttonStyle(.plain).disabled(controlsBusy || engine.isSwitchingCamera)
                .accessibilityLabel(engine.isCameraEnabled ? (engine.cameraPosition == .front ? "Switch to back camera" : "Switch to front camera") : "Enable your camera")
                .accessibilityIdentifier("enableCameraButton")
        }.padding(.horizontal, 27).padding(.top, 2)
    }

    private func secondaryControl(_ symbol: String, title: String, loading: Bool = false) -> some View {
        VStack(spacing: 7) {
            ZStack {
                if loading { ProgressView().tint(.white) }
                else { Image(systemName: symbol).font(.system(size: 18, weight: .regular)) }
            }.frame(width: 40, height: 40).background(.white.opacity(0.07), in: Circle())
            Text(title).font(.system(size: 11, weight: .medium))
        }.foregroundStyle(.white.opacity(0.7)).frame(minWidth: 56)
    }

    private func addSource(_ source: StudioLaunch.Source) async {
        let asset = StudioAsset(source: source)
        sources.append(asset)
        await selectSource(asset.id)
    }

    private func selectSource(_ id: UUID) async {
        guard let next = sources.first(where: { $0.id == id }), selectedSourceID != id else { return }
        if let previous = sources.firstIndex(where: { $0.id == selectedSourceID }) {
            sources[previous].position = engine.sourceTime
            sources[previous].wasPlaying = engine.isSourcePlaying
        }
        isLoading = true
        defer { isLoading = false }
        do {
            switch next.source {
            case let .video(url, title):
                try await engine.loadVideo(url, title: title)
                if next.position > 0 { engine.seek(to: next.position) }
                if next.wasPlaying { engine.togglePlayback() }
            case let .image(image, title): engine.loadImage(image, title: title)
            }
            selectedSourceID = id
        } catch { importError = "This video couldn’t be played. \(error.localizedDescription)" }
    }

    private func finishRecording() async {
        guard !isSavingTake else { return }
        isSavingTake = true
        defer { isSavingTake = false }
        if let draft = await engine.finishForEditing() {
            resumeCameraAfterEditor = engine.isCameraEnabled
            if engine.isCameraEnabled { engine.disableCamera() }
            editingDraft = draft
        }
    }

    private func resumeCameraPreview() {
        guard resumeCameraAfterEditor else { return }
        resumeCameraAfterEditor = false
        Task {
            while engine.isSwitchingCamera { try? await Task.sleep(for: .milliseconds(25)) }
            await engine.enableCamera()
        }
    }
}

private struct StudioCanvas: View {
    let engine: StudioEngine
    let isLoading: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width, geometry.size.height * 9 / 16)
            let height = width * 16 / 9
            ZStack(alignment: .top) {
                Color.black
                if let frame = engine.previewFrame {
                    Image(uiImage: frame).resizable().scaledToFit().accessibilityHidden(true)
                } else if isLoading {
                    ProgressView("Opening your canvas…").tint(.white).frame(maxHeight: .infinity)
                }
                if engine.isCameraEnabled && !engine.pip.isFullScreen {
                    switch engine.pip.layout {
                    case .pip: PiPInteractionLayer(engine: engine, size: CGSize(width: width, height: height))
                    case .split: SplitDivider(engine: engine, size: CGSize(width: width, height: height))
                    case .cameraMain: SourceOverlayInteractionLayer(engine: engine, size: CGSize(width: width, height: height))
                    }
                }
                if !engine.isCountingDown {
                    HStack {
                        if engine.isCameraEnabled && !engine.isRecording && !engine.pip.isFullScreen {
                            Text(engine.pip.layout == .split ? "Drag the divider" : engine.pip.layout == .cameraMain ? "Move the video overlay" : "1 finger: move · 2: size & turn")
                                .font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.5)
                                .padding(.horizontal, 10).frame(height: 28)
                                .background(.black.opacity(0.32), in: Capsule())
                        } else if !engine.isCameraEnabled && !engine.isRecording {
                            Button { Task { await engine.enableCamera() } } label: {
                                Label("Add my camera", systemImage: "video.badge.plus")
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 12).frame(height: 34)
                                    .glassEffect(.regular.interactive(), in: Capsule())
                            }.buttonStyle(.plain).accessibilityIdentifier("addMyCameraButton")
                                .disabled(engine.isStarting || engine.isFinalizing || engine.isSwitchingCamera)
                        }
                        Spacer(minLength: 0)
                        if engine.isCameraEnabled {
                            // Shortcut: you big at the bottom center with Cutout; tap again to go back.
                            Button { engine.toggleBigAtBottom() } label: {
                                Image(systemName: "person.and.background.dotted")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(engine.isBigAtBottom ? RoastTheme.ink : .white)
                                    .frame(width: 32, height: 32)
                                    .background(engine.isBigAtBottom ? RoastTheme.lime : .black.opacity(0.32), in: Circle())
                                    .frame(width: 44, height: 44)
                            }.buttonStyle(.plain)
                                .accessibilityLabel(engine.isBigAtBottom ? "Put your camera back" : "Put yourself big at the bottom")
                                .accessibilityIdentifier("bigAtBottomButton")
                                .disabled(engine.isStarting || engine.isFinalizing || engine.isSwitchingCamera)
                        }
                        if engine.isCameraEnabled {
                            Button { engine.toggleCameraFullScreen() } label: {
                                Image(systemName: engine.pip.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(width: 32, height: 32).background(.black.opacity(0.32), in: Circle())
                                    .frame(width: 44, height: 44)
                            }.buttonStyle(.plain)
                                .accessibilityLabel(engine.pip.isFullScreen ? "Return to Camera" : "Make camera full screen")
                                .accessibilityIdentifier("toggleCameraFullScreenButton")
                                .disabled(engine.isStarting || engine.isFinalizing || engine.isSwitchingCamera)
                        }
                        if engine.isCameraEnabled && !engine.isRecording {
                            Menu {
                                if engine.pip.layout == .cameraMain {
                                    Button("Reset original overlay", systemImage: "arrow.counterclockwise") {
                                        var pip = engine.pip; pip.sourceOverlay = SourceOverlayTransform(); engine.setPiP(pip)
                                    }
                                } else if engine.pip.layout == .split {
                                    Button("Reset split to 70 / 30", systemImage: "arrow.counterclockwise") {
                                        var pip = engine.pip; pip.splitRatio = 0.7; engine.setPiP(pip)
                                    }
                                } else {
                                    Button("Reset position & size", systemImage: "arrow.counterclockwise") { engine.resetPiP() }
                                }
                                Button("Turn camera off", systemImage: "video.slash") { engine.disableCamera() }
                            } label: {
                                Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                                    .frame(width: 32, height: 32).background(.black.opacity(0.32), in: Circle())
                                    .frame(width: 44, height: 44)
                            }.buttonStyle(.plain).accessibilityLabel("Camera options")
                                .disabled(engine.isStarting || engine.isFinalizing || engine.isSwitchingCamera)
                        }
                    }.padding(10).foregroundStyle(.white)
                }
                if let remaining = engine.countdownRemaining {
                    VStack(spacing: 9) {
                        Text("\(remaining)").font(.system(size: 76, weight: .semibold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text("Get ready").font(.system(size: 13, weight: .medium))
                    }.foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.28)).allowsHitTesting(false)
                        .accessibilityElement(children: .combine).accessibilityAddTraits(.updatesFrequently)
                        .accessibilityIdentifier("recordingCountdown")
                }
            }
            .frame(width: width, height: height)
            .coordinateSpace(name: "studioCanvas")
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.07), lineWidth: 1))
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }.accessibilityElement(children: .contain)
    }
}

private struct PiPInteractionLayer: View {
    let engine: StudioEngine
    let size: CGSize

    var body: some View {
        let pip = engine.pip
        let baseWidth = size.width * 0.34
        let baseHeight = baseWidth * ((pip.style == .circle || pip.style == .square) ? 1 : 1.30)
        ZStack {
            OverlayTouchSurface(
                geometry: .init(canvas: size, content: gestureContent(for: pip), scaleRange: 0.55...2.5),
                currentValue: {
                    let value = engine.pip
                    return .init(x: value.x, y: value.y, scale: value.scale, rotation: value.rotation)
                }, onChanged: { value in
                    var next = engine.pip
                    next.x = value.x; next.y = value.y
                    next.scale = value.scale; next.rotation = value.rotation
                    engine.setPiP(next)
                })
            Color.clear
                .frame(width: max(44, baseWidth * pip.scale), height: max(44, baseHeight * pip.scale))
                .rotationEffect(.radians(pip.rotation))
                .position(x: size.width * pip.x, y: size.height * pip.y)
                .allowsHitTesting(false)
                .accessibilityElement().accessibilityLabel("Your camera")
                .accessibilityHint("Move with one finger. Resize and turn with two fingers.")
                .accessibilityAdjustableAction { direction in
                    var next = engine.pip
                    next.scale = min(2.5, max(0.55, next.scale + (direction == .increment ? 0.1 : -0.1)))
                    engine.setPiP(next)
                }
                .accessibilityAction(named: "Reset position and size") { engine.resetPiP() }
                .accessibilityAction(named: "Move left") { move(x: -0.05, y: 0) }
                .accessibilityAction(named: "Move right") { move(x: 0.05, y: 0) }
                .accessibilityAction(named: "Move up") { move(x: 0, y: -0.05) }
                .accessibilityAction(named: "Move down") { move(x: 0, y: 0.05) }
        }.frame(width: size.width, height: size.height)
    }

    /// What a gesture holds and keeps on screen: the PiP frame, or for Cutout the camera you can
    /// actually see inside it, so you can be moved right up to the edges at any Wider/Closer setting.
    private func gestureContent(for pip: PiPTransform) -> CGSize {
        let width = size.width * 0.34
        let frame = CGSize(width: width, height: width * ((pip.style == .circle || pip.style == .square) ? 1 : 1.30))
        guard pip.style == .cutout, let camera = engine.cameraFrameSize else { return frame }
        return CameraFramingGeometry.visibleSize(source: camera, viewport: frame, style: .cutout, framingScale: pip.framingScale)
    }

    private func move(x: Double, y: Double) {
        var next = engine.pip
        let value = OverlayGestureGeometry(canvas: size, content: gestureContent(for: next), scaleRange: 0.55...2.5)
            .keepingVisible(.init(x: next.x + x, y: next.y + y, scale: next.scale, rotation: next.rotation))
        next.x = value.x; next.y = value.y
        engine.setPiP(next)
    }
}
