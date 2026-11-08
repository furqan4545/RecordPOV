import AVFoundation
import SwiftUI
import UIKit

/// Which videos a shelf lists: the user's own work, or imported source videos.
enum VideoShelf: Hashable { case saved, imported }

/// Select mode for Create's Recent and My videos: which cards are checked, and whether
/// Delete is being confirmed. Holding a card and choosing Select starts it.
@MainActor @Observable
final class VideoSelection {
    var isActive = false
    var ids: Set<String> = []
    var isConfirmingDelete = false

    func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    func end() { isActive = false; ids = []; isConfirmingDelete = false }
}

struct HomeRecentVideos: View {
    let library: TakeLibrary
    let title: String?
    let shelf: VideoShelf
    let onOpenImport: (ImportedVideo) -> Void
    /// Set by My videos to allow selecting several videos; Create's Recent leaves it nil.
    let selection: VideoSelection?
    @Environment(\.scenePhase) private var scenePhase
    @State private var imports = ImportedVideoLibrary.shared
    @State private var drafts: [UnfinishedDraft] = []
    @State private var editing: RecordingDraft?
    @State private var selectedTake: SavedTake?
    @State private var editorSavedTake: SavedTake?
    @State private var errorMessage: String?

    init(library: TakeLibrary, title: String? = "Recent", shelf: VideoShelf = .imported,
         selection: VideoSelection? = nil, onOpenImport: @escaping (ImportedVideo) -> Void) {
        self.library = library
        self.title = title
        self.shelf = shelf
        self.selection = selection
        self.onOpenImport = onOpenImport
    }

    private var isSelecting: Bool { selection?.isActive == true }

    private var recent: [RecentVideo] {
        let combined: [RecentVideo]
        switch shelf {
        case .imported: combined = imports.videos.map(RecentVideo.imported)
        case .saved:
            // A draft that has been saved is reached through its video's Re-edit instead.
            let unsaved = drafts.filter { draft in !library.takes.contains { $0.draftID == draft.id } }
            combined = unsaved.map(RecentVideo.draft) + library.takes.map(RecentVideo.saved)
        }
        var seen = Set<String>()
        return combined.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }.filter { seen.insert($0.fileURL.standardizedFileURL.path).inserted }
    }

    var body: some View {
        let items = recent
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(RoastTheme.ink).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if isSelecting {
                        Button("Cancel") { selection?.end() }
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .foregroundStyle(RoastTheme.ink)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("cancelRecentSelectionButton")
                    }
                }
            }
            if let errorMessage { InlineError(message: errorMessage) }
            if items.isEmpty {
                Text(emptyText).font(.subheadline).foregroundStyle(RoastTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                          alignment: .leading, spacing: 20) {
                    ForEach(items) { item in
                        let checked = selection?.ids.contains(item.id) == true
                        Button {
                            if let selection, selection.isActive { selection.toggle(item.id) } else { open(item) }
                        } label: {
                            RecentVideoCard(item: item)
                                .overlay(alignment: .topTrailing) {
                                    if isSelecting { SelectionMark(checked: checked).padding(10) }
                                }
                        }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(item.kind), \(item.title)")
                            .accessibilityAddTraits(isSelecting && checked ? .isSelected : [])
                            .accessibilityIdentifier(item.id)
                            .contextMenu {
                                if !isSelecting {
                                    if let selection {
                                        Button("Select", systemImage: "checkmark.circle") {
                                            selection.ids = [item.id]
                                            selection.isActive = true
                                        }
                                    }
                                    Button("Delete permanently", systemImage: "trash", role: .destructive) { delete(item) }
                                }
                            }
                    }
                }
            }
        }
        .sheet(item: $selectedTake) { TakeDetailView(take: $0, library: library) }
        .fullScreenCover(item: $editing, onDismiss: {
            refreshDrafts()
            if let saved = editorSavedTake { editorSavedTake = nil; selectedTake = saved }
        }) { draft in
            EditorView(draft: draft, library: library) { editorSavedTake = $0 }
        }
        .confirmationDialog(deleteTitle(count: selectedItems(in: items).count),
                            isPresented: Binding(get: { selection?.isConfirmingDelete ?? false },
                                                 set: { selection?.isConfirmingDelete = $0 }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSelected(selectedItems(in: items)) }
                .accessibilityIdentifier("confirmDeleteSelectedVideosButton")
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(shelf == .saved
                 ? "They’re removed from My videos. Copies already in Photos stay in Photos."
                 : "They’re removed from this iPhone. You can download them again from their links.")
        }
        // Forget checks on cards that are no longer listed.
        .onChange(of: items.map(\.id)) { _, ids in selection?.ids.formIntersection(ids) }
        .task { await imports.recoverLegacySources(); refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
        .onChange(of: library.takes.map(\.id)) { _, _ in refreshDrafts() }
        .onChange(of: imports.videos.map(\.id)) { _, _ in refreshDrafts() }
        .onChange(of: shelf) { _, _ in errorMessage = nil; refreshDrafts() }
    }

    private var emptyText: String {
        switch shelf {
        case .imported: "Videos you import appear here."
        case .saved: "Your saved videos and unfinished edits appear here."
        }
    }

    private func open(_ item: RecentVideo) {
        switch item {
        case .imported(let video):
            // Imports are local files, so reopening never needs the media service.
            guard FileManager.default.fileExists(atPath: video.fileURL.path) else {
                try? imports.reload()
                if VideoImportCoordinator.shared.ready?.id == video.id { VideoImportCoordinator.shared.consumeReady() }
                // Uploads have no link to paste, so name the control that adds them again.
                errorMessage = video.sourceURL == nil
                    ? "This video is no longer on this iPhone. Add it again with Upload video or photo."
                    : "This video is no longer on this iPhone. Paste its link to download it again."
                return
            }
            errorMessage = nil
            onOpenImport(video)
        case .draft(let unfinished):
            VideoImportCoordinator.shared.deferOpeningUntilRequested()
            editing = unfinished.draft
        case .saved(let take):
            VideoImportCoordinator.shared.deferOpeningUntilRequested()
            selectedTake = take
        }
    }
    private func selectedItems(in items: [RecentVideo]) -> [RecentVideo] {
        guard let selection else { return [] }
        return items.filter { selection.ids.contains($0.id) }
    }

    private func deleteTitle(count: Int) -> String {
        count == 1 ? "Delete this video?" : "Delete \(count) videos?"
    }

    /// Deletes every checked video, keeps going past failures, then leaves Select mode.
    private func deleteSelected(_ items: [RecentVideo]) {
        var failed = 0
        for item in items {
            do { try remove(item) } catch { failed += 1 }
        }
        refreshDrafts()
        selection?.end()
        errorMessage = failed == 0 ? nil
            : failed == 1 ? "1 video couldn’t be deleted. Try again." : "\(failed) videos couldn’t be deleted. Try again."
    }

    private func remove(_ item: RecentVideo) throws {
        switch item {
        case .imported(let video):
            try imports.delete(video)
            if VideoImportCoordinator.shared.ready?.id == video.id { VideoImportCoordinator.shared.consumeReady() }
        case .draft(let item): try DraftStore().delete(item)
        case .saved(let take): try library.delete(take)
        }
    }

    private func delete(_ item: RecentVideo) {
        do {
            switch item {
            case .imported(let video):
                try imports.delete(video)
                if VideoImportCoordinator.shared.ready?.id == video.id { VideoImportCoordinator.shared.consumeReady() }
            case .draft(let item): try DraftStore().delete(item)
            case .saved(let take): try library.delete(take)
            }
            errorMessage = nil
            refreshDrafts()
        } catch {
            errorMessage = "This video couldn’t be deleted. \(error.localizedDescription)"
        }
    }
    private func refresh() {
        do { try imports.reload() }
        catch { errorMessage = "Your videos couldn’t be loaded. Their files have been kept." }
        refreshDrafts()
    }
    private func refreshDrafts() {
        // Only the Saved videos shelf shows unfinished edits.
        guard shelf == .saved else { return }
        do { drafts = try DraftStore().list() }
        catch { errorMessage = "Your recordings couldn’t be loaded. Try again." }
    }
}

