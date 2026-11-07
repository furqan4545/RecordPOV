import Foundation

/// Video codecs named by the hybrid manifest ('unknown' is decided after download).
enum SourceVideoCodec: String, Codable, Sendable {
    case h264, hevc, vp9, av1, unknown

    init(manifest value: String?) {
        self = value.flatMap { SourceVideoCodec(rawValue: $0.lowercased()) } ?? .unknown
    }
}

/// What this phone can decode. Pure, so the plan choice is unit-testable.
struct VideoDecodeCapabilities: Sendable {
    /// Apple's supplemental VP9/AV1 decoders exist only from iOS 26.2.
    let supplementalDecodersAvailable: Bool
    let decodes: @Sendable (SourceVideoCodec) -> Bool

    func canDecode(_ codec: SourceVideoCodec) -> Bool {
        codec == .h264 || decodes(codec)
    }
}

/// Which asset set of a direct manifest this phone downloads.
enum ImportPlan: Codable, Equatable, Sendable {
    /// Download the primary set; convert it on the phone when it is not directly playable.
    case primary
    /// Download the best directly playable set instead.
    case fallback
    case unsupported(String)

    static let needsNewerIOSMessage = "This video needs iOS 26.2 or later. Update iOS and try again."
    static let unsupportedFormatMessage = "This phone can't open this video's format. Try another link."

    static func choose(_ delivery: MediaDelivery?, capabilities: VideoDecodeCapabilities) -> ImportPlan {
        guard let delivery, delivery.kind == "direct" else { return .primary }
        let codec = SourceVideoCodec(manifest: delivery.expected?.videoCodec)
        // An unknown codec is inspected once the file is on the phone.
        if codec == .unknown || capabilities.canDecode(codec) { return .primary }
        if delivery.fallback != nil { return .fallback }
        return .unsupported(unsupportedMessage(codec, capabilities: capabilities))
    }

    static func unsupportedMessage(_ codec: SourceVideoCodec, capabilities: VideoDecodeCapabilities) -> String {
        [.vp9, .av1].contains(codec) && !capabilities.supplementalDecodersAvailable ? needsNewerIOSMessage : unsupportedFormatMessage
    }
}

struct ImportFormatError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
