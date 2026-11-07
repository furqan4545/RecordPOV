import SwiftUI

struct LibraryView: View {
    let library: TakeLibrary
    let onCreate: () -> Void
    @AppStorage("lastOpenedImportedVideoID") private var lastOpenedImportedID = ""
    @State private var importedLaunch: StudioLaunch?
    @State private var shelf: VideoShelf = .saved

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("My videos")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 20)
                Picker("Show", selection: $shelf) {
                    Text("Saved videos").tag(VideoShelf.saved)
                    Text("Imported videos").tag(VideoShelf.imported)
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .accessibilityIdentifier("myVideosFilter")
                HomeRecentVideos(library: library, title: nil, shelf: shelf) { video in
                    VideoImportCoordinator.shared.deferOpeningUntilRequested()
                    if VideoImportCoordinator.shared.ready?.id == video.id { VideoImportCoordinator.shared.consumeReady() }
                    lastOpenedImportedID = video.id.uuidString
                    importedLaunch = StudioLaunch(source: .video(video.fileURL, video.title))
                }
                Button("Add a video", action: onCreate)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .padding(.horizontal, 18).frame(minHeight: 48)
                    .background(RoastTheme.lime, in: RoundedRectangle(cornerRadius: 14))
                    .buttonStyle(.plain)
                if let message = library.errorMessage { InlineError(message: message) }
            }.padding(.horizontal, 24).padding(.bottom, 25)
        }
        .foregroundStyle(RoastTheme.ink).background(RoastTheme.paper)
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $importedLaunch) { StudioView(launch: $0, library: library) }
    }
}
