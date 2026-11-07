import CoreMedia
import Foundation
import VideoToolbox

/// Decoders available on this phone. VP9 and AV1 need Apple's supplemental
/// decoders, which an app must register (iOS 26.2 and later) before use.
enum DeviceVideoCapabilities {
    /// Runs once per launch, on first use.
    private static let registration: Void = {
        if #available(iOS 26.2, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
        }
    }()

    static func registerSupplementalDecoders() { _ = registration }

    static var supplementalDecodersAvailable: Bool {
        if #available(iOS 26.2, *) { return true }
        return false
    }

    static func canDecode(_ codec: SourceVideoCodec) -> Bool {
        registerSupplementalDecoders()
        switch codec {
        case .h264: return true
        case .hevc: return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        case .vp9: return VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)
        case .av1: return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        case .unknown: return false
        }
    }

    static var current: VideoDecodeCapabilities {
        VideoDecodeCapabilities(supplementalDecodersAvailable: supplementalDecodersAvailable,
                                decodes: { canDecode($0) })
    }

    /// The codec of a decoded track's format, from the file itself.
    static func codec(of subtype: FourCharCode) -> SourceVideoCodec {
        switch subtype {
        case kCMVideoCodecType_H264: return .h264
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha: return .hevc
        case kCMVideoCodecType_VP9: return .vp9
        case kCMVideoCodecType_AV1: return .av1
        default: return .unknown
        }
    }
}
