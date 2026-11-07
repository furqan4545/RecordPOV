import Foundation

/// The video contains only captured microphone audio. Original clip sound is an
/// isolated, synchronized stem; editors must select the video track explicitly.
struct RecordingDraft: Identifiable, Codable, Sendable {
    let id: UUID
    let videoURL: URL
    let microphoneURL: URL?
    let sourceAudioURL: URL?
    let duration: TimeInterval
    let title: String
}
