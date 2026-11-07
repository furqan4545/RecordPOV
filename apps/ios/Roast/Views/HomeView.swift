import PhotosUI
import SwiftUI

private enum HomeSheet: String, Identifiable {
    case settings
    var id: String { rawValue }
}

struct HomeView: View {
    let library: TakeLibrary
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    private let importer = VideoImportCoordinator.shared
    @AppStorage("resolverAddress") private var resolverAddress = MediaResolver.defaultAddress
    @AppStorage("lastOpenedImportedVideoID") private var lastOpenedImportedID = ""
    private let importedVideos = ImportedVideoLibrary.shared
    @State private var link = ""
    @State private var errorMessage: String?
    @State private var needsNetworkSettings = false
    private var loadingPhase: VideoLinkLoadingPhase { importer.phase }
    @State private var isImporting = false
    @State private var selectedMedia: PhotosPickerItem?
    @State private var launch: StudioLaunch?
    @State private var sheet: HomeSheet?
    @State private var isVisible = false
    @FocusState private var linkFocused: Bool

    private var isResolving: Bool { loadingPhase != .idle }
    /// "Download & open video" opens the finished video, even if the link field changed meanwhile.
    private var readyWillAutoOpen: Bool { importer.shouldAutomaticallyOpen }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                importCard
                HomeRecentVideos(library: library, onOpenImport: openImportedVideo)
            }
            .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 30)
        }
        .background(RoastTheme.paper)
        .buttonStyle(.plain)
        .toolbar(.hidden, for: .navigationBar)
        .scrollDismissesKeyboard(.interactively)
        // Opens a finished import once the sheet has fully gone, not mid-dismissal.
        .sheet(item: $sheet, onDismiss: { openReadyImport() }) { destination in
            switch destination {
            case .settings: SettingsView()
            }
        }
        .fullScreenCover(item: $launch) { StudioView(launch: $0, library: library) }
        .onAppear { isVisible = true; importer.resumeIfNeeded(); openReadyImport() }
        .onDisappear { isVisible = false }
        .onChange(of: importer.ready?.id) { _, _ in openReadyImport() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { importer.resumeIfNeeded(); openReadyImport() }
        }
        .task(id: selectedMedia) {
            guard let item = selectedMedia else { return }
            importer.deferOpeningUntilRequested()
            isImporting = true
            defer { isImporting = false }
            do {
                launch = try await importMedia(item)
                selectedMedia = nil
            } catch { errorMessage = "This file couldn’t be opened. Try another video or photo." }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark()
            Text("RecordPOV").font(.system(size: 25, weight: .bold, design: .rounded))
            Spacer()
            Button { sheet = .settings } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 16, weight: .medium))
                    .frame(width: 34, height: 34).background(RoastTheme.ink.opacity(0.05), in: Circle())
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Settings")
        }
        .foregroundStyle(RoastTheme.ink)
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add a video").font(.system(.title2, design: .rounded, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: 12) {
                Image(systemName: "link").foregroundStyle(RoastTheme.muted)
                TextField("Paste a video link", text: $link)
                    .keyboardType(.URL).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().submitLabel(.go).focused($linkFocused)
                    .onSubmit(openLink).accessibilityIdentifier("videoLinkField")
                Button("Paste") {
                    if let value = UIPasteboard.general.string { link = value }
                }
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(RoastTheme.ink)
                .padding(.horizontal, 10).frame(height: 30)
                .background(.white, in: Capsule())
                .accessibilityLabel("Paste video link from clipboard")
            }
            .padding(.horizontal, 13).frame(minHeight: 48).background(RoastTheme.paper, in: RoundedRectangle(cornerRadius: 12))
            Text("Instagram  ·  YouTube  ·  TikTok  ·  X")
                .font(.caption).foregroundStyle(RoastTheme.muted)

            VStack(alignment: .leading, spacing: 10) {
                PrimaryButton(title: isResolving ? loadingPhase.buttonTitle : "Download & open video",
                              symbol: "arrow.down", isLoading: isResolving, action: openLink)
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResolving || isImporting)
                    .accessibilityIdentifier("openStudioButton")
                    .accessibilityValue(loadingPhase.accessibilityValue)
                if isResolving {
                    ImportStatusPanel(link: link, onCancel: cancelResolution)
                }
            }
            if let message = errorMessage ?? importer.errorMessage {
                InlineError(message: message)
                if needsNetworkSettings || importer.needsNetworkSettings {
                    Button("Open iPhone Settings", systemImage: "arrow.up.right.square") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .accessibilityIdentifier("openNetworkSettingsButton")
                }
            }

            HStack(spacing: 12) {
                Rectangle().fill(RoastTheme.ink.opacity(0.1)).frame(height: 1)
                Text("or").font(.caption).foregroundStyle(RoastTheme.muted)
                Rectangle().fill(RoastTheme.ink.opacity(0.1)).frame(height: 1)
            }.accessibilityHidden(true)
            PhotosPicker(selection: $selectedMedia, matching: .any(of: [.videos, .images]), photoLibrary: .shared()) {
                Label(isImporting ? "Opening…" : "Upload video or photo", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(minHeight: 48)
                    .background(RoastTheme.paper, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(isImporting).accessibilityIdentifier("importMediaButton")
        }
        .padding(18).foregroundStyle(RoastTheme.ink)
        .background(.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white, lineWidth: 1))
    }

    private func openLink() {
        guard !isResolving else { return }
        linkFocused = false
        errorMessage = nil
        needsNetworkSettings = false
        guard MediaResolver.supports(link) else {
            errorMessage = "Paste an Instagram, YouTube, TikTok, or X video link."
            return
        }
        if let existing = importedVideos.videos.first(where: { ($0.qualityVersion ?? 0) >= 2 && SourceLinkIdentity.same(link, as: $0.sourceURL?.absoluteString) }) {
            openImportedVideo(existing)
        } else { importer.start(link, address: resolverAddress) }
    }

    private func openReadyImport(force: Bool = false) {
        guard isVisible, scenePhase == .active, sheet == nil, launch == nil, !isImporting,
              let ready = importer.ready else { return }
        guard force || readyWillAutoOpen else { return }
        // A file removed outside the app must not open an empty Studio. Ready
        // imports always come from a link, so the link advice applies.
        guard FileManager.default.fileExists(atPath: ready.url.path) else {
            importer.consumeReady()
            errorMessage = "This video is no longer on this iPhone. Paste its link to download it again."
            return
        }
        lastOpenedImportedID = ready.id.uuidString
        launch = StudioLaunch(source: .video(ready.url, ready.title))
        importer.consumeReady()
    }

    private func openImportedVideo(_ video: ImportedVideo) {
        guard launch == nil, sheet == nil else { return }
        linkFocused = false
        lastOpenedImportedID = video.id.uuidString
        importer.deferOpeningUntilRequested()
        if importer.ready?.id == video.id { importer.consumeReady() }
        launch = StudioLaunch(source: .video(video.fileURL, video.title))
    }

    private func cancelResolution() { importer.cancel() }

}

