import Foundation

struct UnfinishedDraft: Identifiable, Sendable {
    let draft: RecordingDraft
    let modifiedAt: Date
    var id: UUID { draft.id }
}

/// Reads durable draft metadata and deletes a draft only on an explicit user action.
/// Saved absolute sandbox URLs are rebased because an app's container can move.
struct DraftStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Drafts", isDirectory: true)
    }

    let directory: URL
    init(directory: URL = DraftStore.directory) { self.directory = directory }

    func list() throws -> [UnfinishedDraft] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let folders = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: .skipsHiddenFiles)
        return folders.compactMap { candidate -> UnfinishedDraft? in
            let folder = candidate.standardizedFileURL
            guard let folderID = UUID(uuidString: folder.lastPathComponent),
                  let attributes = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  attributes.isDirectory == true, attributes.isSymbolicLink != true,
                  let data = try? Data(contentsOf: folder.appendingPathComponent("draft.json")),
                  let stored = try? JSONDecoder().decode(RecordingDraft.self, from: data),
                  stored.id == folderID, stored.duration.isFinite, stored.duration > 0,
                  let video = rebase(stored.videoURL, to: folder),
                  let videoAttributes = try? FileManager.default.attributesOfItem(atPath: video.path),
                  videoAttributes[.type] as? FileAttributeType == .typeRegular,
                  (videoAttributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else { return nil }
            let draft = RecordingDraft(id: stored.id, videoURL: video,
                microphoneURL: stored.microphoneURL.flatMap { rebase($0, to: folder) },
                sourceAudioURL: stored.sourceAudioURL.flatMap { rebase($0, to: folder) },
                duration: stored.duration, title: stored.title)
            let modified = [folder, folder.appendingPathComponent("draft.json"), folder.appendingPathComponent("edits.json")]
                .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                .max() ?? .distantPast
            return UnfinishedDraft(draft: draft, modifiedAt: modified)
        }.sorted {
            $0.modifiedAt == $1.modifiedAt ? $0.id.uuidString < $1.id.uuidString : $0.modifiedAt > $1.modifiedAt
        }
    }

    func delete(_ item: UnfinishedDraft) throws { try delete(id: item.id) }
    func delete(_ draft: RecordingDraft) throws { try delete(id: draft.id) }

    /// Derive the owned folder from its UUID; media URLs in metadata are never deletion targets.
    func delete(id: UUID) throws {
        let root = directory.standardizedFileURL
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true).standardizedFileURL
        guard root.isFileURL, folder.deletingLastPathComponent() == root else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let rootValues: URLResourceValues
        let folderValues: URLResourceValues
        do { rootValues = try root.resourceValues(forKeys: keys) }
        catch { if isMissing(error) { return }; throw error }
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        do { folderValues = try folder.resourceValues(forKeys: keys) }
        catch { if isMissing(error) { return }; throw error }
        guard folderValues.isDirectory == true, folderValues.isSymbolicLink != true,
              folder.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: folder)
    }

    private func isMissing(_ error: Error) -> Bool {
        let failure = error as NSError
        return failure.domain == NSCocoaErrorDomain &&
            (failure.code == NSFileReadNoSuchFileError || failure.code == NSFileNoSuchFileError)
    }

    private func rebase(_ stored: URL, to folder: URL) -> URL? {
        let name = stored.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name != "/" else { return nil }
        return folder.appendingPathComponent(name, isDirectory: false)
    }
}
