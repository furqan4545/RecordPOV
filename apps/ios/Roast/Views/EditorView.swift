import AVFoundation
import Speech
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    let draft: RecordingDraft
    let library: TakeLibrary
    var onSaved: (SavedTake) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var edits: TakeEdits
    @State private var preview: EditorPreviewController
    @State private var tool = EditorTool.trim
    @State private var editTask: Task<Void, Never>?
    @State private var isExporting = false
    @State private var isImportingMusic = false
    @State private var showMusicImporter = false
    @State private var showCaptionCorrections = false
    @State private var captionTask: Task<Void, Never>?
    @State private var captionProgress: Double?
    @State private var captionStatus = ""
    @AppStorage("captionLanguageIdentifier") private var captionLocale = "en-US"
    @State private var message: String?

    init(draft: RecordingDraft, library: TakeLibrary, onSaved: @escaping (SavedTake) -> Void = { _ in }) {
        self.draft = draft
        self.library = library
        self.onSaved = onSaved
        var stored = EditorEditStore.load(for: draft)
        let hadLegacyCuts = !stored.cuts.isEmpty
        stored.cuts = []
        _edits = State(initialValue: stored)
        _preview = State(initialValue: EditorPreviewController(draft: draft, edits: stored))
        if hadLegacyCuts {
            _message = State(initialValue: "Previous cut markers were cleared. Save keeps the section between your start and end points.")
        }
    }

    private var editedDuration: Double { EditorTimeline(duration: draft.duration, edits: edits).duration }
    private var busy: Bool { isExporting || isImportingMusic }

    var body: some View {
        VStack(spacing: 12) {
            header
            EditorPlayerSurface(player: preview.player)
                .background(.black).clipShape(RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Edited video preview")
                .overlay(alignment: .bottomLeading) {
                    if preview.isRebuilding {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preview.preparationMessage)
                                    .font(.system(size: 12, weight: .medium))
                                if preview.isPlaybackPending {
                                    Text("Plays when ready").font(.system(size: 11)).opacity(0.85)
                                }
                            }
                        }
                        .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 9)
                        .background(.black.opacity(0.72), in: Capsule()).padding(12)
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("editorPreparationStatus")
                    }
                }
            playback
            Picker("Editing tool", selection: $tool) {
                ForEach(EditorTool.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(busy)
            ScrollView {
                Group {
                    switch tool {
                    case .audio: audioControls
                    case .trim: trimControls
                    case .captions: captionControls
                    }
                }.padding(.vertical, 4)
            }
            .frame(height: tool == .trim ? 234 : 202)
            .scrollBounceBehavior(.basedOnSize)
            .disabled(busy)
            if let message = message ?? preview.errorMessage {
                HStack(spacing: 8) {
                    InlineError(message: message).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("editorErrorMessage")
                    if preview.errorMessage != nil {
                        Button("Retry preview") { Task { await preview.prepare(edits: edits) } }
                            .font(.system(size: 12, weight: .semibold)).frame(minHeight: 44)
                            .disabled(busy || preview.isDragging)
                            .accessibilityIdentifier("retryEditorPreviewButton")
                    }
                }
            }
            PrimaryButton(title: isExporting ? "Saving your video…" : "Save video", symbol: "checkmark",
                          isLoading: isExporting) { Task { await saveVideo() } }
                .disabled(busy || captionTask != nil || !preview.isReady(for: edits) || editedDuration < 0.04)
                .accessibilityIdentifier("saveEditedVideoButton")
        }
        .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 8)
        .foregroundStyle(RoastTheme.ink).background(RoastTheme.paper.ignoresSafeArea())
        .preferredColorScheme(.light)
        .interactiveDismissDisabled(isExporting)
        .task { await preview.prepare(edits: edits) }
        .onChange(of: edits) { _, value in schedulePreviewUpdate(value) }
        .fileImporter(isPresented: $showMusicImporter, allowedContentTypes: [.audio]) { result in
            switch result {
            case let .success(url): Task { await importMusic(url) }
            case .failure: message = "The audio file couldn’t be opened. Choose another file."
            }
        }
        .sheet(isPresented: $showCaptionCorrections) { captionCorrections }
        .onDisappear {
            editTask?.cancel()
            try? EditorEditStore.save(edits, for: draft)
            preview.close()
            captionTask?.cancel()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(isExporting).accessibilityLabel("Close editor")
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit video").font(.system(size: 18, weight: .semibold))
                Text(draft.title).font(.caption).foregroundStyle(RoastTheme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(editedDuration.minuteSecond).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(RoastTheme.muted).monospacedDigit()
        }
    }

    private var playback: some View {
        HStack(spacing: 10) {
            Button { preview.togglePlayback(edits: edits) } label: {
                Image(systemName: preview.isPlaying || preview.isPlaybackPending ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold)).frame(width: 44, height: 44)
            }.buttonStyle(.plain).disabled(busy || preview.isDragging)
                .accessibilityLabel(preview.isPlaying ? "Pause preview" : (preview.isPlaybackPending ? "Cancel queued playback" : "Play preview"))
            if tool == .trim {
                Text(editorTime(preview.sourcePosition)).monospacedDigit()
                    .accessibilityIdentifier("trimPreviewTime")
                Text("/ \(editorTime(draft.duration))").foregroundStyle(RoastTheme.muted)
                Spacer()
                Text("\(editorTime(editedDuration)) selected").foregroundStyle(RoastTheme.muted)
            } else {
                Slider(value: Binding(get: { min(preview.outputPosition, max(0.01, preview.timeline.duration)) }, set: {
                    preview.seekOutput(to: $0)
                }), in: 0...max(0.01, preview.timeline.duration), onEditingChanged: { editing in
                    if editing { preview.beginInteraction() }
                    else { finishTimelineInteraction() }
                })
                .tint(RoastTheme.ink).disabled(busy).accessibilityLabel("Preview position")
                Text(editorTime(preview.outputPosition)).monospacedDigit().foregroundStyle(RoastTheme.muted)
            }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private var audioControls: some View {
        VStack(spacing: 8) {
            EditorGainRow(title: "My voice", symbol: "mic", value: $edits.microphoneVolume, available: draft.microphoneURL != nil)
            Toggle(isOn: Binding(get: { edits.voiceCleanupEnabled == true }, set: { edits.voiceCleanupEnabled = $0 })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clean voice").font(.system(size: 13, weight: .medium))
                    Text("Reduce steady microphone hiss")
                        .font(.system(size: 11)).foregroundStyle(RoastTheme.muted)
                }
            }
            .tint(RoastTheme.ink).frame(minHeight: 44).disabled(draft.microphoneURL == nil)
            .accessibilityIdentifier("cleanVoiceToggle")
            EditorGainRow(title: "Original video", symbol: "speaker.wave.2", value: $edits.sourceVolume, available: draft.sourceAudioURL != nil)
            if edits.musicURL != nil {
                EditorGainRow(title: "Music", symbol: "music.note", value: $edits.musicVolume, available: true)
                HStack {
                    Text(edits.musicTitle ?? "Music").font(.caption).lineLimit(1).foregroundStyle(RoastTheme.muted)
                    Spacer(minLength: 4)
                    Button("Remove") { edits.musicURL = nil; edits.musicTitle = nil }
                        .font(.caption.weight(.semibold)).frame(minHeight: 44)
                }
            } else {
                Button { showMusicImporter = true } label: {
                    Label(isImportingMusic ? "Opening music…" : "Add music", systemImage: "music.note.badge.plus")
                        .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 44)
                        .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
            }
        }
    }

    private var trimControls: some View {
        VStack(spacing: 8) {
            EditorTimelineView(videoURL: draft.videoURL, duration: draft.duration,
                trimStart: Binding(get: { edits.trimStart }, set: { value in
                    var range = edits; range.cuts = []
                    edits = EditorTimelineEditing.trimmingStart(to: value, edits: range, duration: draft.duration)
                }),
                trimEnd: Binding(get: { edits.trimEnd }, set: { value in
                    var range = edits; range.cuts = []
                    edits = EditorTimelineEditing.trimmingEnd(to: value, edits: range, duration: draft.duration)
                }),
                sourcePosition: preview.sourcePosition,
                interactionBegan: {
                    editTask?.cancel()
                    message = nil
                    preview.beginInteraction()
                },
                seek: { preview.seekSource(to: $0) },
                interactionEnded: finishTimelineInteraction)
            HStack(spacing: 8) {
                Text("Drag the edges to choose what to keep.")
                    .font(.system(size: 11)).foregroundStyle(RoastTheme.muted)
                Spacer(minLength: 0)
                Button("Reset trim") {
                    preview.beginInteraction()
                    edits.trimStart = 0
                    edits.trimEnd = draft.duration
                    edits.cuts = []
                    message = nil
                    preview.seekSource(to: 0)
                    finishTimelineInteraction()
                }
                .font(.system(size: 12, weight: .semibold)).frame(minHeight: 44)
                .accessibilityIdentifier("resetTrimButton")
            }
        }
    }

    private func editorTime(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds.isFinite ? seconds : 0) * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }

    private func finishTimelineInteraction() {
        editTask?.cancel()
        let currentEdits = edits
        do { try EditorEditStore.save(currentEdits, for: draft) }
        catch { message = "Your edits couldn’t be saved. Try again before closing." }
        Task { await preview.endInteraction(edits: currentEdits) }
    }

    private var captionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if captionTask != nil {
                HStack {
                    if let captionProgress { ProgressView(value: captionProgress).frame(maxWidth: 150) }
                    else { ProgressView() }
                    Text(captionStatus).font(.caption)
                    Spacer(minLength: 4)
                    Button("Cancel") { captionTask?.cancel() }.font(.caption.weight(.semibold)).frame(minHeight: 44)
                }
            } else {
                HStack {
                    Menu {
                        Picker("Spoken language", selection: $captionLocale) {
                            ForEach(["en-US", "en-GB", "es-ES", "fr-FR", "de-DE", "hi-IN", "ko-KR", "ja-JP", "zh-CN", "pt-BR"], id: \.self) { identifier in
                                Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier).tag(identifier)
                            }
                        }
                    } label: {
                        Label(Locale.current.localizedString(forIdentifier: captionLocale) ?? "English", systemImage: "globe")
                            .font(.caption).lineLimit(1).frame(minHeight: 44)
                    }.buttonStyle(.plain)
                    Spacer(minLength: 4)
                    Button(edits.captions.isEmpty ? "Generate captions" : "Replace captions", action: generateCaptions)
                        .font(.system(size: 13, weight: .semibold)).frame(minHeight: 44)
                        .disabled(draft.microphoneURL == nil)
                }
            }
            Text(draft.microphoneURL == nil ? "This video has no microphone recording." : "Only your voice is captioned, on this device. A language download may be needed.")
                .font(.caption).foregroundStyle(RoastTheme.muted).fixedSize(horizontal: false, vertical: true)
            if !edits.captions.isEmpty {
                Toggle("Show captions", isOn: $edits.captionsEnabled).font(.subheadline).tint(RoastTheme.ink)
                Button("Correct caption text") { showCaptionCorrections = true }
                    .font(.system(size: 13, weight: .semibold)).frame(minHeight: 44)
            }
        }
    }

    private var captionCorrections: some View {
        NavigationStack {
            List {
                ForEach($edits.captions) { $caption in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(caption.start.minuteSecond).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        TextField("Caption", text: $caption.text, axis: .vertical).lineLimit(1...4)
                            .accessibilityLabel("Caption at \(caption.start.minuteSecond)")
                    }.padding(.vertical, 4)
                }
            }
            .navigationTitle("Correct captions").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showCaptionCorrections = false } } }
        }
    }

    private func schedulePreviewUpdate(_ value: TakeEdits) {
        editTask?.cancel()
        editTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(140))
                try Task.checkCancellation()
                try EditorEditStore.save(value, for: draft)
                if !preview.isDragging { await preview.update(edits: value) }
            } catch is CancellationError { }
            catch { message = "Your edits couldn’t be saved. Try again before closing." }
        }
    }

    private func importMusic(_ url: URL) async {
        isImportingMusic = true
        defer { isImportingMusic = false }
        do {
            edits.musicURL = try await EditorMusicImporter.copy(url, for: draft)
            edits.musicTitle = url.deletingPathExtension().lastPathComponent
            message = nil
        } catch { message = error.localizedDescription }
    }

    private func generateCaptions() {
        guard captionTask == nil, let microphone = draft.microphoneURL else { return }
        preview.pause()
        message = nil
        captionTask = Task {
            defer { captionTask = nil }
            do {
                let generated = try await MicrophoneCaptioner.generate(microphoneURL: microphone,
                    locale: Locale(identifier: captionLocale)) { fraction, status in
                        captionProgress = fraction; captionStatus = status
                    }
                try Task.checkCancellation()
                edits.captions = generated
                edits.captionsEnabled = true
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
    }

    private func saveVideo() async {
        guard !busy, captionTask == nil, preview.isReady(for: edits) else { return }
        editTask?.cancel()
        isExporting = true
        preview.pause()
        preview.errorMessage = nil
        message = nil
        defer { isExporting = false }
        do {
            try EditorEditStore.save(edits, for: draft)
            let url = try await EditorExporter.export(draft: draft, edits: edits)
            defer { try? FileManager.default.removeItem(at: url) }
            let exportedDuration = try await AVURLAsset(url: url).load(.duration).seconds
            let take = try library.add(url: url, title: draft.title, duration: exportedDuration)
            do { try await library.saveToPhotos(take) } catch { /* The library exposes its recoverable Photos error. */ }
            preview.close()
            let folder = draft.videoURL.deletingLastPathComponent()
            if folder.lastPathComponent == draft.id.uuidString,
               folder.deletingLastPathComponent().lastPathComponent == "Drafts" {
                try? FileManager.default.removeItem(at: folder)
            }
            onSaved(take)
            dismiss()
        } catch { message = error.localizedDescription }
    }
}

private enum EditorTool: String, CaseIterable, Identifiable {
    case audio = "Audio", trim = "Trim", captions = "Captions"
    var id: String { rawValue }
}

private struct EditorGainRow: View {
    let title: String
    let symbol: String
    @Binding var value: Double
    let available: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20)
            Text(title).font(.system(size: 13, weight: .medium)).frame(width: 88, alignment: .leading)
            Slider(value: $value, in: 0...2).tint(RoastTheme.ink).disabled(!available)
                .accessibilityLabel("\(title) volume").accessibilityValue(available ? "\(Int(value * 100)) percent" : "No audio")
            Text(available ? "\(Int(value * 100))%" : "—")
                .font(.system(size: 11, design: .monospaced)).monospacedDigit().frame(width: 38, alignment: .trailing)
        }.frame(minHeight: 44).opacity(available ? 1 : 0.45)
    }
}

private struct EditorPlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerLayerView { PlayerLayerView() }
    func updateUIView(_ view: PlayerLayerView, context: Context) { view.playerLayer.player = player }
    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        override init(frame: CGRect) { super.init(frame: frame); playerLayer.videoGravity = .resizeAspect }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
