import Foundation

/// Continuous, source-clock selection for the editor's two trim handles.
/// Audio gains, music and caption text are preserved by every operation.
enum EditorTimelineEditing {
    static func minimumDuration(for duration: Double) -> Double {
        min(0.2, total(duration))
    }

    static func normalized(_ edits: TakeEdits, duration: Double) -> TakeEdits {
        let length = total(duration)
        let minimum = minimumDuration(for: length)
        var result = edits
        result.trimStart = bounded(edits.trimStart, lower: 0, upper: length, fallback: 0)
        result.trimEnd = bounded(edits.trimEnd, lower: 0, upper: length, fallback: length)
        if result.trimEnd - result.trimStart < minimum {
            result.trimEnd = min(length, result.trimStart + minimum)
            result.trimStart = max(0, result.trimEnd - minimum)
        }
        // The user explicitly chose a single continuous start/end interval.
        result.cuts = []
        return result
    }

    static func trimmingStart(to seconds: Double, edits: TakeEdits, duration: Double) -> TakeEdits {
        var result = normalized(edits, duration: duration)
        result.trimStart = bounded(seconds, lower: 0,
            upper: max(0, result.trimEnd - minimumDuration(for: duration)), fallback: result.trimStart)
        return result
    }

    static func trimmingEnd(to seconds: Double, edits: TakeEdits, duration: Double) -> TakeEdits {
        var result = normalized(edits, duration: duration)
        result.trimEnd = bounded(seconds, lower: min(total(duration), result.trimStart + minimumDuration(for: duration)),
                                 upper: total(duration), fallback: result.trimEnd)
        return result
    }

    static func boundedSourceTime(_ seconds: Double, duration: Double) -> Double {
        bounded(seconds, lower: 0, upper: total(duration), fallback: 0)
    }

    private static func total(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
    private static func bounded(_ value: Double, lower: Double, upper: Double, fallback: Double) -> Double {
        min(upper, max(lower, value.isFinite ? value : fallback))
    }
}
