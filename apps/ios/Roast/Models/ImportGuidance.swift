import Foundation

/// Tells the user to keep RecordPOV open while a link import runs, from the
/// lookup until the video is ready: the last step only runs while the app is open.
struct ImportGuidance: Equatable {
    enum Tone: Equatable { case stay, go }
    let tone: Tone
    let symbol: String
    let text: String

    static let readyTitle = "Your video is ready"
    static let keepOpen = "Keep RecordPOV open until your video is ready."

    static func current(phase: VideoLinkLoadingPhase) -> ImportGuidance? {
        phase == .idle ? nil : stay(keepOpen)
    }

    /// Whole percent, rounded down and clamped to 0-100; nil while the size is unknown.
    static func percentText(_ progress: Double?) -> String? {
        percentValue(progress).map { "\($0)%" }
    }

    /// The same whole percent as a number, shared by the text and the bar's VoiceOver value.
    static func percentValue(_ progress: Double?) -> Int? {
        guard let progress, progress.isFinite else { return nil }
        let clamped = min(max(progress, 0), 1)
        // The tiny bias keeps exact steps such as 0.29 from showing as 28%.
        return Int((clamped * 100 + 1e-9).rounded(.down))
    }

    private static func stay(_ text: String) -> ImportGuidance {
        ImportGuidance(tone: .stay, symbol: "iphone", text: text)
    }
}
