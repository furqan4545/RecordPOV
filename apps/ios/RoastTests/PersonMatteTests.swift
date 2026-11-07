import CoreImage
import CoreVideo
import Vision
import XCTest
@testable import Roast

final class PersonMatteTests: XCTestCase {
    private let context = CIContext(options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
        .cacheIntermediates: false,
    ])

    func testRedMaskPreservesOpaqueTransparentAndSoftAlpha() {
        let extent = CGRect(x: 0, y: 0, width: 8, height: 8)
        let camera = CIImage(color: .white).cropped(to: extent)
        for confidence in [0.0, 0.125, 0.5, 0.875, 1.0] {
            // Green/blue intentionally stay zero: luminance blending would fail.
            let mask = CIImage(color: CIColor(red: confidence, green: 0, blue: 0))
                .cropped(to: extent)
            let result = PersonMatteProcessor.apply(mask: mask, to: camera)
            let pixel = rgba(result, at: CGPoint(x: 3, y: 3))
            XCTAssertEqual(pixel[3], Float(confidence), accuracy: 0.002)
            // Core Image returns premultiplied color, so this also checks blending.
            XCTAssertEqual(pixel[0], Float(confidence), accuracy: 0.002)
        }
    }

    func testSingleComponentFloatMaskPreservesConfidence() throws {
        let confidence: [Float] = [0, 0.125, 0.5, 0.875, 1]
        let mask = try floatMask(width: confidence.count, height: 2) { column, _ in confidence[column] }
        let camera = CIImage(color: .white).cropped(to: mask.extent)
        let result = PersonMatteProcessor.apply(mask: mask, to: camera)
        for column in confidence.indices {
            XCTAssertEqual(rgba(result, at: CGPoint(x: column, y: 0))[3],
                           confidence[column], accuracy: 0.002)
        }
    }

    func testMaskAlignmentScalesBothAxesAndPreservesNonzeroOrigins() throws {
        let maskExtent = CGRect(x: 17, y: 31, width: 8, height: 8)
        for target in [CGRect(x: -19, y: 43, width: 80, height: 40),
                       CGRect(x: 23, y: -37, width: 40, height: 80)] {
            for horizontal in [true, false] {
                let gradient = try floatMask(width: 8, height: 8) { column, row in
                    (Float(horizontal ? column : row) + 0.5) / 8
                }.transformed(by: .init(translationX: maskExtent.minX, y: maskExtent.minY))
                let aligned = PersonMatteProcessor.alignedMask(gradient, to: target)
                XCTAssertEqual(aligned.extent, target)
                for fraction in [0.25, 0.75] {
                    let localX = floor(target.width * fraction)
                    let localY = floor(target.height * fraction)
                    let point = CGPoint(x: target.minX + localX, y: target.minY + localY)
                    let expected = horizontal
                        ? (localX + 0.5) / target.width : (localY + 0.5) / target.height
                    XCTAssertEqual(rgba(aligned, at: point)[0], Float(expected), accuracy: 0.003)
                }
            }
        }
    }

    func testProductionConfigurationUsesAccurateAndNewestSupportedRevision() throws {
        let processor = PersonMatteProcessor()
        let request = processor.request
        XCTAssertEqual(request.qualityLevel, .accurate)
        XCTAssertEqual(request.revision,
                       VNGeneratePersonSegmentationRequest.supportedRevisions.max()
                        ?? VNGeneratePersonSegmentationRequest.defaultRevision)
        let formats = try request.supportedOutputPixelFormats().map(\.uint32Value)
        let expected = formats.contains(kCVPixelFormatType_OneComponent16Half)
            ? kCVPixelFormatType_OneComponent16Half
            : (formats.contains(kCVPixelFormatType_OneComponent32Float)
               ? kCVPixelFormatType_OneComponent32Float : kCVPixelFormatType_OneComponent8)
        XCTAssertEqual(request.outputPixelFormat, expected)
        processor.reset()
        XCTAssertFalse(processor.request === request)
        XCTAssertEqual(processor.request.qualityLevel, .accurate)
        XCTAssertEqual(processor.request.outputPixelFormat, expected)
    }

    private func floatMask(width: Int, height: Int,
                           confidence: (Int, Int) -> Float) throws -> CIImage {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                        kCVPixelFormatType_OneComponent32Float, nil, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let maskBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(maskBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(maskBuffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(maskBuffer))
        for row in 0..<height {
            let values = base.advanced(by: row * CVPixelBufferGetBytesPerRow(maskBuffer))
                .assumingMemoryBound(to: Float.self)
            for column in 0..<width { values[column] = confidence(column, row) }
        }
        return CIImage(cvPixelBuffer: maskBuffer, options: [.colorSpace: NSNull()])
    }

    /// Renders the whole image before indexing pixels. A one-pixel render region
    /// can optimize an upstream affine sample differently from the full video frame.
    private func rgba(_ image: CIImage, at point: CGPoint) -> [Float] {
        let bounds = image.extent.integral
        let width = Int(bounds.width)
        var pixels = [Float](repeating: .nan, count: width * Int(bounds.height) * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!,
                           rowBytes: width * 4 * MemoryLayout<Float>.size,
                           bounds: bounds, format: .RGBAf, colorSpace: nil)
        }
        let column = Int(floor(point.x - bounds.minX))
        let row = Int(floor(point.y - bounds.minY))
        let start = (row * width + column) * 4
        return Array(pixels[start..<(start + 4)])
    }
}
