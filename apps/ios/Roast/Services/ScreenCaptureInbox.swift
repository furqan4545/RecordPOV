import AVFoundation
import Foundation

enum ScreenCaptureInbox {
    static var appGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "RoastAppGroupIdentifier") as? String ?? "group.com.roast.app"
    }

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("ScreenTakes", isDirectory: true)
    }

    static func pending() -> [URL] {
        guard let directory else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? [])
            .filter { $0.pathExtension == "mp4" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    @MainActor static func importCapture(_ source: URL, library: TakeLibrary) async throws -> SavedTake {
        let duration = try await AVURLAsset(url: source).load(.duration).seconds
        let take = try library.add(url: source, title: "Screen recording", duration: duration, kind: "Screen")
        try? FileManager.default.removeItem(at: source)
        return take
    }
}

