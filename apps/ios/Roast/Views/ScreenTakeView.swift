import PhotosUI
import ReplayKit
import SwiftUI

struct ScreenTakeView: View {
    let library: TakeLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var pending: [URL] = []
    @State private var selectedMedia: PhotosPickerItem?
    @State private var launch: StudioLaunch?
    @State private var isImporting = false
    @State private var errorMessage: String?

    private var recordingAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        RPScreenRecorder.shared().isAvailable && ScreenCaptureInbox.directory != nil
        #endif
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    Text("Record your screen first, then add your camera reaction.")
                        .font(.subheadline).foregroundStyle(RoastTheme.muted).lineSpacing(3)
                    VStack(alignment: .leading, spacing: 16) {
                        stepHeader(number: "01", title: "Record your screen")
                        Text("Start here, open the app you want to show, then stop from the recording indicator.")
                            .font(.subheadline).foregroundStyle(RoastTheme.muted)
                        HStack {
                            Label("Start screen recording", systemImage: "record.circle")
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                            if recordingAvailable { BroadcastPicker().frame(width: 52, height: 52) }
                            else { Image(systemName: "iphone.gen3").font(.title2).frame(width: 52, height: 52) }
                        }
                        .padding(.leading, 16).padding(.trailing, 5)
                        .background(RoastTheme.lime.opacity(recordingAvailable ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 14))
                        if !recordingAvailable {
                            Text("Screen recording isn’t available right now. You can choose an existing recording below.")
                                .font(.caption).foregroundStyle(RoastTheme.muted)
                        }
                    }
                    .padding(18).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 22))

                    VStack(alignment: .leading, spacing: 16) {
                        stepHeader(number: "02", title: "Add your reaction")
                        ForEach(pending, id: \.absoluteString) { file in
                            Button {
                                Task {
                                    isImporting = true
                                    defer { isImporting = false }
                                    do {
                                        let take = try await ScreenCaptureInbox.importCapture(file, library: library)
                                        try? await library.saveToPhotos(take)
                                        pending = ScreenCaptureInbox.pending()
                                        launch = StudioLaunch(source: .video(take.fileURL, "Screen recording"))
                                    } catch { errorMessage = "This screen recording couldn’t be imported." }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "play.rectangle.fill")
                                    Text("Open screen recording")
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                }.font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 48)
                                    .background(RoastTheme.lime, in: RoundedRectangle(cornerRadius: 14))
                            }.buttonStyle(.plain).disabled(isImporting)
                        }
                        PhotosPicker(selection: $selectedMedia, matching: .videos) {
                            HStack {
                                Image(systemName: "photo.on.rectangle")
                                Text(isImporting ? "Opening recording…" : "Choose a screen recording")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }.font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .padding(.horizontal, 14).frame(minHeight: 48)
                                .background(RoastTheme.paper, in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain).disabled(isImporting)
                        Text("Position your camera and record your reaction.")
                            .font(.caption).foregroundStyle(RoastTheme.muted)
                    }.padding(18).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 22))
                    if let errorMessage { InlineError(message: errorMessage) }
                    DisclosureGroup("Why record first on iPhone?") {
                        Text("iPhone doesn’t allow a movable camera over other apps in this mode. Record the screen first, then add your reaction in RecordPOV.")
                            .font(.footnote).foregroundStyle(RoastTheme.muted).padding(.top, 8)
                    }.font(.subheadline).padding(.horizontal, 6)
                }.padding(24)
            }
            .background(RoastTheme.paper).foregroundStyle(RoastTheme.ink)
            .navigationTitle("Screen recording").navigationBarTitleDisplayMode(.inline)
            .task { pending = ScreenCaptureInbox.pending() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { pending = ScreenCaptureInbox.pending() } }
            .task(id: selectedMedia) {
                guard let item = selectedMedia else { return }
                isImporting = true
                defer { isImporting = false }
                do { launch = try await importMedia(item); selectedMedia = nil }
                catch { errorMessage = "This recording couldn’t be opened. Try another video." }
            }
            .fullScreenCover(item: $launch) { StudioView(launch: $0, library: library) }
        }
    }

    private func stepHeader(number: String, title: String) -> some View {
        HStack(spacing: 12) {
            Text(number).font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 32, height: 32).background(RoastTheme.paper, in: Circle())
            Text(title).font(.system(.headline, design: .rounded))
        }
    }
}

private struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 52, height: 52))
        view.preferredExtension = (Bundle.main.bundleIdentifier ?? "com.roast.app") + ".ScreenBroadcast"
        view.showsMicrophoneButton = false
        view.tintColor = UIColor(RoastTheme.ink)
        view.accessibilityLabel = "Start screen recording in RecordPOV"
        return view
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) { }
}
