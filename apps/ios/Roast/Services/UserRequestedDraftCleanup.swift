#if DEBUG
import Foundation

/// Explicit, one-launch maintenance requested by the owner. This never runs
/// during ordinary launches and targets only the captured draft UUIDs.
enum UserRequestedDraftCleanup {
    static func runIfRequested() {
        guard let input = ProcessInfo.processInfo.environment["ROAST_USER_REQUESTED_DELETE_DRAFT_IDS"], !input.isEmpty else { return }
        let ids = Set(input.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        let store = DraftStore()
        var deleted: [String] = [], missing: [String] = []
        var failures: [String: String] = [:]
        for id in ids {
            let folder = store.directory.appendingPathComponent(id.uuidString, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { missing.append(id.uuidString); continue }
            do {
                try store.delete(id: id)
                if !FileManager.default.fileExists(atPath: folder.path) { deleted.append(id.uuidString) }
                else { failures[id.uuidString] = "The draft folder is still present." }
            } catch { failures[id.uuidString] = error.localizedDescription }
        }
        let report: [String: Any] = ["requested": ids.count, "deleted": deleted.sorted(), "alreadyMissing": missing.sorted(), "failures": failures]
        if let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: cache.appendingPathComponent("UserRequestedDraftCleanup.json"), options: .atomic)
        }
    }
}
#endif
