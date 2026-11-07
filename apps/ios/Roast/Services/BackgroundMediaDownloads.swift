import Foundation
import UIKit

struct MediaTransfer: Codable, Sendable {
    let id: UUID
    let group: UUID
    let url: URL
    let headers: [String: String]
    let platform: String
    let serviceBase: URL?
    let maxBytes: Int64
}

/// One stable background session is reattached on launch. The system owns the
/// network transfers; a view disappearing does not cancel them. Signed URLs
/// live only in this private, backup-excluded journal until completion/cleanup.
final class BackgroundMediaDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundMediaDownloads()
    static let identifier = "com.furqanali.roast.source-downloads.v1"
    /// YouTube throttles whole-file requests; byte ranges of this size download at full speed.
    static let pieceSize: Int64 = 10 * 1024 * 1024
    /// A running download that receives no bytes for this long is cancelled and requested again.
    static let stallWindow: TimeInterval = 30
    static let stallCheckInterval: TimeInterval = 5
    /// Attempts per piece or whole-file transfer, the first one included.
    static let maxAttempts = 5
    enum StallDecision: Equatable { case keep, retry, fail }
    static func stallDecision(lastBytesAt: Date, now: Date, attempts: Int) -> StallDecision {
        guard now.timeIntervalSince(lastBytesAt) >= stallWindow else { return .keep }
        return attempts >= maxAttempts ? .fail : .retry
    }
    /// Inclusive byte ranges covering `total`; the last piece is shorter.
    static func pieceRanges(total: Int64, pieceSize: Int64 = pieceSize) -> [ClosedRange<Int64>] {
        guard total > 0, pieceSize > 0 else { return [] }
        let count = (total + pieceSize - 1) / pieceSize
        return (0..<count).map { index in (index * pieceSize)...(min((index + 1) * pieceSize, total) - 1) }
    }
    private struct Piece: Codable {
        let index: Int
        let start: Int64
        let end: Int64
        var state: String = "running"
        var bytes: Int64 = 0
        var attempts: Int = 1
        var length: Int64 { end - start + 1 }
    }
    private struct Entry: Codable {
        var transfer: MediaTransfer
        var state: String
        var bytes: Int64 = 0
        var expected: Int64 = 0
        var error: String?
        /// Byte-range pieces (YouTube); nil for whole-file transfers and journals written by older builds.
        var pieces: [Piece]? = nil
        /// Whole-file attempts; nil in journals written by older builds.
        var attempts: Int? = nil
    }
    private let queue = DispatchQueue(label: "app.recordpov.background-downloads")
    private let folder: URL
    private var entries: [String: Entry] = [:]
    private var waiters: [UUID: [CheckedContinuation<URL, Error>]] = [:]
    private var backgroundCompletion: (() -> Void)?
    private var journalLoaded = false
    private var didFinishBackgroundEvents = false
    private var protectionObserver: NSObjectProtocol?
    private var activityObservers: [NSObjectProtocol] = []
    /// When each running task (by task description) last received bytes. Memory only.
    private var lastBytes: [String: Date] = [:]
    /// When any task last received bytes. The session runs only a few tasks at once, so a
    /// piece that has no bytes yet is queued, not stalled, while other tasks still receive data.
    private var lastAnyBytes: Date?
    /// Tasks cancelled to be requested again; their callbacks are ignored.
    private var retiredTasks: Set<Int> = []
    private var appActive = false
    private var stallTimer: DispatchSourceTimer?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 4 * 60 * 60
        let operations = OperationQueue()
        operations.name = "app.recordpov.background-download-delegate"
        operations.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: operations)
    }()
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()
    private override init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackgroundVideoDownloads", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var excluded = folder
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try? excluded.setResourceValues(resources)
        protectionObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { try? await self?.restoreIfPossible() }
        }
        // Stalled tasks are re-created only while the app is active: one created in
        // the background would be discretionary. Becoming active restarts the window.
        activityObservers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.queue.async { self?.setActive(true) }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.queue.async { self?.setActive(false) }
            }
        ]
    }
    func restoreIfPossible() async throws {
        let available = await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.journalLoaded { continuation.resume(); return }
                switch MediaImportJournal.read([String: Entry].self, from: self.journal, protectedDataAvailable: available) {
                case .deferred:
                    continuation.resume(throwing: MediaJournalError.protectedDataUnavailable); return
                case .unreadable:
                    continuation.resume(throwing: MediaJournalError.unreadable); return
                case .missing: self.entries = [:]
                case .loaded(let stored): self.entries = stored
                }
                self.journalLoaded = true
                let restoring = Set(self.entries.keys)
                self.session.getAllTasks { tasks in
                    self.queue.async {
                        let active = Set(tasks.compactMap(\.taskDescription))
                        for task in tasks where self.entries[Self.parse(task.taskDescription)?.key ?? ""] == nil { task.cancel() }
                        for key in restoring {
                            guard let entry = self.entries[key], let id = UUID(uuidString: key) else { continue }
                            if entry.pieces != nil { self.reconcilePieces(id, active: active); continue }
                            guard !active.contains(key),
                                  entry.state == "running" || (entry.state == "failed" && entry.error == "storage") else { continue }
                            // A process can die after the callback moved the file
                            // but before its terminal journal commit. This is only
                            // a completed transfer; native validation still runs.
                            if let size = self.recoverableFileSize(id) { self.completeRecovered(id, size: size) }
                            else { self.fail(id, reason: "interrupted") }
                        }
                        try? self.persist()
                    }
                }
                continuation.resume()
            }
        }
    }
    /// Recovers part files whose tasks finished while the app was gone; a running
    /// piece whose task no longer exists and left no complete part fails the transfer.
    private func reconcilePieces(_ id: UUID, active: Set<String>) {
        let key = id.uuidString
        guard let entry = entries[key], let pieces = entry.pieces,
              entry.state == "running" || (entry.state == "failed" && entry.error == "storage") else { return }
        // The process can die after the parts were joined but before the terminal journal commit.
        if let size = recoverableFileSize(id), size == entry.expected { completeRecovered(id, size: size); return }
        guard entry.state == "running" else { return }
        for piece in pieces where piece.state == "running" && !active.contains(Self.describe(key, piece: piece.index)) {
            guard let size = partSize(id, piece.index), size == piece.length else { fail(id, reason: "interrupted"); return }
            entries[key]?.pieces?[piece.index].state = "complete"
            entries[key]?.pieces?[piece.index].bytes = size
        }
        sumPieceBytes(key)
        if entries[key]?.pieces?.allSatisfy({ $0.state == "complete" }) == true { assemble(id) }
    }
    /// A piece transfer's bytes are the sum of its pieces.
    private func sumPieceBytes(_ key: String) {
        let total = entries[key]?.pieces?.reduce(Int64(0)) { $0 + $1.bytes } ?? 0
        entries[key]?.bytes = total
    }
    private func completeRecovered(_ id: UUID, size: Int64) {
        let key = id.uuidString
        let previous = entries[key]
        entries[key]?.state = "complete"
        entries[key]?.error = nil
        entries[key]?.bytes = size
        entries[key]?.expected = size
        do {
            try persist()
            removeParts(id, count: previous?.pieces?.count ?? 0)
            let waiting = waiters.removeValue(forKey: id) ?? []
            for waiter in waiting { waiter.resume(returning: file(id)) }
        }
        catch { entries[key] = previous; fail(id, reason: "storage", preserveFile: true) }
    }
    private var journal: URL { folder.appendingPathComponent("transfers.json") }
    private func file(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString).appendingPathExtension("mp4") }
    private func partFile(_ id: UUID, _ index: Int) -> URL { folder.appendingPathComponent("\(id.uuidString).part\(index)") }
    private func removeParts(_ id: UUID, count: Int) {
        for index in 0..<count { try? FileManager.default.removeItem(at: partFile(id, index)) }
    }
    private func removeFiles(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
        removeParts(id, count: entries[id.uuidString]?.pieces?.count ?? 0)
    }
    private func persist() throws {
        guard journalLoaded else { throw MediaJournalError.unreadable }
        try MediaImportJournal.write(entries, to: journal)
    }
    private func recoverableFileSize(_ id: UUID) -> Int64? {
        guard let entry = entries[id.uuidString], let size = regularFileSize(file(id)), size <= entry.transfer.maxBytes else { return nil }
        return size
    }
    private func partSize(_ id: UUID, _ index: Int) -> Int64? { regularFileSize(partFile(id, index)) }
    private func regularFileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0 else { return nil }
        return Int64(size)
    }
    /// A piece task is described as "<transfer id>#<piece index>"; a whole-file task as the transfer id.
    private static func describe(_ key: String, piece: Int?) -> String { piece.map { "\(key)#\($0)" } ?? key }
    private static func parse(_ description: String?) -> (key: String, piece: Int?)? {
        guard let parts = description?.split(separator: "#", omittingEmptySubsequences: false),
              (1...2).contains(parts.count), UUID(uuidString: String(parts[0])) != nil else { return nil }
        guard parts.count == 2 else { return (String(parts[0]), nil) }
        guard let index = Int(parts[1]), index >= 0 else { return nil }
        return (String(parts[0]), index)
    }
    private static func downloadsInPieces(_ transfer: MediaTransfer) -> Bool {
        transfer.serviceBase == nil && transfer.platform == "youtube"
    }
    /// googlevideo URLs carry the file's total size as `clen`.
    static func declaredLength(_ url: URL) -> Int64? {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "clen" })?.value,
              let length = Int64(value), length > 0 else { return nil }
        return length
    }
    /// The total from "bytes <start>-<end>/<total>".
    static func contentRangeTotal(_ header: String?) -> Int64? {
        guard let header, header.hasPrefix("bytes "), let slash = header.lastIndex(of: "/"),
              let total = Int64(header[header.index(after: slash)...]), total > 0 else { return nil }
        return total
    }
    /// One foreground `bytes=0-0` request, for a YouTube URL without `clen`.
    private static func probeTotal(_ transfer: MediaTransfer) async throws -> Int64 {
        var request = try requestFor(transfer)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let response: URLResponse
        do { (_, response) = try await probeSession.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw DirectImportError.interrupted }
        guard let http = response as? HTTPURLResponse, http.statusCode == 206, let final = http.url,
              DirectMediaPolicy.allows(final, platform: transfer.platform),
              let total = contentRangeTotal(http.value(forHTTPHeaderField: "Content-Range")) else { throw DirectImportError.interrupted }
        return total
    }
    private static func requestFor(_ transfer: MediaTransfer, range: ClosedRange<Int64>? = nil) throws -> URLRequest {
        var request: URLRequest
        if let base = transfer.serviceBase {
            guard transfer.headers.isEmpty, DirectMediaPolicy.serviceFile(transfer.url, base: base) else { throw DirectImportError.invalidDelivery }
            request = URLRequest(url: transfer.url)
            request.httpShouldHandleCookies = false
            request.timeoutInterval = 60
        } else {
            request = try DirectMediaPolicy.request(.init(role: "muxed", url: transfer.url, headers: transfer.headers), platform: transfer.platform)
        }
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        return request
    }
    func attachBackgroundEvents(_ completion: @escaping () -> Void) {
        queue.async {
            self.backgroundCompletion = completion
            self.finishBackgroundEventsIfPossible()
        }
        Task { try? await restoreIfPossible() }
    }
    func start(_ transfers: [MediaTransfer]) async throws {
        try await restoreIfPossible()
        try Task.checkCancellation()
        let active = await MainActor.run { UIApplication.shared.applicationState == .active }
        let known = await withCheckedContinuation { (continuation: CheckedContinuation<Set<String>, Never>) in
            queue.async { continuation.resume(returning: Set(self.entries.keys)) }
        }
        // YouTube files download in pieces; the size comes from the URL, or one ranged probe.
        var totals: [UUID: Int64] = [:]
        for transfer in transfers where !known.contains(transfer.id.uuidString) && Self.downloadsInPieces(transfer) {
            if let length = Self.declaredLength(transfer.url) { totals[transfer.id] = length }
            else { totals[transfer.id] = try await Self.probeTotal(transfer) }
        }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if active { self.setActive(true, restartWindow: false) }
                do {
                    for transfer in transfers {
                        let key = transfer.id.uuidString
                        if self.entries[key] != nil { continue }
                        let request = try Self.requestFor(transfer)
                        guard transfer.maxBytes > 0, transfer.maxBytes <= DirectMediaPolicy.byteLimit else { throw DirectImportError.invalidDelivery }
                        let now = Date()
                        if let total = totals[transfer.id] {
                            guard total <= transfer.maxBytes else { throw DirectImportError.tooLarge }
                            // Every piece is scheduled now, in the foreground, so none is discretionary.
                            let pieces = Self.pieceRanges(total: total).enumerated().map {
                                Piece(index: $0.offset, start: $0.element.lowerBound, end: $0.element.upperBound)
                            }
                            let tasks = try pieces.map { piece -> URLSessionDownloadTask in
                                let task = self.session.downloadTask(with: try Self.requestFor(transfer, range: piece.start...piece.end))
                                task.taskDescription = Self.describe(key, piece: piece.index)
                                return task
                            }
                            self.entries[key] = Entry(transfer: transfer, state: "running", expected: total, pieces: pieces)
                            do { try self.persist() }
                            catch {
                                self.entries.removeValue(forKey: key)
                                for task in tasks { task.cancel() }
                                throw error
                            }
                            for task in tasks {
                                if let description = task.taskDescription { self.lastBytes[description] = now }
                                task.resume()
                            }
                        } else {
                            let task = self.session.downloadTask(with: request)
                            task.taskDescription = key
                            self.entries[key] = Entry(transfer: transfer, state: "running", attempts: 1)
                            do { try self.persist() }
                            catch {
                                self.entries.removeValue(forKey: key)
                                task.cancel()
                                throw error
                            }
                            self.lastBytes[key] = now
                            task.resume()
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func completedFile(_ transfer: UUID) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard let entry = self.entries[transfer.uuidString] else {
                        continuation.resume(throwing: DirectImportError.interrupted); return
                    }
                    if entry.state == "complete" {
                        if FileManager.default.fileExists(atPath: self.file(transfer).path) { continuation.resume(returning: self.file(transfer)) }
                        else { continuation.resume(throwing: DirectImportError.interrupted) }
                    } else if entry.state == "failed" {
                        continuation.resume(throwing: entry.error == "tooLarge" ? DirectImportError.tooLarge : DirectImportError.interrupted)
                    } else { self.waiters[transfer, default: []].append(continuation) }
                }
            }
        } onCancel: { self.cancel([transfer]) }
    }
    func progress(group: UUID) async -> Double? {
        await withCheckedContinuation { continuation in
            queue.async {
                let members = self.entries.values.filter { $0.transfer.group == group }
                let expected = members.reduce(Int64(0)) { $0 + $1.expected }
                // A piece transfer's bytes are the sum of its pieces, against its total size.
                let bytes = members.reduce(Int64(0)) { $0 + ($1.pieces?.reduce(Int64(0)) { $0 + $1.bytes } ?? $1.bytes) }
                continuation.resume(returning: !members.isEmpty && members.allSatisfy { $0.expected > 0 } && expected > 0 ? min(1, Double(bytes) / Double(expected)) : nil)
            }
        }
    }
    func retainOnly(_ ids: [UUID]) {
        queue.async {
            guard self.journalLoaded else { return }
            let retained = Set(ids.map(\.uuidString))
            let stale = self.entries.keys.filter { !retained.contains($0) }
            let staleKeys = Set(stale)
            self.session.getAllTasks { tasks in
                for task in tasks where staleKeys.contains(Self.parse(task.taskDescription)?.key ?? "") { task.cancel() }
            }
            for key in stale {
                if let id = UUID(uuidString: key) { self.removeFiles(id) }
                self.entries.removeValue(forKey: key)
            }
            try? self.persist()
        }
    }
    func cancel(_ ids: [UUID]) {
        queue.async {
            guard self.journalLoaded else { return }
            let keys = Set(ids.map(\.uuidString))
            self.session.getAllTasks { tasks in for task in tasks where keys.contains(Self.parse(task.taskDescription)?.key ?? "") { task.cancel() } }
            for id in ids { self.fail(id, reason: "cancelled") }
        }
    }
    func remove(_ ids: [UUID]) {
        queue.async {
            guard self.journalLoaded else { return }
            for id in ids {
                self.removeFiles(id)
                self.entries.removeValue(forKey: id.uuidString)
            }
            try? self.persist()
        }
    }
    private func fail(_ id: UUID, reason: String, preserveFile: Bool = false) {
        guard journalLoaded, let entry = entries[id.uuidString], entry.state != "complete" else { return }
        // The other pieces of a failed piece transfer are useless; stop them.
        if entry.pieces != nil, entry.state == "running" {
            let key = id.uuidString
            session.getAllTasks { tasks in for task in tasks where Self.parse(task.taskDescription)?.key == key { task.cancel() } }
        }
        entries[id.uuidString]?.state = "failed"
        entries[id.uuidString]?.error = reason
        if !preserveFile { removeFiles(id) }
        try? persist()
        let waiting = waiters.removeValue(forKey: id) ?? []
        for waiter in waiting {
            waiter.resume(throwing: reason == "cancelled" ? CancellationError() : (reason == "tooLarge" ? DirectImportError.tooLarge : DirectImportError.interrupted))
        }
    }
    // MARK: Stall retry

    private func setActive(_ active: Bool, restartWindow: Bool = true) {
        appActive = active
        guard active else { stallTimer?.cancel(); stallTimer = nil; return }
        // The 30 s window starts over: a task gets its first mark at the next check.
        if restartWindow { lastBytes = [:]; lastAnyBytes = nil }
        guard stallTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.stallCheckInterval, repeating: Self.stallCheckInterval)
        timer.setEventHandler { [weak self] in self?.checkForStalls() }
        timer.resume()
        stallTimer = timer
    }
    private func checkForStalls() {
        guard appActive, journalLoaded, entries.values.contains(where: { $0.state == "running" }) else { return }
        session.getAllTasks { tasks in
            // Never re-create a task while the app is in the background.
            DispatchQueue.main.async {
                guard UIApplication.shared.applicationState == .active else { return }
                self.queue.async { self.retryStalled(tasks) }
            }
        }
    }
    private func retryStalled(_ tasks: [URLSessionTask]) {
        guard appActive, journalLoaded else { return }
        let now = Date()
        var live: [String: URLSessionTask] = [:]
        for task in tasks where !retiredTasks.contains(task.taskIdentifier) && task.state == .running {
            if let description = task.taskDescription { live[description] = task }
        }
        var changed = false
        for key in Array(entries.keys) {
            guard let entry = entries[key], entry.state == "running", let id = UUID(uuidString: key) else { continue }
            let parts: [(piece: Piece?, attempts: Int)] = entry.pieces.map { pieces in
                pieces.filter { $0.state == "running" }.map { ($0, $0.attempts) }
            } ?? [(nil, entry.attempts ?? 1)]
            for part in parts {
                let description = Self.describe(key, piece: part.piece?.index)
                var last = lastBytes[description] ?? now
                lastBytes[description] = last
                let started = part.piece.map { $0.bytes > 0 } ?? (entry.bytes > 0)
                if !started, let any = lastAnyBytes, any > last { last = any }
                let decision = Self.stallDecision(lastBytesAt: last, now: now, attempts: part.attempts)
                if decision == .keep { continue }
                let old = live[description]
                if let old { retiredTasks.insert(old.taskIdentifier); old.cancel() }
                guard decision == .retry,
                      let request = try? Self.requestFor(entry.transfer, range: part.piece.map { $0.start...$0.end }) else {
                    // Out of attempts: the coordinator's fallback or error path takes over.
                    fail(id, reason: "network"); break
                }
                // The same request again: a piece keeps its range, a whole file restarts from zero.
                let task = session.downloadTask(with: request)
                task.taskDescription = description
                if let piece = part.piece {
                    entries[key]?.pieces?[piece.index].attempts = part.attempts + 1
                    entries[key]?.pieces?[piece.index].bytes = 0
                    sumPieceBytes(key)
                } else {
                    entries[key]?.attempts = part.attempts + 1
                    entries[key]?.bytes = 0
                }
                lastBytes[description] = now
                task.resume()
                changed = true
            }
        }
        if changed { try? persist() }
    }
    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let parsed = Self.parse(downloadTask.taskDescription), let id = UUID(uuidString: parsed.key) else { downloadTask.cancel(); return }
        let key = parsed.key
        queue.async {
            if self.retiredTasks.contains(downloadTask.taskIdentifier) { return }
            guard let entry = self.entries[key] else { downloadTask.cancel(); return }
            let now = Date()
            self.lastBytes[Self.describe(key, piece: parsed.piece)] = now
            self.lastAnyBytes = now
            if let index = parsed.piece {
                guard let pieces = entry.pieces, pieces.indices.contains(index) else { downloadTask.cancel(); return }
                // A response larger than the requested range is not that piece.
                if totalBytesWritten > pieces[index].length || totalBytesExpectedToWrite > pieces[index].length {
                    downloadTask.cancel(); self.fail(id, reason: "response"); return
                }
                self.entries[key]?.pieces?[index].bytes = totalBytesWritten
                self.sumPieceBytes(key)
            } else {
                self.entries[key]?.bytes = totalBytesWritten
                self.entries[key]?.expected = totalBytesExpectedToWrite
            }
            let total = self.entries.values.filter { $0.transfer.group == entry.transfer.group }.reduce(Int64(0)) { $0 + $1.bytes }
            if total > entry.transfer.maxBytes || (parsed.piece == nil && totalBytesExpectedToWrite > entry.transfer.maxBytes) {
                downloadTask.cancel(); self.fail(id, reason: "tooLarge")
            }
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The OS deletes location after this callback returns. Move synchronously.
        guard let parsed = Self.parse(downloadTask.taskDescription), let id = UUID(uuidString: parsed.key) else { return }
        let key = parsed.key
        queue.sync {
            if retiredTasks.contains(downloadTask.taskIdentifier) { return }
            if let index = parsed.piece { finishPiece(id, index: index, task: downloadTask, location: location); return }
            guard let entry = entries[key], entry.state == "running", let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode), let final = response.url else { fail(id, reason: "response"); return }
            let valid = entry.transfer.serviceBase.map { DirectMediaPolicy.serviceFile(final, base: $0) }
                ?? DirectMediaPolicy.allows(final, platform: entry.transfer.platform)
            guard valid else { fail(id, reason: "destination"); return }
            do {
                let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
                let otherBytes = entries.values.filter { $0.transfer.group == entry.transfer.group && $0.transfer.id != id }.reduce(Int64(0)) { $0 + $1.bytes }
                guard size > 0, size + otherBytes <= entry.transfer.maxBytes else { fail(id, reason: "tooLarge"); return }
                let target = file(id)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: location, to: target)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
                entries[key]?.state = "complete"
                entries[key]?.bytes = size
                entries[key]?.expected = size
                // The coordinator removes the private transfer descriptor after committing the import.
                try persist()
                let waiting = waiters.removeValue(forKey: id) ?? []
                for waiter in waiting { waiter.resume(returning: target) }
            } catch {
                entries[key]?.state = "running"
                fail(id, reason: "storage", preserveFile: true)
            }
        }
    }
    /// A piece must be exactly its range (206 with a matching Content-Range) from an allowed host.
    private func finishPiece(_ id: UUID, index: Int, task: URLSessionDownloadTask, location: URL) {
        let key = id.uuidString
        guard let entry = entries[key], entry.state == "running", let pieces = entry.pieces,
              pieces.indices.contains(index), pieces[index].state == "running" else { return }
        let piece = pieces[index]
        guard let response = task.response as? HTTPURLResponse, response.statusCode == 206,
              response.value(forHTTPHeaderField: "Content-Range") == "bytes \(piece.start)-\(piece.end)/\(entry.expected)",
              let final = response.url else { fail(id, reason: "response"); return }
        guard DirectMediaPolicy.allows(final, platform: entry.transfer.platform) else { fail(id, reason: "destination"); return }
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size == piece.length else { fail(id, reason: "response"); return }
            let target = partFile(id, index)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            entries[key]?.pieces?[index].state = "complete"
            entries[key]?.pieces?[index].bytes = size
            sumPieceBytes(key)
            if entries[key]?.pieces?.allSatisfy({ $0.state == "complete" }) == true { assemble(id) }
            else { try persist() }
        } catch { fail(id, reason: "storage") }
    }
    /// Joins the parts in order into the transfer's final file with a streaming copy.
    private func assemble(_ id: UUID) {
        let key = id.uuidString
        guard let entry = entries[key], let pieces = entry.pieces else { return }
        let target = file(id)
        do {
            try? FileManager.default.removeItem(at: target)
            guard FileManager.default.createFile(atPath: target.path, contents: nil,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw CocoaError(.fileWriteUnknown) }
            let output = try FileHandle(forWritingTo: target)
            do {
                for piece in pieces.sorted(by: { $0.index < $1.index }) {
                    let input = try FileHandle(forReadingFrom: partFile(id, piece.index))
                    defer { try? input.close() }
                    while try autoreleasepool(invoking: {
                        guard let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty else { return false }
                        try output.write(contentsOf: chunk)
                        return true
                    }) {}
                }
                try output.close()
            } catch { try? output.close(); throw error }
            let size = regularFileSize(target) ?? 0
            guard size == entry.expected, size <= entry.transfer.maxBytes else {
                fail(id, reason: size > entry.transfer.maxBytes ? "tooLarge" : "response"); return
            }
            removeParts(id, count: pieces.count)
            entries[key]?.state = "complete"
            entries[key]?.bytes = size
            entries[key]?.expected = size
            try persist()
            let waiting = waiters.removeValue(forKey: id) ?? []
            for waiter in waiting { waiter.resume(returning: target) }
        } catch {
            entries[key]?.state = "running"
            fail(id, reason: "storage", preserveFile: true)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let parsed = Self.parse(task.taskDescription), let id = UUID(uuidString: parsed.key) else { return }
        let key = parsed.key
        queue.async {
            // Cancelled to be requested again: not a failure, and no waiter is resumed.
            if self.retiredTasks.remove(task.taskIdentifier) != nil { return }
            if let index = parsed.piece {
                guard let entry = self.entries[key], entry.state == "running" else { return }
                let finished = entry.pieces.map { $0.indices.contains(index) && $0[index].state == "complete" } ?? false
                if error != nil || !finished { self.fail(id, reason: "network") }
                return
            }
            if error != nil || self.entries[key]?.state == "running" { self.fail(id, reason: "network") }
        }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        queue.async {
            self.didFinishBackgroundEvents = true
            self.finishBackgroundEventsIfPossible()
        }
    }
    private func finishBackgroundEventsIfPossible() {
        guard didFinishBackgroundEvents, let completion = backgroundCompletion else { return }
        didFinishBackgroundEvents = false; backgroundCompletion = nil
        DispatchQueue.main.async { completion() }
    }
    /// Only an explicit user Cancel may discard an unreadable prior journal.
    func discardPendingTransfersAfterUserCancellation() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.journalLoaded = true
                for continuations in self.waiters.values { for waiter in continuations { waiter.resume(throwing: CancellationError()) } }
                self.waiters = [:]; self.entries = [:]
                self.session.getAllTasks { tasks in for task in tasks { task.cancel() } }
                if let files = try? FileManager.default.contentsOfDirectory(at: self.folder, includingPropertiesForKeys: nil) {
                    for file in files where file.lastPathComponent == "transfers.json" || UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
                        try? FileManager.default.removeItem(at: file)
                    }
                }
                try? self.persist()
                continuation.resume()
            }
        }
    }
}

final class RecordPOVAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundMediaDownloads.identifier else { completionHandler(); return }
        BackgroundMediaDownloads.shared.attachBackgroundEvents(completionHandler)
    }
}
