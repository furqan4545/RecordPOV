import XCTest
@testable import Roast

final class CameraFramingTests: XCTestCase {
    func testRegularShapesCoverEveryEdgeForPortraitAndLandscapeFeeds() {
        for style in [PiPStyle.rounded, .circle, .square] {
            let viewport = CGSize(width: 240, height: style == .rounded ? 312 : 240)
            for source in [CGSize(width: 720, height: 1280), CGSize(width: 1280, height: 720)] {
                for framing in [1.0, 1.6, 2.5] {
                    let rect = CameraFramingGeometry.contentRect(source: source, viewport: viewport,
                                                                 style: style, framingScale: framing)
                    assertCoversViewport(rect, viewport: viewport)
                    XCTAssertEqual(rect.midX, viewport.width / 2, accuracy: 0.001)
                    XCTAssertEqual(rect.midY, viewport.height / 2, accuracy: 0.001)
                    if framing == 1 {
                        // The default fills with the minimum crop needed, not extra zoom.
                        XCTAssertEqual(min(rect.width / viewport.width, rect.height / viewport.height),
                                       1, accuracy: 0.001)
                    }
                }
            }
        }
    }

    func testRegularFramingBelowOneCannotExposeMargins() {
        for style in [PiPStyle.rounded, .circle, .square] {
            let viewport = CGSize(width: 240, height: style == .rounded ? 312 : 240)
            for source in [CGSize(width: 720, height: 1280), CGSize(width: 1280, height: 720)] {
                let baseline = CameraFramingGeometry.contentRect(source: source, viewport: viewport,
                                                                 style: style, framingScale: 1)
                for framing in [0.0, 0.55, 0.8] {
                    let rect = CameraFramingGeometry.contentRect(source: source, viewport: viewport,
                                                                 style: style, framingScale: framing)
                    assertCoversViewport(rect, viewport: viewport)
                    XCTAssertEqual(rect, baseline)
                }
            }
        }
    }

    func testCameraAspectRatioIsPreservedInEveryStyle() {
        for source in [CGSize(width: 720, height: 1280), CGSize(width: 1280, height: 720),
                       CGSize(width: 1440, height: 1920)] {
            for style in PiPStyle.allCases {
                for framing in [0.55, 1.0, 2.0] {
                    let rect = CameraFramingGeometry.contentRect(source: source,
                                                                 viewport: CGSize(width: 240, height: 312),
                                                                 style: style, framingScale: framing)
                    XCTAssertEqual(rect.width / rect.height, source.width / source.height, accuracy: 0.0001)
                }
            }
        }
    }

    func testCutoutFitsTheWholeFeedAndAllowsWiderFraming() {
        let viewport = CGSize(width: 240, height: 312)
        for source in [CGSize(width: 720, height: 1280), CGSize(width: 1280, height: 720)] {
            let baseline = CameraFramingGeometry.contentRect(source: source, viewport: viewport,
                                                             style: .cutout, framingScale: 1)
            XCTAssertEqual(max(baseline.width / viewport.width, baseline.height / viewport.height),
                           1, accuracy: 0.001)
            for framing in [0.55, 0.8, 1.0] {
                let rect = CameraFramingGeometry.contentRect(source: source, viewport: viewport,
                                                             style: .cutout, framingScale: framing)
                XCTAssertGreaterThanOrEqual(rect.minX, -0.001)
                XCTAssertGreaterThanOrEqual(rect.minY, -0.001)
                XCTAssertLessThanOrEqual(rect.maxX, viewport.width + 0.001)
                XCTAssertLessThanOrEqual(rect.maxY, viewport.height + 0.001)
                XCTAssertEqual(rect.midX, viewport.width / 2, accuracy: 0.001)
                XCTAssertEqual(rect.midY, viewport.height / 2, accuracy: 0.001)
                if framing < 1 {
                    XCTAssertLessThan(rect.width, baseline.width)
                    XCTAssertLessThan(rect.height, baseline.height)
                }
            }
        }
    }

    func testPiPSizeDoesNotChangeFraming() {
        for style in PiPStyle.allCases {
            let small = CameraFramingGeometry.contentRect(source: CGSize(width: 720, height: 1280),
                                                          viewport: CGSize(width: 120, height: 156),
                                                          style: style, framingScale: style == .cutout ? 0.8 : 1.4)
            let large = CameraFramingGeometry.contentRect(source: CGSize(width: 720, height: 1280),
                                                          viewport: CGSize(width: 360, height: 468),
                                                          style: style, framingScale: style == .cutout ? 0.8 : 1.4)
            XCTAssertEqual(small.width / 120, large.width / 360, accuracy: 0.001)
            XCTAssertEqual(small.height / 156, large.height / 468, accuracy: 0.001)
        }
    }

    func testCloserFramingIsExplicitAndLegacyTransformFits() throws {
        let baseline = CameraFramingGeometry.contentRect(source: CGSize(width: 720, height: 1280),
                                                         viewport: CGSize(width: 240, height: 312),
                                                         style: .rounded, framingScale: 1)
        let rect = CameraFramingGeometry.contentRect(source: CGSize(width: 720, height: 1280),
                                                     viewport: CGSize(width: 240, height: 312),
                                                     style: .rounded, framingScale: 2)
        XCTAssertGreaterThan(rect.width, baseline.width)
        XCTAssertGreaterThan(rect.height, baseline.height)
        let oldTransform = Data(#"{"x":0.5,"y":0.6,"scale":1.4,"rotation":0,"style":"circle"}"#.utf8)
        let decoded = try JSONDecoder().decode(PiPTransform.self, from: oldTransform)
        XCTAssertEqual(decoded.framingScale, 1)
        XCTAssertEqual(decoded.style, .circle)
    }

    @MainActor func testLayoutResetPreservesFramingChoice() {
        let engine = StudioEngine()
        var pip = PiPTransform()
        pip.style = .cutout
        pip.framingScale = 0.7
        pip.x = 0.2
        pip.y = 0.3
        pip.rotation = .pi / 4
        pip.scale = 2
        engine.setPiP(pip)
        XCTAssertEqual(engine.pip.framingScale, 0.7)
        engine.resetPiP()
        XCTAssertEqual(engine.pip.framingScale, 0.7)
        XCTAssertEqual(engine.pip.style, .cutout)
        XCTAssertEqual(engine.pip.scale, 1)
        XCTAssertEqual(engine.pip.x, PiPTransform.defaultTransform.x)
        XCTAssertEqual(engine.pip.y, PiPTransform.defaultTransform.y)
        XCTAssertEqual(engine.pip.rotation, 0)
        engine.close()
    }

    private func assertCoversViewport(_ rect: CGRect, viewport: CGSize,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(rect.minX, 0.001, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.minY, 0.001, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.maxX, viewport.width - 0.001, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.maxY, viewport.height - 0.001, file: file, line: line)
    }
}