private enum RecentVideo: Identifiable {
    case imported(ImportedVideo), draft(UnfinishedDraft), saved(SavedTake)
    var id: String {
        switch self {
        case .imported(let video): "recentImported-\(video.id.uuidString)"
        case .draft(let item): "recentDraft-\(item.id.uuidString)"
        case .saved(let take): "recentSaved-\(take.id.uuidString)"
        }
    }
    var fileURL: URL {
        switch self { case .imported(let video): video.fileURL; case .draft(let item): item.draft.videoURL; case .saved(let take): take.fileURL }
    }
    var title: String {
        let value: String
        switch self { case .imported(let video): value = video.title; case .draft(let item): value = item.draft.title; case .saved(let take): value = take.title }
        return value.isEmpty ? "Your video" : value
    }
    var kind: String {
        switch self { case .imported: "Imported"; case .draft: "Continue editing"; case .saved: "Saved" }
    }
    var date: Date {
        switch self { case .imported(let video): video.createdAt; case .draft(let item): item.modifiedAt; case .saved(let take): take.createdAt }
    }
}

/// The Delete button pinned to the bottom of the screen while selecting videos.
struct DeleteSelectedBar: View {
    let selection: VideoSelection
    let identifier: String

    var body: some View {
        Button(role: .destructive) { selection.isConfirmingDelete = true } label: {
            Label(selection.ids.isEmpty ? "Delete" : "Delete \(selection.ids.count)", systemImage: "trash")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(selection.ids.isEmpty ? RoastTheme.muted : .red)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(RoastTheme.ink.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .disabled(selection.ids.isEmpty)
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(RoastTheme.paper)
        .accessibilityIdentifier(identifier)
    }
}

/// The round check on a card in Select mode.
private struct SelectionMark: View {
    let checked: Bool
    var body: some View {
        ZStack {
            Circle().fill(checked ? RoastTheme.lime : .black.opacity(0.25))
            Circle().stroke(.white, lineWidth: 2)
            if checked {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(RoastTheme.ink)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

private struct RecentVideoCard: View {
    let item: RecentVideo
    @State private var thumbnail: UIImage?
    /// Keeps thumbnails across shelf switches so cards do not flash or decode again.
    private static let cache = NSCache<NSURL, UIImage>()

    init(item: RecentVideo) {
        self.item = item
        _thumbnail = State(initialValue: Self.cache.object(forKey: item.fileURL as NSURL))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(RoastTheme.ink)
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    } else {
                        Image(systemName: "play.rectangle").font(.system(size: 26, weight: .light)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(height: 210).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(RoastTheme.ink)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(item.kind).font(.caption2).foregroundStyle(RoastTheme.muted).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        .task(id: item.fileURL) {
            if let cached = Self.cache.object(forKey: item.fileURL as NSURL) { thumbnail = cached; return }
            thumbnail = nil
            let asset = AVURLAsset(url: item.fileURL)
            defer { withExtendedLifetime(asset) {} }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 450, height: 630)
            if let result = try? await generator.image(at: .zero), !Task.isCancelled {
                let image = UIImage(cgImage: result.image)
                Self.cache.setObject(image, forKey: item.fileURL as NSURL)
                thumbnail = image
            }
        }
    }
}
