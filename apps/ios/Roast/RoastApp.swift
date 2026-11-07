import SwiftUI

@main
struct RoastApp: App {
    @UIApplicationDelegateAdaptor(RecordPOVAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let importer = VideoImportCoordinator.shared
    @State private var library = TakeLibrary()
    @State private var selectedTab: AppTab = .create
    #if DEBUG
    @State private var editorPreviewDraft: RecordingDraft?
    #endif
    private enum AppTab: Hashable { case create, takes, screen }
    init() {
        MediaServiceSettings.migrateLegacyDefaultIfNeeded()
        #if DEBUG
        UserRequestedDraftCleanup.runIfRequested()
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
                Tab("Screen", systemImage: "record.circle", value: AppTab.screen) {
                    ScreenTakeView(library: library)
                }
            }
            .tint(RoastTheme.ink)
            .preferredColorScheme(.light)
            .onOpenURL { _ = NativeAccountIdentity.handle($0) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { importer.resumeIfNeeded() }
                else if phase == .background { importer.didEnterBackground() }
            }
            #if DEBUG
            .fullScreenCover(item: $editorPreviewDraft) { draft in
                EditorView(draft: draft, library: library, onSaved: { _ in })
            }
            #endif
            .task {
                importer.resumeIfNeeded()
                #if DEBUG
                if ProcessInfo.processInfo.environment["ROAST_CONNECTION_DIAGNOSTICS"] == "1" {
                    await MediaResolver.runConnectionDiagnostics()
                }
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
        }
    }
}
