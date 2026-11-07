import CryptoKit
import Foundation
import Observation

struct ImportedVideo: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let fileName: String
    var title: String
    let createdAt: Date
    var sourceURL: URL?
    var platform: String?
    var duration: TimeInterval?
    var qualityVersion: Int? = nil
    fileprivate var legacyKey: String?
    fileprivate var storageDirectory: URL? = nil

    var fileURL: URL { (storageDirectory ?? ImportedVideoLibrary.directory).appendingPathComponent(fileName) }
    private enum CodingKeys: String, CodingKey { case id, fileName, title, createdAt, sourceURL, platform, duration, qualityVersion, legacyKey }
}

/// Original imports are independent of draft captures, isolated audio stems,
/// and finished videos. Only this directory's own files may be deleted here.
@MainActor @Observable
final class ImportedVideoLibrary {
    static let shared = ImportedVideoLibrary()
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImportedVideos", isDirectory: true)
    }
    private(set) var videos: [ImportedVideo] = []
    private(set) var isRecovering = false
    var errorMessage: String?
    private let storageDirectory: URL
    private let legacyDirectories: [URL]
    private var migration = Migration()
    private var indexURL: URL { storageDirectory.appendingPathComponent("index.json") }
    private var migrationURL: URL { storageDirectory.appendingPathComponent("legacy-recovery-v1.json") }
    private struct Migration: Codable { var complete = false; var processed: Set<String> = [] }

    init(directory: URL? = nil, legacyDirectories: [URL]? = nil) {
        storageDirectory = (directory ?? Self.directory).standardizedFileURL
        self.legacyDirectories = legacyDirectories ?? (directory == nil ? [
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("SourceVideos"),
            FileManager.default.temporaryDirectory.appendingPathComponent("RoastImports"),
        ] : [])
        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: storageDirectory.path)
            if let data = try? Data(contentsOf: migrationURL), let saved = try? JSONDecoder().decode(Migration.self, from: data) { migration = saved }
            try reload()
        } catch { errorMessage = "Your imported videos couldn’t be loaded. Their files have been kept." }
        if directory == nil { Task { await recoverLegacySources() } }
    }

    /// The caller validates native playback before adding. importID makes a
    /// restored background job safe to commit again after a crash.
    @discardableResult
    func add(url: URL, title: String, sourceURL: URL? = nil, platform: String? = nil,
             importID: UUID? = nil, duration: TimeInterval? = nil, qualityVersion: Int? = nil) throws -> ImportedVideo {
        if let importID, let existing = videos.first(where: { $0.id == importID && Self.regularFile($0.fileURL) }) { return existing }
        guard url.isFileURL, Self.regularFile(url) else { throw ImportError.unavailable }
        let source = url.standardizedFileURL
        if let existing = videos.first(where: { $0.id == importID || $0.fileURL.standardizedFileURL == source }) { return existing }
        let id = importID ?? UUID()
        let ext = Self.extensions.contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : "mp4"
        let name = "\(id.uuidString).\(ext)"
        let destination = storageDirectory.appendingPathComponent(name)
        let createdCopy: Bool
        if Self.regularFile(destination) { createdCopy = false }
        else {
            let pending = storageDirectory.appendingPathComponent(".\(id.uuidString).importing")
            defer { try? FileManager.default.removeItem(at: pending) }
            try FileManager.default.copyItem(at: source, to: pending)
            try FileManager.default.moveItem(at: pending, to: destination)
            createdCopy = true
        }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        let item = ImportedVideo(id: id, fileName: name, title: title.isEmpty ? "Imported video" : title,
            createdAt: .now, sourceURL: Self.publicSource(sourceURL), platform: platform,
            duration: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }, qualityVersion: qualityVersion, legacyKey: legacyKey(for: source), storageDirectory: storageDirectory)
        let previous = videos
        videos.insert(item, at: 0)
        do { try persist(); errorMessage = nil; return item }
        catch {
            videos = previous
            if createdCopy { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
    }

    func delete(_ video: ImportedVideo) throws {
        guard let stored = videos.first(where: { $0.id == video.id }) else { return }
        if let key = stored.legacyKey { migration.processed.insert(key); try persistMigration() }
        let trash = storageDirectory.appendingPathComponent(".deleted-\(stored.id.uuidString)-\(UUID().uuidString)")
        let hasFile = FileManager.default.fileExists(atPath: stored.fileURL.path)
        if hasFile { try FileManager.default.moveItem(at: stored.fileURL, to: trash) }
        let previous = videos
        videos.removeAll { $0.id == stored.id }
        do { try persist() }
        catch {
            videos = previous
            if hasFile { try? FileManager.default.moveItem(at: trash, to: stored.fileURL) }
            throw error
        }
        // A crash after committing deletion cannot rediscover this hidden file
        // as an unindexed import. Its source and any draft copies are separate.
        if hasFile { try? FileManager.default.removeItem(at: trash) }
    }

    func reload() throws {
        let manager = FileManager.default
        var stored: [ImportedVideo] = []
        if manager.fileExists(atPath: indexURL.path) {
            let data = try Data(contentsOf: indexURL)
            do { stored = try JSONDecoder().decode([ImportedVideo].self, from: data) }
            catch {
                // Keep the original manifest for recovery before rebuilding an
                // index from owned media; never discard the media itself.
                try data.write(to: storageDirectory.appendingPathComponent("index-recovery-\(UUID()).json"), options: .atomic)
                errorMessage = "Your imported videos were recovered. Their files have been kept."
            }
        }
        var seen: Set<UUID> = []
        videos = try stored.compactMap { item in
            guard Self.safeName(item.fileName), try Self.fileIsPresent(storageDirectory.appendingPathComponent(item.fileName)),
                  seen.insert(item.id).inserted else { return nil }
            var bound = item; bound.storageDirectory = storageDirectory
            return bound
        }
        let knownNames = Set(videos.map(\.fileName))
        let files = try manager.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)
        for file in files where Self.extensions.contains(file.pathExtension.lowercased()) && !knownNames.contains(file.lastPathComponent) {
            guard try Self.fileIsPresent(file) else { continue }
            let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) ?? UUID()
            guard seen.insert(id).inserted else { continue }
            let date = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
            videos.append(ImportedVideo(id: id, fileName: file.lastPathComponent, title: "Imported video", createdAt: date,
                storageDirectory: storageDirectory))
        }
        videos.sort { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
        try persist()
    }

    /// Copies the two old import locations once. Originals are never moved or
    /// removed, so existing studio sessions and pending drafts remain usable.
    func recoverLegacySources() async {
        guard !isRecovering, !migration.complete else { return }
        isRecovering = true
        defer { isRecovering = false }
        do {
            for folder in legacyDirectories {
                let files: [URL]
                do { files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) }
                catch { if Self.isMissing(error) { continue }; throw error }
                for file in files where Self.extensions.contains(file.pathExtension.lowercased()) {
                    guard try Self.fileIsPresent(file) else { continue }
                    try Task.checkCancellation()
                    guard let key = legacyKey(for: file), !migration.processed.contains(key) else { continue }
                    let id = Self.legacyID(key)
                    if !videos.contains(where: { $0.id == id || $0.legacyKey == key }) {
                        let ext = file.pathExtension.lowercased()
                        let destination = storageDirectory.appendingPathComponent("\(id.uuidString).\(ext)")
                        if !Self.regularFile(destination) {
                            try await Task.detached(priority: .utility) {
                                let pending = destination.deletingLastPathComponent().appendingPathComponent(".\(id.uuidString).recovering")
                                defer { try? FileManager.default.removeItem(at: pending) }
                                try FileManager.default.copyItem(at: file, to: pending)
                                try FileManager.default.moveItem(at: pending, to: destination)
                            }.value
                        }
                        _ = try add(url: file, title: "Imported video", importID: id)
                    }
                    migration.processed.insert(key)
                    try persistMigration()
                    await Task.yield()
                }
            }
            migration.complete = true
            try persistMigration()
        } catch is CancellationError { }
        catch { errorMessage = "Some older imports couldn’t be recovered yet. Their original files have been kept." }
    }

    private func persist() throws { try write(JSONEncoder().encode(videos), to: indexURL) }
    private func persistMigration() throws { try write(JSONEncoder().encode(migration), to: migrationURL) }
    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
    private func legacyKey(for url: URL) -> String? {
        guard legacyDirectories.contains(where: { $0.standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL }) else { return nil }
        return "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
    }
    private nonisolated static let extensions: Set<String> = ["mp4", "mov", "m4v"]
    private nonisolated static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && URL(fileURLWithPath: name).lastPathComponent == name && !name.contains("\\")
    }
    private nonisolated static func regularFile(_ url: URL) -> Bool {
        (try? fileIsPresent(url)) == true
    }
    private nonisolated static func fileIsPresent(_ url: URL) throws -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            return values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? 0) > 0
        } catch { if isMissing(error) { return false }; throw error }
    }
    private nonisolated static func isMissing(_ error: Error) -> Bool {
        let value = error as NSError
        return (value.domain == NSCocoaErrorDomain && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(value.code))
            || (value.domain == NSPOSIXErrorDomain && value.code == 2)
    }
    private nonisolated static func publicSource(_ url: URL?) -> URL? {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased(),
              ["instagram.com", "youtube.com", "youtu.be", "tiktok.com", "x.com", "twitter.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return url
    }
    private nonisolated static func legacyID(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }
    private enum ImportError: LocalizedError {
        case unavailable
        var errorDescription: String? { "This video couldn’t be opened. Its original file has been kept." }
    }
}
