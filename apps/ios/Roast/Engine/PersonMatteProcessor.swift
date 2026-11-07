import CoreImage
import CoreVideo
import Foundation
import Vision

/// Owns one continuous camera sequence. All calls stay on the frame queue.
final class PersonMatteProcessor {
    private let quality: VNGeneratePersonSegmentationRequest.QualityLevel
    private(set) var request: VNGeneratePersonSegmentationRequest
    private var sequence = VNSequenceRequestHandler()
    private var lastSize = CGSize.zero
    private var lastRevision: Int64?
    private var cachedCutout: CIImage?
    private(set) var maskSize = CGSize.zero
    private(set) var lastInferenceMilliseconds: Double = 0

    init(quality: VNGeneratePersonSegmentationRequest.QualityLevel = .accurate) {
        self.quality = quality
        request = Self.makeRequest(quality: quality)
    }

    func reset() {
        request = Self.makeRequest(quality: quality)
        sequence = VNSequenceRequestHandler()
        lastSize = .zero
        lastRevision = nil
        cachedCutout = nil
        maskSize = .zero
    }

    func cutout(from buffer: CVPixelBuffer, revision: Int64) throws -> CIImage? {
        let camera = CIImage(cvPixelBuffer: buffer)
        if camera.extent.size != lastSize {
            reset()
            lastSize = camera.extent.size
        }
        if lastRevision == revision { return cachedCutout }
        // Never reuse an old person's matte if this frame fails to segment.
        lastRevision = nil
        cachedCutout = nil
        let started = ProcessInfo.processInfo.systemUptime
        defer { lastInferenceMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000 }
        try sequence.perform([request], on: buffer, orientation: .up)
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        // Confidence values are data, not display colors. Preserve their range.
        let mask = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        maskSize = mask.extent.size
        let cutout = Self.apply(mask: mask, to: camera)
        cachedCutout = cutout
        lastRevision = revision
        return cutout
    }

    static func alignedMask(_ mask: CIImage, to extent: CGRect) -> CIImage {
        guard mask.extent.width > 0, mask.extent.height > 0 else {
            return CIImage(color: .clear).cropped(to: extent)
        }
        // Vision masks use normalized image coordinates. Aspect-fill would crop
        // a square mask against a portrait camera and move the silhouette edges.
        return mask.samplingLinear()
            .transformed(by: .init(translationX: -mask.extent.minX, y: -mask.extent.minY))
            .transformed(by: .init(scaleX: extent.width / mask.extent.width,
                                  y: extent.height / mask.extent.height))
            .transformed(by: .init(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    static func apply(mask: CIImage, to camera: CIImage) -> CIImage {
        // A one-component Vision buffer is in the red channel. Luminance-mask
        // blending can change those confidence values and make people translucent.
        camera.applyingFilter("CIBlendWithRedMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: camera.extent),
            kCIInputMaskImageKey: alignedMask(mask, to: camera.extent),
        ]).cropped(to: camera.extent)
    }

    private static func makeRequest(quality: VNGeneratePersonSegmentationRequest.QualityLevel)
        -> VNGeneratePersonSegmentationRequest {
        let request = VNGeneratePersonSegmentationRequest()
        request.revision = VNGeneratePersonSegmentationRequest.supportedRevisions.max()
            ?? VNGeneratePersonSegmentationRequest.defaultRevision
        request.qualityLevel = quality
        let supported = (try? request.supportedOutputPixelFormats())?.map(\.uint32Value) ?? []
        request.outputPixelFormat = supported.contains(kCVPixelFormatType_OneComponent16Half)
            ? kCVPixelFormatType_OneComponent16Half
            : (supported.contains(kCVPixelFormatType_OneComponent32Float)
               ? kCVPixelFormatType_OneComponent32Float : kCVPixelFormatType_OneComponent8)
        return request
    }
}
