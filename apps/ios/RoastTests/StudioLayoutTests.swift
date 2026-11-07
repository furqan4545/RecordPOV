import XCTest
@testable import Roast

final class StudioLayoutTests: XCTestCase {
    func testSeventyThirtySplitPlacesOriginalOnTopWithoutGaps() {
        let canvas = CGRect(x: 0, y: 0, width: 720, height: 1280)
        let areas = StudioLayoutGeometry.splitRects(canvas: canvas, originalFraction: 0.7)
        XCTAssertEqual(areas.source.height, 896, accuracy: 0.001)
        XCTAssertEqual(areas.camera.height, 384, accuracy: 0.001)
        XCTAssertEqual(areas.source.minY, areas.camera.maxY, accuracy: 0.001)
        XCTAssertEqual(areas.source.maxY, canvas.maxY)
        XCTAssertEqual(areas.camera.minY, canvas.minY)
        XCTAssertEqual(areas.source.union(areas.camera), canvas)
    }

    func testSplitRatioClampsAndKeepsEachPanelUsable() {
        let canvas = CGRect(x: 14, y: 20, width: 360, height: 640)
        for ratio in [-5.0, 0.2, 0.3, 0.5, 0.8, 5, .nan] {
            let areas = StudioLayoutGeometry.splitRects(canvas: canvas, originalFraction: ratio)
            XCTAssertGreaterThanOrEqual(areas.source.height, canvas.height * 0.2 - 0.001)
            XCTAssertGreaterThanOrEqual(areas.camera.height, canvas.height * 0.2 - 0.001)
            XCTAssertEqual(areas.source.union(areas.camera), canvas)
        }
    }

    func testOriginalOverlayKeepsPortraitAndLandscapeAspectRatios() {
        let canvas = CGRect(x: 0, y: 0, width: 720, height: 1280)
        for aspect in [9.0 / 16, 16.0 / 9, 1] {
            let rect = StudioLayoutGeometry.sourceOverlayRect(canvas: canvas,
                sourceAspectRatio: aspect, transform: SourceOverlayTransform())
            XCTAssertEqual(rect.width / rect.height, aspect, accuracy: 0.001)
            XCTAssertEqual(rect.midX, canvas.width * 0.76, accuracy: 0.001)
            XCTAssertEqual(rect.midY, canvas.height * 0.77, accuracy: 0.001)
        }
    }

    func testInitialCameraStyleIsCutoutAndExplicitLegacyChoicesRemain() throws {
        XCTAssertEqual(PiPTransform().style, .cutout)
        let old = try JSONDecoder().decode(PiPTransform.self, from: Data(#"{"style":"square","x":0.3}"#.utf8))
        XCTAssertEqual(old.style, .square)
        XCTAssertEqual(old.x, 0.3)
        XCTAssertEqual(old.layout, .pip)
        XCTAssertFalse(old.isFullScreen)
        XCTAssertEqual(old.splitRatio, 0.7)
    }

    @MainActor func testFullScreenToggleRestoresEveryLayoutAndOverlayChoice() {
        let engine = StudioEngine()
        defer { engine.close() }
        for layout in StudioLayout.allCases {
            var pip = PiPTransform(x: 0.21, y: 0.64, scale: 1.8, rotation: 0.27, style: .circle,
                                   framingScale: 1.3, isFullScreen: false, layout: layout, splitRatio: 0.72)
            pip.sourceOverlay = SourceOverlayTransform(x: 0.81, y: 0.12, scale: 0.7, rotation: -0.18)
            engine.setPiP(pip)
            pip = engine.pip
            engine.isCameraEnabled = true
            engine.toggleCameraFullScreen()
            XCTAssertTrue(engine.pip.isFullScreen)
            engine.toggleCameraFullScreen()
            XCTAssertEqual(engine.pip, pip)
            engine.isCameraEnabled = false
            engine.toggleCameraFullScreen()
            XCTAssertEqual(engine.pip, pip)
        }
    }

    @MainActor func testCutoutReturnsAsRoundedAfterSplitWithoutResettingPlacement() {
        let engine = StudioEngine()
        defer { engine.close() }
        var choice = engine.pip
        XCTAssertEqual(choice.style, .cutout)
        choice.x = 0.3
        choice.scale = 1.2
        engine.setPiP(choice)
        XCTAssertEqual(engine.pip.style, .cutout)
        choice.layout = .split
        engine.setPiP(choice)
        XCTAssertEqual(engine.pip.style, .rounded)
        choice = engine.pip
        choice.layout = .pip
        engine.setPiP(choice)
        XCTAssertEqual(engine.pip.style, .rounded)
        XCTAssertEqual(engine.pip.x, 0.3)
        XCTAssertEqual(engine.pip.scale, 1.2)
        choice.layout = .split
        choice.style = .cutout
        engine.setPiP(choice)
        choice = engine.pip
        choice.style = .cutout
        engine.setPiP(choice)
        XCTAssertEqual(engine.pip.style, .cutout)
        choice.layout = .pip
        engine.setPiP(choice)
        XCTAssertEqual(engine.pip.style, .rounded)
    }

    @MainActor func testLayoutChangesPreserveOtherExplicitCameraShapes() {
        let engine = StudioEngine()
        defer { engine.close() }
        for style in [PiPStyle.rounded, .circle, .square] {
            var choice = engine.pip
            choice.style = style
            engine.setPiP(choice)
            for layout in [StudioLayout.split, .cameraMain, .pip] {
                choice = engine.pip
                choice.layout = layout
                engine.setPiP(choice)
                XCTAssertEqual(engine.pip.style, style)
            }
        }
    }

    @MainActor func testDefaultCameraSkipsUnavailableHardwareWithoutAnError() async {
        let engine = StudioEngine()
        defer { engine.close() }
        engine.cameraAvailable = false
        await engine.startDefaultCameraIfNeeded()
        XCTAssertFalse(engine.isCameraEnabled)
        XCTAssertNil(engine.errorMessage)
        XCTAssertEqual(engine.pip.style, .cutout)
    }

    @MainActor func testAnExplicitCameraOffDecisionPreventsLateDefaultActivation() async {
        let engine = StudioEngine()
        defer { engine.close() }
        engine.disableCamera()
        await Task.yield()
        await engine.startDefaultCameraIfNeeded()
        XCTAssertFalse(engine.isCameraEnabled)
        XCTAssertNil(engine.errorMessage)
    }

    @MainActor func testInvalidLayoutTransformValuesCannotEscapeBounds() {
        let engine = StudioEngine()
        defer { engine.close() }
        var pip = PiPTransform()
        pip.splitRatio = 100
        pip.sourceOverlay = SourceOverlayTransform(x: -10, y: 10, scale: 99, rotation: .nan)
        engine.setPiP(pip)
        XCTAssertEqual(engine.pip.splitRatio, 0.8)
        XCTAssertEqual(engine.pip.sourceOverlay.x, 0)
        XCTAssertEqual(engine.pip.sourceOverlay.y, 1)
        XCTAssertEqual(engine.pip.sourceOverlay.scale, 2.5)
        XCTAssertEqual(engine.pip.sourceOverlay.rotation, 0)
    }
}
