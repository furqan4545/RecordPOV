import SwiftUI

@main
struct RoastApp: App {
    #if !APP_STORE
    @UIApplicationDelegateAdaptor(RecordPOVAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let importer = VideoImportCoordinator.shared
    #endif
    @State private var library = TakeLibrary()
    /// One sign-in state for the whole app: the Create avatar, Profile and the editor's Save.
    @State private var account = AccountService()
    @State private var selectedTab: AppTab = .create
    #if DEBUG
    @State private var editorPreviewDraft: RecordingDraft?
    #endif
    private enum AppTab: Hashable { case create, takes }
    init() {
        #if !APP_STORE
        MediaServiceSettings.migrateLegacyDefaultIfNeeded()
        #endif
        #if DEBUG
        UserRequestedDraftCleanup.runIfRequested()
        // Lets a developer see the first-launch onboarding again without deleting the app.
        if ProcessInfo.processInfo.environment["ROAST_RESET_ONBOARDING"] == "1" {
            UserDefaults.standard.removeObject(forKey: "didFinishOnboarding")
        }
        #endif
    }
    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                Tab("Create", systemImage: "plus.viewfinder", value: AppTab.create) {
                    NavigationStack { HomeView(library: library) }
                }
                Tab("My videos", systemImage: "rectangle.stack", value: AppTab.takes) {
                    NavigationStack { LibraryView(library: library, onCreate: { selectedTab = .create }) }
                }
            }
            .tint(RoastTheme.ink)
            .preferredColorScheme(.light)
            .onOpenURL { _ = NativeAccountIdentity.handle($0) }
            #if !APP_STORE
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { importer.resumeIfNeeded() }
                else if phase == .background { importer.didEnterBackground() }
            }
            #endif
            #if DEBUG
            .fullScreenCover(item: $editorPreviewDraft) { draft in
                EditorView(draft: draft, library: library, onSaved: { _ in })
            }
            #endif
            .task {
                #if !APP_STORE
                importer.resumeIfNeeded()
                #endif
                #if DEBUG
                #if !APP_STORE
                if ProcessInfo.processInfo.environment["ROAST_CONNECTION_DIAGNOSTICS"] == "1" {
                    await MediaResolver.runConnectionDiagnostics()
                }
                #endif
                if ProcessInfo.processInfo.environment["ROAST_CAMERA_DIAGNOSTICS"] == "1" {
                    await StudioEngine.runCameraDiagnostics()
                }
                if ProcessInfo.processInfo.environment["ROAST_MATTE_DIAGNOSTICS"] == "1" {
                    await PersonMatteDiagnostics.run()
                }
                if ProcessInfo.processInfo.environment["ROAST_EDITOR_DIAGNOSTICS"] == "1" {
                    await EditorDiagnostics.run()
                }
                if ProcessInfo.processInfo.environment["ROAST_DRAFT_TIMING_DIAGNOSTICS"] == "1" {
                    await DraftTimingDiagnostics.run()
                }
                if ProcessInfo.processInfo.environment["ROAST_MICROPHONE_DIAGNOSTICS"] == "1" {
                    await StudioMicrophoneDiagnostics.run()
                }
                if ProcessInfo.processInfo.environment["ROAST_EDITOR_PREVIEW"] == "1" {
                    let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("EditorTest", isDirectory: true)
                    let capture = folder.appendingPathComponent("capture.mov")
                    let source = folder.appendingPathComponent("source.m4a")
                    if FileManager.default.fileExists(atPath: capture.path),
                       FileManager.default.fileExists(atPath: source.path) {
                        editorPreviewDraft = RecordingDraft(id: UUID(), videoURL: capture,
                            microphoneURL: capture, sourceAudioURL: source, duration: 3,
                            title: "Synthetic editor preview")
                    }
                }
                #endif
            }
            .task { await account.load() }
            .environment(account)
        }
    }
}