@MainActor
func importMedia(_ item: PhotosPickerItem) async throws -> StudioLaunch {
    if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
        guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { throw CocoaError(.fileReadCorruptFile) }
        let saved = try ImportedVideoLibrary.shared.add(url: movie.url, title: "Video")
        try? FileManager.default.removeItem(at: movie.url)
        UserDefaults.standard.set(saved.id.uuidString, forKey: "lastOpenedImportedVideoID")
        return StudioLaunch(source: .video(saved.fileURL, saved.title))
    }
    guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return StudioLaunch(source: .image(image, "Photo"))
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("resolverAddress") private var address = MediaResolver.defaultAddress
    @State private var draft = ""
    private var valid: Bool {
        guard let url = URL(string: draft.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return ["http", "https"].contains(url.scheme ?? "") && url.host != nil && url.user == nil && url.password == nil
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { AccountView() } label: { Label("Account", systemImage: "person.crop.circle") }
                        .accessibilityIdentifier("accountSettingsButton")
                }
                Section("Video links") {
                    TextField("Media service address", text: $draft)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("The service opens public video links for the studio. Local videos and photos work without it.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !valid { Text("Enter a complete http:// or https:// address.").font(.caption).foregroundStyle(.red) }
                }
                Section("Made for your device") {
                    Label("Camera background removal runs on-device.", systemImage: "sparkles")
                    Label("Finished videos save to Photos automatically.", systemImage: "photo")
                    Label("Your camera opens in Studio. Recording starts when you tap Record.", systemImage: "camera")
                }.font(.subheadline)
                Section("RecordPOV") {
                    Link("recordpov.app", destination: URL(string: "https://recordpov.app")!)
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { address = draft.trimmingCharacters(in: .whitespacesAndNewlines); dismiss() }
                        .disabled(!valid)
                }
            }
            .onAppear { draft = address }
        }
        .presentationDetents([.large])
    }
}
