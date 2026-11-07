import AVFoundation
import Foundation
import Speech

enum CaptionError: LocalizedError {
    case permission, unavailable, noSpeech, languageDownload, recognition
    var errorDescription: String? {
        switch self {
        case .permission: "Allow Speech Recognition in Settings to generate captions. Your draft is safe."
        case .unavailable: "On-device captions aren’t available for this language on this device. Try another language."
        case .noSpeech: "No speech was found in your microphone recording. You can keep editing."
        case .languageDownload: "The language download couldn’t finish. Check your connection and try again. Your draft is safe."
        case .recognition: "Your voice couldn’t be transcribed. Your draft and existing captions are still safe."
        }
    }
}

enum CaptionGrouping {
    static func cues(from words: [CaptionWord]) -> [TakeCaption] {
        var result: [TakeCaption] = []
        var group: [CaptionWord] = []
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            result.append(TakeCaption(start: first.start, end: max(first.start + 0.08, last.end),
                                      text: group.map(\.text).joined(separator: " "), words: group))
            group.removeAll(keepingCapacity: true)
        }
        for word in words.sorted(by: { $0.start < $1.start }) where !word.text.isEmpty {
            if let first = group.first, let last = group.last,
               group.count >= 6 || word.end - first.start > 2.5 || word.start - last.end > 0.7 { flush() }
            group.append(word)
            if word.text.last.map({ ".!?。！？".contains($0) }) == true { flush() }
        }
        flush()
        return result
    }
}

@MainActor
enum MicrophoneCaptioner {
    typealias ProgressHandler = @MainActor (_ fraction: Double?, _ message: String) -> Void

    /// This entry point accepts only the explicit microphone stem, never the
    /// composed preview, original clip, or music. All inference stays on-device.
    static func generate(microphoneURL: URL, locale: Locale,
                         progress: @escaping ProgressHandler) async throws -> [TakeCaption] {
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else { throw CaptionError.permission }
        try Task.checkCancellation()
        progress(nil, "Preparing your voice…")
        let prepared = try await prepareMicrophoneAudio(from: microphoneURL)
        defer { try? FileManager.default.removeItem(at: prepared.url) }
        let words: [CaptionWord]
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            words = try await modern(audioURL: prepared.url, offset: prepared.offset,
                                     locale: supported, progress: progress)
        } else {
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
                throw CaptionError.unavailable
            }
            progress(nil, "Captioning your voice on this device…")
            words = try await legacy(audioURL: prepared.url, offset: prepared.offset, recognizer: recognizer)
        }
        try Task.checkCancellation()
        let cues = CaptionGrouping.cues(from: words)
        guard !cues.isEmpty else { throw CaptionError.noSpeech }
        return cues
    }

    private static func legacy(audioURL: URL, offset: Double,
                               recognizer: SFSpeechRecognizer) async throws -> [CaptionWord] {
        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration).seconds
        var cursor = 0.0
        var words: [CaptionWord] = []
        // The legacy recognizer is a dictation API. Short, timestamped chunks
        // keep long takes within its per-request limits without any server path.
        while cursor < duration {
            try Task.checkCancellation()
            let length = min(45, duration - cursor)
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw CaptionError.recognition
            }
            exporter.timeRange = CMTimeRange(start: CMTime(seconds: cursor, preferredTimescale: 48_000),
                duration: CMTime(seconds: length, preferredTimescale: 48_000))
            let chunk = FileManager.default.temporaryDirectory.appendingPathComponent("roast-caption-chunk-\(UUID()).m4a")
            defer { try? FileManager.default.removeItem(at: chunk) }
            try await withTaskCancellationHandler {
                try await exporter.export(to: chunk, as: .m4a)
            } onCancel: { exporter.cancelExport() }
            let recognized = try await LegacyOnDeviceRecognition().recognize(url: chunk,
                offset: offset + cursor, recognizer: recognizer)
            words.append(contentsOf: recognized)
            cursor += length
        }
        return words
    }

    private static func modern(audioURL: URL, offset: Double, locale: Locale,
                               progress: @escaping ProgressHandler) async throws -> [CaptionWord] {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress(0, "Downloading the on-device language…")
            let observation = installation.progress.observe(\.fractionCompleted, options: [.new]) { value, _ in
                Task { @MainActor in progress(value.fractionCompleted, "Downloading the on-device language…") }
            }
            defer { observation.invalidate() }
            do {
                try await withTaskCancellationHandler {
                    try await installation.downloadAndInstall()
                } onCancel: { installation.progress.cancel() }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw CaptionError.languageDownload
            }
        }
        try Task.checkCancellation()
        progress(nil, "Captioning your voice on this device…")
        let file = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collected = Task { () throws -> [CaptionWord] in
            var words: [CaptionWord] = []
            for try await result in transcriber.results where result.isFinal {
                try Task.checkCancellation()
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    words.append(CaptionWord(start: offset + range.start.seconds,
                        end: offset + range.end.seconds, text: text))
                }
            }
            return words
        }
        do {
            return try await withTaskCancellationHandler {
                if let end = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else { await analyzer.cancelAndFinishNow() }
                return try await collected.value
            } onCancel: {
                collected.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            collected.cancel()
            await analyzer.cancelAndFinishNow()
            if Task.isCancelled { throw CancellationError() }
            throw CaptionError.recognition
        }
    }

    static func prepareMicrophoneAudio(from url: URL) async throws -> (url: URL, offset: Double) {
        let source = AVURLAsset(url: url)
        defer { withExtendedLifetime(source) {} }
        guard let microphone = try await source.loadTracks(withMediaType: .audio).first else {
            throw EditorError.unreadableAudio
        }
        let range = try await microphone.load(.timeRange)
        let asset = AVMutableComposition()
        guard let audio = asset.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw EditorError.unreadableAudio
        }
        try audio.insertTimeRange(range, of: microphone, at: .zero)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw EditorError.unreadableAudio
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("roast-voice-\(UUID()).m4a")
        do {
            try await withTaskCancellationHandler {
                try await exporter.export(to: target, as: .m4a)
            } onCancel: { exporter.cancelExport() }
            return (target, range.start.seconds)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }
}

@MainActor
private final class LegacyOnDeviceRecognition {
    private var continuation: CheckedContinuation<[CaptionWord], Error>?
    private var task: SFSpeechRecognitionTask?

    func recognize(url: URL, offset: Double, recognizer: SFSpeechRecognizer) async throws -> [CaptionWord] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                task = recognizer.recognitionTask(with: request) { result, error in
                    Task { @MainActor in
                        if let result, result.isFinal {
                            self.finish(.success(result.bestTranscription.segments.map {
                                CaptionWord(start: offset + $0.timestamp,
                                    end: offset + $0.timestamp + max(0.08, $0.duration), text: $0.substring)
                            }))
                        } else if error != nil { self.finish(.failure(CaptionError.recognition)) }
                    }
                }
                if Task.isCancelled { finish(.failure(CancellationError())) }
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
    }

    private func finish(_ result: Result<[CaptionWord], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        task?.cancel()
        task = nil
        continuation.resume(with: result)
    }
}
