import AVFoundation
import Foundation
import Observation
import UIKit

struct ReadyVideoImport: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let title: String
}

/// The import belongs to the app, not HomeView. Its journal and system-owned
/// transfers let it survive tab changes, suspension and ordinary OS relaunches.
@MainActor @Observable
final class VideoImportCoordinator {
    static let shared = VideoImportCoordinator()
    private struct Job: Codable {
        let id: UUID
        let raw: String
        let address: String
        var stage: String = "resolving"
        var media: ResolvedMedia?
        var transfers: [MediaTransfer] = []
        /// The asset set chosen from a direct manifest; nil in journals written by older builds.
        var plan: ImportPlan?
        var importedFile: URL?
        var title: String?
        var error: String?
        var usedDirect: Bool = false
        var loadingPhase: VideoLinkLoadingPhase { .resuming(hasResolvedMedia: media != nil, stage: stage) }
    }
    private(set) var phase = VideoLinkLoadingPhase.idle
    private(set) var progress: Double?
    private(set) var ready: ReadyVideoImport?
    private(set) var errorMessage: String?
    private(set) var needsNetworkSettings = false
    private(set) var lastDeliveryKind: String?
    private(set) var lastImportReport: ImportReport?
    /// While a job converts on the phone, progress is the conversion fraction, not download bytes.
    private var convertingJob: UUID?
    private var job: Job?
    private var task: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var automaticJobID: UUID?
    private var restorationTask: Task<Void, Never>?
    private var restorationGeneration = UUID()
    private var restored = false
    private var restorationBlocked = false
    private var pendingStart: (raw: String, address: String)?
    private var protectionObserver: NSObjectProtocol?
    var shouldAutomaticallyOpen: Bool { ready?.id == automaticJobID && ready != nil }
    /// Leaving the app never cancels "Download & open video": the finished video opens on return.
    func didEnterBackground() {
        if task != nil { backgroundedDuringRun = true }
    }
    /// The most recent finished import, kept after Studio consumes `ready` (DEBUG diagnostics read it).
    private(set) var lastCompletedImport: ReadyVideoImport?
    /// Set when the app leaves during a run; work interrupted by that is retried, not failed.
    private var backgroundedDuringRun = false
    func deferOpeningUntilRequested() { automaticJobID = nil }
    private let journal: URL
    var sourceText: String? { job?.raw }
    var isRunning: Bool { phase != .idle }

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoImport", isDirectory: true)
        journal = directory.appendingPathComponent("pending.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        protectionObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.resumeIfNeeded() } }
    }
    func start(_ raw: String, address: String) {
        guard restored else {
            guard !restorationBlocked else { errorMessage = MediaJournalError.unreadable.localizedDescription; return }
            pendingStart = (raw, address)
            phase = .preparing
            resumeIfNeeded()
            return
        }
        cancel()
        errorMessage = nil; needsNetworkSettings = false; lastDeliveryKind = nil; lastImportReport = nil; lastCompletedImport = nil
        job = Job(id: UUID(), raw: raw.trimmingCharacters(in: .whitespacesAndNewlines), address: address)
        automaticJobID = job?.id
        phase = .preparing
        do { try persist() } catch { fail(error); return }
        resumeIfNeeded()
    }
    func resumeIfNeeded() {
        guard restored else {
            guard restorationTask == nil else { return }
            let generation = restorationGeneration
            restorationTask = Task { await restorePendingJob(generation: generation) }
            return
        }
        guard task == nil, let job, job.stage != "failed", job.stage != "ready",
              UIApplication.shared.applicationState != .background else { return }
        let id = job.id
        phase = job.loadingPhase
        if phase != .downloading { progress = nil }
        backgroundedDuringRun = false
        task = Task { await run(id) }
        progressTask?.cancel()
        progressTask = Task {
            while !Task.isCancelled, self.job?.id == id, self.phase != .idle {
                if self.convertingJob != id {
                    let value = self.phase == .downloading ? await BackgroundMediaDownloads.shared.progress(group: id) : nil
                    if self.job?.id == id, self.convertingJob != id {
                        // Whole percents only: identical values must not invalidate observers.
                        let next = self.phase == .downloading ? value.map { ($0 * 100 + 1e-9).rounded(.down) / 100 } : nil
                        if next != self.progress { self.progress = next }
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
    func consumeReady() {
        guard ready != nil else { return }
        ready = nil; job = nil
        try? FileManager.default.removeItem(at: journal)
    }
    func cancel() {
        let needsReset = !restored
        pendingStart = nil
        restorationGeneration = UUID()
        restorationTask?.cancel(); restorationTask = nil
        let transfers = job?.transfers.map(\.id) ?? []
        if let id = job?.id { OnDeviceConverter.removePartialOutput(jobID: id) }
        job = nil
        task?.cancel(); task = nil
        progressTask?.cancel(); progressTask = nil
        BackgroundMediaDownloads.shared.cancel(transfers)
        BackgroundMediaDownloads.shared.remove(transfers)
        phase = .idle; progress = nil; ready = nil; errorMessage = nil; automaticJobID = nil
        try? FileManager.default.removeItem(at: journal)
        if needsReset {
            restorationBlocked = false
            let generation = restorationGeneration
            restorationTask = Task {
                await BackgroundMediaDownloads.shared.discardPendingTransfersAfterUserCancellation()
                guard self.restorationGeneration == generation, !Task.isCancelled else { return }
                self.restored = true; self.restorationTask = nil
                if let pending = self.pendingStart { self.pendingStart = nil; self.start(pending.raw, address: pending.address) }
            }
        }
    }
    private func restorePendingJob(generation: UUID) async {
        defer { if restorationGeneration == generation { restorationTask = nil } }
        let saved: Job?
        switch MediaImportJournal.read(Job.self, from: journal, protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable) {
        case .deferred:
            phase = job?.loadingPhase ?? .preparing
            return
        case .unreadable:
            restorationBlocked = true; pendingStart = nil
            phase = job?.loadingPhase ?? .preparing; errorMessage = MediaJournalError.unreadable.localizedDescription
            return
        case .missing: saved = nil
        case .loaded(let value): saved = value
        }
        do {
            try await BackgroundMediaDownloads.shared.restoreIfPossible()
            try Task.checkCancellation()
            guard restorationGeneration == generation else { return }
            if saved != nil { try ImportedVideoLibrary.shared.reload() }
            job = saved; ready = nil; errorMessage = nil
            if let stored = saved {
                if let imported = ImportedVideoLibrary.shared.videos.first(where: { $0.id == stored.id }) {
                    // Library commit can precede the final job checkpoint. The
                    // durable import is authoritative even if staging was gone
                    // when the process died between those two writes.
                    var completed = stored
                    completed.stage = "ready"; completed.title = imported.title; completed.importedFile = imported.fileURL
                    completed.usedDirect = stored.usedDirect || stored.media?.delivery?.kind == "direct"
                    completed.media = nil; completed.transfers = []; completed.error = nil
                    job = completed
                    try persist()
                    ready = ReadyVideoImport(id: stored.id, url: imported.fileURL, title: imported.title)
                    // A finished "Download & open video" opens once Create is on screen again.
                    automaticJobID = stored.id; lastCompletedImport = ready
                    lastDeliveryKind = completed.usedDirect ? "direct" : "prepared"; phase = .idle
                } else if stored.stage == "failed" { phase = .idle; errorMessage = stored.error }
                else if stored.stage == "ready" {
                    // The finished import was removed (for example deleted by the user); drop the stale job quietly.
                    job = nil; phase = .idle
                    try? FileManager.default.removeItem(at: journal)
                } else { phase = stored.loadingPhase }
            } else { phase = .idle }
            restored = true; restorationBlocked = false
            // Only a successfully read job and transfer journal may prune OS tasks.
            BackgroundMediaDownloads.shared.retainOnly(job?.transfers.map(\.id) ?? [])
            if let pending = pendingStart { pendingStart = nil; start(pending.raw, address: pending.address) }
            else { resumeIfNeeded() }
        } catch {
            guard restorationGeneration == generation, !Task.isCancelled else { return }
            phase = (job ?? saved)?.loadingPhase ?? .preparing
            if phase != .downloading { progress = nil }
            if case MediaJournalError.protectedDataUnavailable = error { return }
            restorationBlocked = true; pendingStart = nil
            errorMessage = MediaJournalError.unreadable.localizedDescription
        }
    }
    private func persist() throws {
        guard let job else { return }
        try MediaImportJournal.write(job, to: journal)
    }
    private func current(_ id: UUID) throws -> Job {
        try Task.checkCancellation()
        guard let job, job.id == id else { throw CancellationError() }
        return job
    }
    private func run(_ id: UUID) async {
        let lease = VideoImportBackgroundLease()
        defer {
            lease.end()
            if job?.id == id { task = nil; progressTask?.cancel(); progressTask = nil }
        }
        var transient: URL?
        do {
            let file: URL
            var delivered: ResolvedMedia?
            while true {
                var active = try current(id)
                if let saved = active.media, saved.delivery?.kind == "direct", active.transfers.isEmpty,
                   DirectMediaPolicy.expiresSoon(saved) {
                    // A stale direct manifest would fail validation. Ask for a fresh one instead.
                    active.media = nil; active.stage = "resolving"; job = active; try persist()
                }
                if active.media == nil {
                    phase = .preparing; progress = nil
                    let resolved = try await resolveAwake(active.raw, address: active.address)
                    _ = try current(id)
                    active.media = resolved
                    // A primary that already failed is not tried again from a fresh manifest,
                    // unless that manifest's primary is itself the directly playable set.
                    active.plan = active.plan == .fallback &&
                        (resolved.delivery?.fallback != nil || resolved.delivery?.convert == true) ? .fallback : nil
                    job = active; try persist()
                }
                guard let media = active.media else { throw DirectImportError.invalidDelivery }
                if active.plan == nil {
                    active.plan = ImportPlan.choose(media.delivery, capabilities: DeviceVideoCapabilities.current)
                    job = active; try persist()
                }
                let plan = active.plan ?? .primary
                if case .unsupported(let message) = plan { throw ImportFormatError(message: message) }
                do { file = try await materialize(media, plan: plan, jobID: id); delivered = media; break }
                catch {
                    // A background failure is retried on return; it must not discard
                    // finished transfers or spend the one fallback.
                    if retriesOnReturn(error) { throw error }
                    let latest = try current(id)
                    guard media.delivery?.kind == "direct", latest.plan == .primary, media.delivery?.fallback != nil else { throw error }
                    // Switch once to the directly playable set, with fresh transfers.
                    BackgroundMediaDownloads.shared.cancel(latest.transfers.map(\.id))
                    BackgroundMediaDownloads.shared.remove(latest.transfers.map(\.id))
                    var fallback = latest
                    fallback.plan = .fallback; fallback.transfers = []; fallback.stage = "resolving"
                    job = fallback; try persist(); phase = .downloading; progress = nil
                }
            }
            transient = file
            let latest = try current(id)
            guard let resolved = latest.media ?? delivered else { throw DirectImportError.invalidDelivery }
            let imported = try ImportedVideoLibrary.shared.add(url: file, title: resolved.title,
                sourceURL: resolved.sourceUrl, platform: resolved.platform, importID: id, duration: resolved.duration, qualityVersion: resolved.qualityVersion)
            // Library now owns its durable copy. Only disposable staging is removed.
            if file.standardizedFileURL != imported.fileURL.standardizedFileURL { try? FileManager.default.removeItem(at: file) }
            transient = nil
            var completed = latest
            completed.stage = "ready"; completed.importedFile = imported.fileURL; completed.title = imported.title
            completed.usedDirect = latest.media?.delivery?.kind == "direct"
            completed.media = nil; completed.transfers = []; completed.error = nil
            job = completed; try persist()
            BackgroundMediaDownloads.shared.remove(latest.transfers.map(\.id))
            lastDeliveryKind = completed.usedDirect ? "direct" : "prepared"
            ready = ReadyVideoImport(id: id, url: imported.fileURL, title: imported.title)
            lastCompletedImport = ready
            phase = .idle; progress = nil; errorMessage = nil
            // The user chose another video meanwhile: this one simply stays in Recent.
            if automaticJobID != id { consumeReady() }
        } catch {
            let retry = retriesOnReturn(error)
            // A server-prepared download is the transfer's own file; the retry still needs it.
            if let transient, !(retry && job?.id == id && job?.media?.delivery?.kind != "direct") {
                try? FileManager.default.removeItem(at: transient)
            }
            guard job?.id == id else { return }
            if Task.isCancelled { return }
            if retry {
                // Relay lookup and local validation can resume on foreground.
                // System-owned file transfers continue while this task is suspended.
                phase = job?.loadingPhase ?? .preparing
                if phase != .downloading { progress = nil }
                // Runs after this task is cleared; ignored while still in the background.
                Task { @MainActor [weak self] in self?.resumeIfNeeded() }
                return
            }
            fail(error)
        }
    }
    /// Auto-lock must not suspend the link lookup (YouTube relays it through this phone).
    private func resolveAwake(_ raw: String, address: String) async throws -> ResolvedMedia {
        let awake = YouTubeRelayForegroundLease.acquire()
        defer { YouTubeRelayForegroundLease.release(awake) }
        return try await MediaResolver.resolve(raw, address: address)
    }
    /// Failures caused by leaving the app restart on return instead of falling back or failing.
    /// The next run clears backgroundedDuringRun, so a real foreground failure still surfaces.
    private func retriesOnReturn(_ error: Error) -> Bool {
        error is ImportDeferral || UIApplication.shared.applicationState == .background || backgroundedDuringRun
    }
    private func materialize(_ media: ResolvedMedia, plan: ImportPlan, jobID: UUID) async throws -> URL {
        var active = try current(jobID)
        let direct = media.delivery?.kind == "direct"
        let assets: [DirectMediaAsset]
        var expected = media.delivery?.expected
        if direct {
            let primary = try DirectMediaPolicy.validate(media, checkExpiry: active.transfers.isEmpty)
            if plan == .fallback {
                guard let fallback = media.delivery?.fallback else { throw DirectImportError.invalidDelivery }
                assets = fallback.assets; expected = fallback.expected
            } else { assets = primary }
        } else {
            guard let base = URL(string: active.address), let url = media.delivery?.url ?? media.playbackUrl,
                  DirectMediaPolicy.serviceFile(url, base: base) else { throw DirectImportError.invalidDelivery }
            assets = [.init(role: "muxed", url: url, headers: [:])]
        }
        let created = active.transfers.isEmpty
        if created {
            // iOS makes transfers started in the background discretionary, so they
            // could wait for Wi-Fi and power. Schedule them once the app is back.
            if UIApplication.shared.applicationState == .background { throw ImportDeferral.waitingForForeground }
            let base = direct ? nil : URL(string: active.address)
            active.transfers = assets.map { asset in
                MediaTransfer(id: UUID(), group: jobID, url: asset.url, headers: asset.headers,
                    platform: media.platform, serviceBase: base, maxBytes: media.delivery?.maxBytes ?? DirectMediaPolicy.byteLimit)
            }
            active.stage = "downloading"; job = active; try persist()
        }
        guard active.transfers.count == assets.count else { throw DirectImportError.invalidDelivery }
        phase = .downloading
        let downloadStarted = Date()
        try await BackgroundMediaDownloads.shared.start(active.transfers)
        if created, UIApplication.shared.applicationState == .background {
            // The app left while these tasks were being scheduled, so they are
            // discretionary. Drop them and schedule fresh ones in the foreground.
            _ = try current(jobID)
            let ids = active.transfers.map(\.id)
            BackgroundMediaDownloads.shared.cancel(ids); BackgroundMediaDownloads.shared.remove(ids)
            active.transfers = []; active.stage = "resolving"; job = active; try persist()
            throw ImportDeferral.waitingForForeground
        }
        // Both transfers are scheduled first. Observe failures concurrently so a
        // rejected audio URL cannot leave a large video downloading needlessly.
        let files = try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            for (index, transfer) in active.transfers.enumerated() {
                group.addTask { (index, try await BackgroundMediaDownloads.shared.completedFile(transfer.id)) }
            }
            defer { group.cancelAll() }
            var ordered = [URL?](repeating: nil, count: active.transfers.count)
            for try await (index, url) in group { ordered[index] = url }
            return try ordered.map { value in
                guard let value else { throw DirectImportError.interrupted }
                return value
            }
        }
        let downloadSeconds = Date().timeIntervalSince(downloadStarted)
        _ = try current(jobID)
        // A transfer can finish while the app is in the background; keep it awake until the local step ends.
        let preparing = VideoImportBackgroundLease()
        defer { preparing.end() }
        phase = .loading; progress = nil; active.stage = "preparing"; job = active; try persist()
        if direct {
            guard let expected else { throw DirectImportError.invalidDelivery }
            return try await prepareDownloaded(media, plan: plan, assets: assets, expected: expected, files: files,
                                               jobID: jobID, downloadSeconds: downloadSeconds)
        }
        let local = try await StudioVideoPreparer.prepare(files[0])
        // The library commits its own durable copy before transfer cleanup.
        return local.url
    }
    /// Inspects the downloaded codecs: H.264 + AAC-LC is copied as is; anything
    /// else this phone can decode is converted to H.264 + AAC-LC on the device.
    private func prepareDownloaded(_ media: ResolvedMedia, plan: ImportPlan, assets: [DirectMediaAsset],
                                   expected: DirectMediaExpectation, files: [URL], jobID: UUID,
                                   downloadSeconds: Double) async throws -> URL {
        // YouTube's DASH files declare their length twice; fix the header before anything reads them.
        for file in files { try? DirectVideoPreparer.normalizeFragmentedMP4(file) }
        let codecs: OnDeviceConverter.SourceCodecs
        do { codecs = try await OnDeviceConverter.sourceCodecs(assets: assets, files: files) }
        catch is CancellationError { throw CancellationError() }
        catch { throw DirectImportError.incompatible }
        var report = ImportReport(deliveryPlan: plan == .fallback ? "fallback" : "direct",
                                  sourceVideoCodec: ImportReport.videoCodecName(codecs.video),
                                  sourceAudioCodec: ImportReport.audioCodecName(codecs.audio),
                                  downloadSeconds: downloadSeconds, conversionSeconds: 0)
        let file: URL
        if try await DirectVideoPreparer.isDirectlyCompatible(assets: assets, files: files) {
            file = try await DirectVideoPreparer.prepare(media, assets: assets, files: files, expected: expected)
        } else {
            let codec = codecs.video.map(DeviceVideoCapabilities.codec(of:)) ?? .unknown
            let capabilities = DeviceVideoCapabilities.current
            guard capabilities.canDecode(codec) else {
                throw ImportFormatError(message: ImportPlan.unsupportedMessage(codec, capabilities: capabilities))
            }
            _ = try current(jobID)
            if plan != .fallback { report.deliveryPlan = "converted" }
            convertingJob = jobID; progress = 0
            defer { if convertingJob == jobID { convertingJob = nil } }
            let started = Date()
            file = try await OnDeviceConverter.convert(assets: assets, files: files, expected: expected, jobID: jobID) { [weak self] fraction in
                Task { @MainActor in self?.showConversionProgress(fraction, jobID: jobID) }
            }
            report.conversionSeconds = Date().timeIntervalSince(started)
        }
        lastImportReport = report
        return file
    }
    private func showConversionProgress(_ fraction: Double, jobID: UUID) {
        guard convertingJob == jobID, job?.id == jobID else { return }
        // Whole percents only, like download progress.
        let next = (min(1, max(0, fraction)) * 100 + 1e-9).rounded(.down) / 100
        if next != progress { progress = next }
    }
    private func fail(_ error: Error) {
        phase = .idle; progress = nil
        errorMessage = error.localizedDescription
        needsNetworkSettings = (error as? MediaConnectionFailure)?.offersSettings == true
        let transfers = job?.transfers.map(\.id) ?? []
        BackgroundMediaDownloads.shared.cancel(transfers); BackgroundMediaDownloads.shared.remove(transfers)
        if let id = job?.id { OnDeviceConverter.removePartialOutput(jobID: id) }
        job?.stage = "failed"; job?.error = errorMessage; job?.media = nil; job?.transfers = []
        try? persist()
    }
    #if DEBUG
    /// Explicit device probe; it uses the production importer and durable library.
    func prepareForDiagnostics(raw: String, address: String) async throws -> URL {
        start(raw, address: address)
        while isRunning { try await Task.sleep(for: .milliseconds(200)) }
        // Studio may already have opened (and consumed) the finished import.
        guard let finished = ready ?? lastCompletedImport else { throw ResolverError(errorMessage ?? "The import did not finish.") }
        return finished.url
    }
    #endif
}

private enum ImportDeferral: Error { case waitingForForeground }

/// How the last import was delivered, for the DEBUG connection diagnostics.
struct ImportReport: Sendable {
    /// 'direct' | 'converted' | 'fallback'
    var deliveryPlan: String
    var sourceVideoCodec: String
    var sourceAudioCodec: String
    var downloadSeconds: Double
    var conversionSeconds: Double

    static func videoCodecName(_ subtype: FourCharCode?) -> String {
        guard let subtype else { return "none" }
        let codec = DeviceVideoCapabilities.codec(of: subtype)
        return codec == .unknown ? fourCharacters(subtype) : codec.rawValue
    }
    static func audioCodecName(_ subtype: FourCharCode?) -> String {
        guard let subtype else { return "none" }
        switch subtype {
        case kAudioFormatMPEG4AAC: return "aac-lc"
        case kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return "he-aac"
        default: return fourCharacters(subtype)
        }
    }
    private static func fourCharacters(_ value: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? String(value)
    }
}

@MainActor
private final class VideoImportBackgroundLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    init() {
        // UIKit calls this on the main thread and expects the task to end before it returns.
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Finish video import") { [weak self] in
            MainActor.assumeIsolated { () -> Void in self?.end() }
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        let current = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(current)
    }
}
