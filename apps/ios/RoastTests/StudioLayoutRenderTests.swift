import CoreImage
import CoreVideo
import UIKit
import XCTest
@testable import Roast

final class StudioLayoutRenderTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    func testSplitRendersOriginalAboveCameraAtTheChosenDivider() async throws {
        let pipeline = try await pipelineWithRedCamera()
        var pip = PiPTransform()
        pip.style = .square
        pip.layout = .split
        for fraction in [0.7, 0.5] {
            pip.splitRatio = fraction
            let image = try await render(pipeline, pip: pip)
            assertColor(image, red: false, x: 0.5, y: 1 - fraction + 0.03)
            assertColor(image, red: true, x: 0.5, y: 1 - fraction - 0.03)
            assertColor(image, red: false, x: 0.5, y: 0.95)
            assertColor(image, red: true, x: 0.5, y: 0.05)
        }
    }

    func testSplitSourceGeometryKeepsTheCompleteOriginalInsideEveryPane() {
        let canvas = CGRect(x: 14, y: 20, width: 720, height: 1280)
        for source in [CGSize(width: 720, height: 1280), CGSize(width: 1280, height: 720),
                       CGSize(width: 1800, height: 600)] {
            for fraction in [0.2, 0.43, 0.7, 0.8] {
                let pane = StudioLayoutGeometry.splitRects(canvas: canvas, originalFraction: fraction).source
                let content = StudioLayoutGeometry.splitSourceRect(source: source, in: pane)
                XCTAssertGreaterThanOrEqual(content.minX, pane.minX - 0.001)
                XCTAssertGreaterThanOrEqual(content.minY, pane.minY - 0.001)
                XCTAssertLessThanOrEqual(content.maxX, pane.maxX + 0.001)
                XCTAssertLessThanOrEqual(content.maxY, pane.maxY + 0.001)
                XCTAssertEqual(content.midX, pane.midX, accuracy: 0.001)
                XCTAssertEqual(content.midY, pane.midY, accuracy: 0.001)
                XCTAssertEqual(content.width / content.height, source.width / source.height, accuracy: 0.001)
                XCTAssertTrue(abs(content.width - pane.width) < 0.001 || abs(content.height - pane.height) < 0.001)
            }
        }
    }

    func testMovingTheSplitDividerNeverCropsAnyOriginalCorner() async throws {
        let pipeline = try await pipelineWithRedCamera()
        var pip = PiPTransform()
        pip.style = .square
        pip.layout = .split
        for size in [CGSize(width: 720, height: 1280), CGSize(width: 1280, height: 720),
                     CGSize(width: 1800, height: 600)] {
            // A nonzero CIImage origin must not move the original out of its pane.
            let source = markedSource(size: size).transformed(by: .init(translationX: 37, y: -50))
            for fraction in [0.2, 0.43, 0.7, 0.8] {
                pip.splitRatio = fraction
                let image = try await render(pipeline, pip: pip, source: source)
                if fraction == 0.43, size.width == 720 || size.width == 1280 {
                    let proof = XCTAttachment(image: image)
                    proof.name = size.width == 720 ? "Split portrait with every original edge visible" : "Split landscape with soft background fill"
                    proof.lifetime = .keepAlways
                    add(proof)
                }
                let raster = try decode(image)
                let pane = StudioLayoutGeometry.splitRects(canvas: StudioFramePipeline.canvas,
                    originalFraction: fraction).source
                let content = StudioLayoutGeometry.splitSourceRect(source: size, in: pane)
                for (x, y, color) in [(0.08, 0.92, [255, 0, 0]), (0.92, 0.92, [0, 255, 0]),
                                      (0.08, 0.08, [0, 0, 255]), (0.92, 0.08, [255, 255, 0])] {
                    assertPixel(raster, at: CGPoint(x: content.minX + content.width * x,
                        y: content.minY + content.height * y), equals: color)
                }
                assertPixel(raster, at: CGPoint(x: StudioFramePipeline.canvas.midX,
                    y: pane.minY / 2), equals: [255, 0, 0])
            }
        }
    }

    func testSplitAspectGapsUseASoftenedSourceWhileTheOriginalStaysSharp() async throws {
        let pipeline = try await pipelineWithRedCamera()
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 360)
        var source = CIImage(color: .red).cropped(to: bounds)
        for x in stride(from: 0, to: 640, by: 16) {
            source = CIImage(color: .blue).cropped(to: CGRect(x: x, y: 0, width: 8, height: 360))
                .composited(over: source)
        }
        var pip = PiPTransform()
        pip.style = .square
        pip.layout = .split
        let image = try await render(pipeline, pip: pip, source: source)
        let raster = try decode(image)
        let pane = StudioLayoutGeometry.splitRects(canvas: StudioFramePipeline.canvas,
            originalFraction: pip.splitRatio).source
        let content = StudioLayoutGeometry.splitSourceRect(source: bounds.size, in: pane)
        assertPixel(raster, at: CGPoint(x: content.minX + content.width * 0.31,
            y: content.midY), equals: [0, 0, 255])
        let gap = raster.pixel(at: CGPoint(x: pane.minX + pane.width * 0.31, y: pane.maxY - 12))
        XCTAssertGreaterThan(gap[0], 30, "The gap must contain the original's softened red and blue, not an empty bar.")
        XCTAssertGreaterThan(gap[2], 30)
        XCTAssertLessThan(gap[0], 240)
        XCTAssertLessThan(gap[2], 240)
        XCTAssertLessThan(gap[1], 15)
        XCTAssertEqual(gap[3], 255)
    }

    func testStageRendersCameraMainWithMovableOriginalOverlay() async throws {
        let pipeline = try await pipelineWithRedCamera()
        var pip = PiPTransform()
        pip.style = .square
        pip.layout = .cameraMain
        let initial = try await render(pipeline, pip: pip)
        assertColor(initial, red: true, x: 0.15, y: 0.5)
        assertColor(initial, red: false, x: pip.sourceOverlay.x, y: 1 - pip.sourceOverlay.y)
        pip.sourceOverlay.x = 0.25
        pip.sourceOverlay.y = 0.75
        let moved = try await render(pipeline, pip: pip)
        assertColor(moved, red: false, x: 0.25, y: 0.25)
        assertColor(moved, red: true, x: 0.76, y: 0.77)
    }

    func testFullScreenHidesOriginalAndRestoresThePreviousStageOverlay() async throws {
        let pipeline = try await pipelineWithRedCamera()
        var pip = PiPTransform()
        pip.style = .square
        pip.layout = .cameraMain
        let originalOverlay = pip.sourceOverlay
        let baseline = try await render(pipeline, pip: pip)
        assertColor(baseline, red: false, x: 0.76, y: 0.77)
        pip.isFullScreen = true
        let full = try await render(pipeline, pip: pip)
        for point in [CGPoint(x: 0.76, y: 0.77), CGPoint(x: 0.1, y: 0.1)] {
            assertColor(full, red: true, x: point.x, y: point.y)
        }
        pip.isFullScreen = false
        let restored = try await render(pipeline, pip: pip)
        assertColor(restored, red: false, x: 0.76, y: 0.77)
        XCTAssertEqual(pip.sourceOverlay, originalOverlay)
    }

    func testCameraOffRendersOnlyOriginalForEveryLayoutAndFullScreenState() async throws {
        let pipeline = try await pipelineWithRedCamera()
        for layout in StudioLayout.allCases {
            for fullScreen in [false, true] {
                var pip = PiPTransform()
                pip.style = .square
                pip.layout = layout
                pip.isFullScreen = fullScreen
                let image = try await render(pipeline, pip: pip, cameraEnabled: false)
                for point in [CGPoint(x: 0.05, y: 0.05), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.95, y: 0.95)] {
                    assertColor(image, red: false, x: point.x, y: point.y)
                }
            }
        }
    }

    private func pipelineWithRedCamera() async throws -> StudioFramePipeline {
        let pipeline = StudioFramePipeline()
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let camera = try XCTUnwrap(buffer)
        context.render(CIImage(color: .red), to: camera,
                       bounds: CGRect(x: 0, y: 0, width: 1280, height: 720), colorSpace: nil)
        await pipeline.debugInjectCameraBuffer(camera)
        return pipeline
    }

    private func render(_ pipeline: StudioFramePipeline, pip: PiPTransform,
                        cameraEnabled: Bool = true, source: CIImage? = nil) async throws -> UIImage {
        let source = source ?? CIImage(color: .blue).cropped(to: StudioFramePipeline.canvas)
        let result: StudioRenderResult = await withCheckedContinuation { continuation in
            pipeline.render(StudioRenderRequest(source: source, pip: pip,
                cameraEnabled: cameraEnabled, recordingTime: nil)) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(result.cameraPresent, cameraEnabled)
        return try XCTUnwrap(result.image)
    }

    private func markedSource(size: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        let width = size.width * 0.16, height = size.height * 0.16
        var image = CIImage(color: .gray).cropped(to: bounds)
        for (x, y, color) in [(CGFloat(0), size.height - height, CIColor.red),
                              (size.width - width, size.height - height, CIColor.green),
                              (CGFloat(0), CGFloat(0), CIColor.blue),
                              (size.width - width, CGFloat(0), CIColor.yellow)] {
            image = CIImage(color: color).cropped(to: CGRect(x: x, y: y, width: width, height: height))
                .composited(over: image)
        }
        return image.cropped(to: bounds)
    }

    private struct Raster {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func pixel(at point: CGPoint) -> [UInt8] {
            let column = min(width - 1, max(0, Int(point.x)))
            let row = min(height - 1, max(0, Int(CGFloat(height) - point.y)))
            let offset = (row * width + column) * 4
            return Array(bytes[offset..<(offset + 4)])
        }
    }

    private func decode(_ image: UIImage) throws -> Raster {
        let cgImage = try XCTUnwrap(image.cgImage)
        let input = CIImage(cgImage: cgImage)
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            context.render(input, toBitmap: $0.baseAddress!, rowBytes: width * 4,
                           bounds: input.extent, format: .RGBA8, colorSpace: nil)
        }
        return Raster(width: width, height: height, bytes: bytes)
    }

    private func assertPixel(_ raster: Raster, at point: CGPoint, equals color: [Int],
                             file: StaticString = #filePath, line: UInt = #line) {
        let actual = raster.pixel(at: point)
        for channel in 0..<3 {
            XCTAssertEqual(Double(actual[channel]), Double(color[channel]), accuracy: 12,
                           "Unexpected original content at \(point)", file: file, line: line)
        }
        XCTAssertEqual(actual[3], 255, file: file, line: line)
    }

    /// Test points use the compositor's bottom-left coordinates. The rendered
    /// UIImage/CGImage raster has a top-left row origin, so flip only its row index.
    private func assertColor(_ image: UIImage, red: Bool, x: Double, y: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let cgImage = image.cgImage else { XCTFail("Missing rendered image", file: file, line: line); return }
        let input = CIImage(cgImage: cgImage)
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            context.render(input, toBitmap: $0.baseAddress!, rowBytes: width * 4,
                           bounds: input.extent, format: .RGBA8, colorSpace: nil)
        }
        let column = min(width - 1, max(0, Int(x * Double(width))))
        let row = min(height - 1, max(0, Int((1 - y) * Double(height))))
        let offset = (row * width + column) * 4
        XCTAssertGreaterThan(bytes[offset + (red ? 0 : 2)], 240, file: file, line: line)
        XCTAssertLessThan(bytes[offset + (red ? 2 : 0)], 12, file: file, line: line)
        XCTAssertEqual(bytes[offset + 3], 255, file: file, line: line)
    }
}
