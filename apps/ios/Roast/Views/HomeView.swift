import PhotosUI
import SwiftUI

private enum HomeSheet: String, Identifiable {
    case profile
    var id: String { rawValue }
}

struct HomeView: View {
    let library: TakeLibrary
    #if !APP_STORE
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    private let importer = VideoImportCoordinator.shared
    @AppStorage("resolverAddress") private var resolverAddress = MediaResolver.defaultAddress
    private let importedVideos = ImportedVideoLibrary.shared
    @State private var link = ""
    @State private var needsNetworkSettings = false
    @State private var isVisible = false
    @FocusState private var linkFocused: Bool

    private var loadingPhase: VideoLinkLoadingPhase { importer.phase }
    private var isResolving: Bool { loadingPhase != .idle }
    #endif
    @Environment(AccountService.self) private var account
    @AppStorage("lastOpenedImportedVideoID") private var lastOpenedImportedID = ""
    @AppStorage("didFinishOnboarding") private var didFinishOnboarding = false
    @State private var errorMessage: String?
    @State private var isImporting = false
    @State private var selectedMedia: PhotosPickerItem?
    @State private var launch: StudioLaunch?
    @State private var sheet: HomeSheet?
    /// Recent's Select mode, started by holding a video.
    @State private var recentSelection = VideoSelection()

    var body: some View {
        Group {
            if didFinishOnboarding {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        importCard
                        HomeRecentVideos(library: library, selection: recentSelection, onOpenImport: openImportedVideo)
                    }
                    .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 30)
                }
                .safeAreaInset(edge: .bottom) {
                    if recentSelection.isActive {
                        DeleteSelectedBar(selection: recentSelection, identifier: "deleteSelectedRecentVideosButton")
                    }
                }
                .background(RoastTheme.paper)
                .scrollDismissesKeyboard(.interactively)
            } else {
                OnboardingView { didFinishOnboarding = true }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: didFinishOnboarding)
        .buttonStyle(.plain)
        .toolbar(.hidden, for: .navigationBar)
        .toolbarVisibility(didFinishOnboarding ? .automatic : .hidden, for: .tabBar)
        // Opens a finished import once the sheet has fully gone, not mid-dismissal.
        .sheet(item: $sheet, onDismiss: { openReadyImport() }) { destination in
            switch destination {
            case .profile: ProfileView()
            }
        }
        .fullScreenCover(item: $launch) { StudioView(launch: $0, library: library) }
        #if !APP_STORE
        .onAppear { isVisible = true; importer.resumeIfNeeded(); openReadyImport() }
        .onDisappear { isVisible = false }
        .onChange(of: importer.ready?.id) { _, _ in openReadyImport() }
        .onChange(of: didFinishOnboarding) { _, _ in openReadyImport() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { importer.resumeIfNeeded(); openReadyImport() }
        }
        #endif
        .task(id: selectedMedia) {
            guard let item = selectedMedia else { return }
            #if !APP_STORE
            importer.deferOpeningUntilRequested()
            #endif
            errorMessage = nil
            isImporting = true
            defer { isImporting = false }
            do {
                let picked = try await importMedia(item)
                await waitForPresentationsToClear()
                launch = picked
                selectedMedia = nil
            } catch { errorMessage = "This file couldn’t be opened. Try another video or photo." }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark()
            Text("RecordPOV").font(.system(size: 25, weight: .bold, design: .rounded))
            Spacer()
            Button { sheet = .profile } label: {
                ProfileAvatar(user: account.session?.user, size: 36)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Profile").accessibilityIdentifier("profileButton")
        }
        .foregroundStyle(RoastTheme.ink)
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add a video").font(.system(.title2, design: .rounded, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                #if APP_STORE
                Text("Choose a video or photo from your library, then record your reaction.")
                    .font(.subheadline).foregroundStyle(RoastTheme.muted)
                #endif
            }
            #if !APP_STORE
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
            PlatformIconRow(size: 24)

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
            #else
            if let errorMessage { InlineError(message: errorMessage) }
            #endif
            PhotosPicker(selection: $selectedMedia, matching: .any(of: [.videos, .images]), photoLibrary: .shared()) {
                #if APP_STORE
                let title = "Choose video or photo"
                let background = RoastTheme.lime
                #else
                let title = "Upload video or photo"
                let background = RoastTheme.paper
                #endif
                Label(isImporting ? "Opening…" : title, systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(minHeight: 48)
                    .background(background, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(isImporting).accessibilityIdentifier("importMediaButton")
        }
        .padding(18).foregroundStyle(RoastTheme.ink)
        .background(.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white, lineWidth: 1))
    }

    #if !APP_STORE
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

    private func cancelResolution() { importer.cancel() }
    #endif

    private func openReadyImport() {
        #if !APP_STORE
        // A finished import waits until the first-launch onboarding is done.
        guard didFinishOnboarding, isVisible, scenePhase == .active, sheet == nil, launch == nil, !isImporting,
              let ready = importer.ready else { return }
        guard importer.shouldAutomaticallyOpen else { return }
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
        #endif
    }

    private func openImportedVideo(_ video: ImportedVideo) {
        guard launch == nil, sheet == nil else { return }
        #if !APP_STORE
        linkFocused = false
        importer.deferOpeningUntilRequested()
        if importer.ready?.id == video.id { importer.consumeReady() }
        #endif
        lastOpenedImportedID = video.id.uuidString
        launch = StudioLaunch(source: .video(video.fileURL, video.title))
    }
}

/// The Photos picker can still be closing when its pick arrives. Opening Studio over a
/// closing sheet leaves a Studio whose video never loads and that can't be tapped, so
/// wait until nothing is presented or mid-transition (at most 3 seconds).
@MainActor
func waitForPresentationsToClear() async {
    for _ in 0..<60 {
        let busy = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter(\.isKeyWindow)
            .contains { window in
                guard let root = window.rootViewController else { return false }
                return root.presentedViewController != nil || root.transitionCoordinator != nil
            }
        if !busy { return }
        try? await Task.sleep(for: .milliseconds(50))
    }
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
