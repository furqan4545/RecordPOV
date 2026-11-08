import AVKit
import SwiftUI

struct TakeDetailView: View {
    let library: TakeLibrary
    /// The video shown. Re-edit swaps in the newly saved one.
    @State private var take: SavedTake
    @State private var editableDraft: RecordingDraft?
    @State private var reEditDraft: RecordingDraft?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var player: AVPlayer?
    @State private var errorMessage: String?
    @State private var isSharing = false

    init(take: SavedTake, library: TakeLibrary) {
        _take = State(initialValue: take)
        self.library = library
    }

    private var isSaved: Bool { library.isSavedToPhotos(take) }
    private var isSaving: Bool { library.isSavingToPhotos(take) }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
            GeometryReader { geometry in
                if dynamicTypeSize.isAccessibilitySize || geometry.size.height < 540 {
                    ScrollView {
                        VStack(spacing: 18) {
                            videoPreview.frame(height: min(320, max(200, geometry.size.height * 0.55)))
                            information
                            actions
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    VStack(spacing: 18) {
                        videoPreview.frame(maxHeight: .infinity)
                        information
                        actions
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
        .foregroundStyle(RoastTheme.ink)
        .tint(RoastTheme.ink)
        .background(RoastTheme.paper.ignoresSafeArea())
        .preferredColorScheme(.light)
        .presentationBackground(RoastTheme.paper)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            if player == nil { player = AVPlayer(url: take.fileURL) }
            editableDraft = Self.draft(for: take)
        }
        .onChange(of: take.id) { _, _ in
            player?.pause()
            player = AVPlayer(url: take.fileURL)
            editableDraft = Self.draft(for: take)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { player?.pause() }
        }
        .onDisappear { player?.pause() }
        .sheet(isPresented: $isSharing) { SavedVideoShareSheet(url: take.fileURL) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Your video")
                .font(.headline)
                .lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            Menu {
                if let draft = editableDraft {
                    Button("Re-edit", systemImage: "slider.horizontal.3") {
                        player?.pause()
                        reEditDraft = draft
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("reEditSavedVideoButton")
                }
                Button("Delete from My videos", systemImage: "trash", role: .destructive) {
                    player?.pause()
                    do { try library.delete(take); dismiss() }
                    catch { errorMessage = "The video couldn’t be deleted. Try again." }
                }
                .disabled(isSaving)
            } label: { headerIcon("ellipsis") }
            .accessibilityLabel("Video options")
            .accessibilityIdentifier("savedVideoOptionsButton")
            Button {
                player?.pause()
                dismiss()
            } label: { headerIcon("xmark") }
            .accessibilityLabel("Close video")
            .accessibilityIdentifier("closeSavedVideoButton")
        }
        .buttonStyle(.plain)
        // Back to the editor with the same recording and edits; saving replaces this video.
        .fullScreenCover(item: $reEditDraft) { draft in
            EditorView(draft: draft, library: library) { take = $0 }
        }
    }

    /// The draft this video was saved from, if it's still on this iPhone.
    private static func draft(for take: SavedTake) -> RecordingDraft? {
        guard let id = take.draftID else { return nil }
        return (try? DraftStore().list())?.first { $0.id == id }?.draft
    }

    private func headerIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(RoastTheme.ink)
            .frame(width: 44, height: 44)
            .background(RoastTheme.ink.opacity(0.06), in: Circle())
            .contentShape(Circle())
    }

    private var videoPreview: some View {
        VideoPlayer(player: player)
            .tint(.white)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .accessibilityLabel("Your video preview")
            .accessibilityIdentifier("savedVideoPreview")
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(take.title.isEmpty ? "Your video" : take.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("savedVideoTitle")
            HStack(spacing: 8) {
                Text(take.displayKind)
                Text("·").accessibilityHidden(true)
                Text(take.formattedDuration).monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(RoastTheme.muted)
            HStack(spacing: 7) {
                if isSaving {
                    ProgressView().tint(RoastTheme.ink)
                } else {
                    Image(systemName: isSaved ? "checkmark.circle.fill" : "checkmark.circle")
                }
                Text(isSaving ? "Saving to Photos…" : isSaved ? "Saved to Photos" : "Saved in My videos")
            }
            .font(.subheadline.weight(.medium))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("savedVideoStatus")
            .accessibilityAddTraits(.updatesFrequently)
            if let message = errorMessage ?? library.photoSaveError(for: take) {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityIdentifier("savedVideoError")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                player?.pause()
                isSharing = true
            } label: {
                Group {
                    if dynamicTypeSize.isAccessibilitySize { Text("Share video") }
                    else { Label("Share video", systemImage: "square.and.arrow.up") }
                }
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(RoastTheme.ink)
                    .background(RoastTheme.lime, in: RoundedRectangle(cornerRadius: 16))
            }
            .accessibilityIdentifier("shareSavedVideoButton")
            if !isSaved && !isSaving {
                Button { Task { await saveToPhotos() } } label: {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize { Text("Save to Photos") }
                        else { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                    }
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(RoastTheme.ink.opacity(0.14)))
                }
                .accessibilityIdentifier("saveTakeToPhotosButton")
            }
        }
        .buttonStyle(.plain)
    }

    private func saveToPhotos() async {
        do { try await library.saveToPhotos(take) }
        catch { /* The library exposes the save error and keeps the app copy. */ }
    }
}

private struct SavedVideoShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
