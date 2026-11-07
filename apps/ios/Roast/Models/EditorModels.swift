import Foundation

struct EditInterval: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    var duration: Double { max(0, end - start) }
}

struct CaptionWord: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

struct TakeCaption: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var words: [CaptionWord] = []
}

struct TakeEdits: Codable, Equatable, Sendable {
    var trimStart: Double = 0
    var trimEnd: Double
    var cuts: [EditInterval] = []
    var sourceVolume: Double = 0.75
    var microphoneVolume: Double = 0.6
    /// New takes receive gentle cleanup; older drafts keep their raw voice until enabled.
    var voiceCleanupEnabled: Bool? = true
    var musicVolume: Double = 0.35
    var musicURL: URL?
    var musicTitle: String?
    var captionsEnabled = true
    var captions: [TakeCaption] = []

    init(duration: Double) { trimEnd = duration.isFinite ? max(0, duration) : 0 }

}

extension TakeEdits {
    private enum CodingKeys: String, CodingKey {
        case trimStart, trimEnd, cuts, sourceVolume, microphoneVolume, voiceCleanupEnabled
        case musicVolume, musicURL, musicTitle, captionsEnabled, captions
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        trimStart = try values.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
        trimEnd = try values.decode(Double.self, forKey: .trimEnd)
        cuts = try values.decodeIfPresent([EditInterval].self, forKey: .cuts) ?? []
        sourceVolume = try values.decodeIfPresent(Double.self, forKey: .sourceVolume) ?? 0.75
        microphoneVolume = try values.decodeIfPresent(Double.self, forKey: .microphoneVolume) ?? 0.6
        // A missing old cleanup choice must not change an existing draft's sound.
        voiceCleanupEnabled = try values.decodeIfPresent(Bool.self, forKey: .voiceCleanupEnabled)
        musicVolume = try values.decodeIfPresent(Double.self, forKey: .musicVolume) ?? 0.35
        musicURL = try values.decodeIfPresent(URL.self, forKey: .musicURL)
        musicTitle = try values.decodeIfPresent(String.self, forKey: .musicTitle)
        captionsEnabled = try values.decodeIfPresent(Bool.self, forKey: .captionsEnabled) ?? true
        captions = try values.decodeIfPresent([TakeCaption].self, forKey: .captions) ?? []
    }
}

/// Every stem and caption uses the original recording's clock. The kept ranges
/// are the single mapping used by preview, export, trimming, and caption timing.
struct EditorTimeline: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        var sourceStart: Double
        var sourceEnd: Double
        var outputStart: Double
        var duration: Double { sourceEnd - sourceStart }
        var outputEnd: Double { outputStart + duration }
    }

    let segments: [Segment]
    var duration: Double { segments.last?.outputEnd ?? 0 }

    init(duration: Double, edits: TakeEdits) {
        let total = duration.isFinite ? max(0, duration) : 0
        let start = min(total, max(0, edits.trimStart.isFinite ? edits.trimStart : 0))
        let end = min(total, max(start, edits.trimEnd.isFinite ? edits.trimEnd : total))
        let cuts = edits.cuts.compactMap { cut -> (Double, Double)? in
            guard cut.start.isFinite, cut.end.isFinite else { return nil }
            let lower = max(start, min(cut.start, cut.end))
            let upper = min(end, max(cut.start, cut.end))
            return upper > lower ? (lower, upper) : nil
        }.sorted { $0.0 < $1.0 }

        var kept: [Segment] = []
        var cursor = start
        var output = 0.0
        for cut in cuts {
            if cut.0 > cursor {
                kept.append(Segment(sourceStart: cursor, sourceEnd: cut.0, outputStart: output))
                output += cut.0 - cursor
            }
            cursor = max(cursor, cut.1)
        }
        if end > cursor {
            kept.append(Segment(sourceStart: cursor, sourceEnd: end, outputStart: output))
        }
        segments = kept
    }

    func sourceTime(atOutput time: Double) -> Double {
        let position = min(duration, max(0, time.isFinite ? time : 0))
        for segment in segments where position < segment.outputEnd {
            return segment.sourceStart + max(0, position - segment.outputStart)
        }
        return segments.last?.sourceEnd ?? 0
    }

    func outputTime(atSource time: Double) -> Double {
        for segment in segments {
            if time <= segment.sourceStart { return segment.outputStart }
            if time < segment.sourceEnd { return segment.outputStart + time - segment.sourceStart }
        }
        return duration
    }

    func remap(_ captions: [TakeCaption]) -> [TakeCaption] {
        captions.flatMap { caption in
            segments.compactMap { segment -> TakeCaption? in
                let start = max(caption.start, segment.sourceStart)
                let end = min(caption.end, segment.sourceEnd)
                guard end > start else { return nil }
                var text = caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
                var visibleStart = start
                var visibleEnd = end
                // Generated word timings let cuts remove the corresponding words.
                // A manually corrected line keeps the user's exact replacement text.
                if !caption.words.isEmpty, caption.text == caption.words.map(\.text).joined(separator: " ") {
                    let words = caption.words.filter { $0.end > start && $0.start < end }
                    guard let first = words.first, let last = words.last else { return nil }
                    text = words.map(\.text).joined(separator: " ")
                    visibleStart = max(start, first.start)
                    visibleEnd = min(end, last.end)
                }
                guard !text.isEmpty else { return nil }
                return TakeCaption(start: segment.outputStart + visibleStart - segment.sourceStart,
                                   end: segment.outputStart + visibleEnd - segment.sourceStart, text: text)
            }
        }.sorted { $0.start < $1.start }
    }
}

enum EditorError: LocalizedError {
    case noVideo, emptyEdit, unreadableAudio, exportUnavailable, invalidMusic
    var errorDescription: String? {
        switch self {
        case .noVideo: "This recording couldn’t be opened. Your draft is still on this device."
        case .emptyEdit: "Select a section with the trim handles, or reset the trim."
        case .unreadableAudio: "An audio track couldn’t be opened. Your draft is still safe."
        case .exportUnavailable: "The edited video couldn’t be saved. Your draft and edits are still safe."
        case .invalidMusic: "Choose an audio file that is at least a quarter of a second long."
        }
    }
}

enum EditorEditStore {
    static func load(for draft: RecordingDraft) -> TakeEdits {
        let folder = draft.videoURL.deletingLastPathComponent()
        let url = folder.appendingPathComponent("edits.json")
        guard var edits = try? JSONDecoder().decode(TakeEdits.self, from: Data(contentsOf: url)) else {
            return TakeEdits(duration: draft.duration)
        }
        if let music = edits.musicURL {
            let name = music.lastPathComponent
            edits.musicURL = !name.isEmpty && name != "." && name != ".." && name != "/"
                ? folder.appendingPathComponent(name, isDirectory: false) : nil
        }
        return edits
    }

    static func save(_ edits: TakeEdits, for draft: RecordingDraft) throws {
        let url = draft.videoURL.deletingLastPathComponent().appendingPathComponent("edits.json")
        try JSONEncoder().encode(edits).write(to: url, options: .atomic)
    }
}
