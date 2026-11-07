import XCTest
@testable import Roast

final class OverlayGestureStateTests: XCTestCase {
    private let geometry = OverlayGestureGeometry(canvas: CGSize(width: 400, height: 800),
        content: CGSize(width: 100, height: 130), scaleRange: 0.55...2.5)
    private let initial = OverlayGestureValue(x: 0.5, y: 0.5, scale: 1, rotation: 0)

    private func touch(_ id: Int, _ x: Double, _ y: Double) -> OverlayTouchPoint {
        .init(id: id, location: CGPoint(x: x, y: y))
    }

    func testOneFingerOnlyMovesAndUsesReducedSensitivity() throws {
        var state = OverlayGestureState()
        XCTAssertNil(state.update(touches: [touch(1, 150, 300)], value: initial, geometry: geometry))
        let moved = try XCTUnwrap(state.update(touches: [touch(1, 190, 380)], value: initial, geometry: geometry))
        XCTAssertEqual(moved.x, 0.565, accuracy: 0.000_001)
        XCTAssertEqual(moved.y, 0.565, accuracy: 0.000_001)
        XCTAssertEqual(moved.scale, 1)
        XCTAssertEqual(moved.rotation, 0)
    }

    func testLiftingOneFingerStopsResizeAndRotationAndRebasesDragWithoutAJump() throws {
        var state = OverlayGestureState()
        _ = state.update(touches: [touch(1, 150, 400), touch(2, 250, 400)], value: initial, geometry: geometry)
        let resized = try XCTUnwrap(state.update(touches: [touch(1, 150, 350), touch(2, 250, 450)],
                                                value: initial, geometry: geometry))
        XCTAssertGreaterThan(resized.scale, 1)
        XCTAssertEqual(resized.rotation, .pi / 4 * 0.35, accuracy: 0.000_001)
        // The ended event updates membership before the surviving finger moves.
        XCTAssertNil(state.update(touches: [touch(2, 250, 450)], value: resized, geometry: geometry))
        let dragged = try XCTUnwrap(state.update(touches: [touch(2, 280, 490)], value: resized, geometry: geometry))
        XCTAssertEqual(dragged.x - resized.x, 30 / 400 * 0.65, accuracy: 0.000_001)
        XCTAssertEqual(dragged.y - resized.y, 40 / 800 * 0.65, accuracy: 0.000_001)
        XCTAssertEqual(dragged.scale, resized.scale)
        XCTAssertEqual(dragged.rotation, resized.rotation)
    }

    func testAddingOrReplacingAFingerDoesNotReuseThePreviousPairOrigin() throws {
        var state = OverlayGestureState()
        _ = state.update(touches: [touch(1, 150, 300)], value: initial, geometry: geometry)
        let moved = try XCTUnwrap(state.update(touches: [touch(1, 160, 310)], value: initial, geometry: geometry))
        XCTAssertNil(state.update(touches: [touch(1, 160, 310), touch(2, 300, 500)], value: moved, geometry: geometry))
        XCTAssertNil(state.update(touches: [touch(1, 160, 310), touch(3, 100, 200)], value: moved, geometry: geometry))
        XCTAssertNil(state.update(touches: [touch(3, 100, 200), touch(1, 160, 310)], value: moved, geometry: geometry),
                     "Touch delivery order must not flip the finger pair.")
    }

    func testRotationAcrossTheAngleBoundaryTakesTheShortTurnAtReducedSensitivity() throws {
        var state = OverlayGestureState()
        func pair(_ degrees: Double) -> [OverlayTouchPoint] {
            let angle = degrees * .pi / 180
            return [touch(1, 200, 400), touch(2, 200 + cos(angle) * 80, 400 + sin(angle) * 80)]
        }
        _ = state.update(touches: pair(179), value: initial, geometry: geometry)
        let turned = try XCTUnwrap(state.update(touches: pair(-179), value: initial, geometry: geometry))
        XCTAssertEqual(turned.rotation, 2 * .pi / 180 * 0.35, accuracy: 0.000_001)
    }

    func testPinchIsDampedAndRespectsTheScaleLimit() throws {
        var state = OverlayGestureState()
        _ = state.update(touches: [touch(1, 150, 400), touch(2, 250, 400)], value: initial, geometry: geometry)
        let resized = try XCTUnwrap(state.update(touches: [touch(1, 100, 400), touch(2, 300, 400)], value: initial, geometry: geometry))
        XCTAssertEqual(resized.scale, pow(2, 0.65), accuracy: 0.000_001)
        XCTAssertLessThan(resized.scale, 2)
        let bounded = try XCTUnwrap(state.update(touches: [touch(1, -2_000, 400), touch(2, 2_400, 400)], value: resized, geometry: geometry))
        XCTAssertEqual(bounded.scale, 2.5)
    }

    func testCrossingFingersDoesNotFlipOrExplodeTheOverlay() {
        var state = OverlayGestureState()
        _ = state.update(touches: [touch(1, 150, 400), touch(2, 250, 400)], value: initial, geometry: geometry)
        XCTAssertNil(state.update(touches: [touch(1, 200, 400), touch(2, 200, 400)], value: initial, geometry: geometry))
        XCTAssertNil(state.update(touches: [touch(1, 250, 400), touch(2, 150, 400)], value: initial, geometry: geometry))
    }

    func testACrossingBetweenDeliveredEventsCannotJumpByHalfATurn() {
        var state = OverlayGestureState()
        _ = state.update(touches: [touch(1, 150, 400), touch(2, 250, 400)], value: initial, geometry: geometry)
        XCTAssertNil(state.update(touches: [touch(1, 250, 400), touch(2, 150, 400)], value: initial, geometry: geometry))
        XCTAssertNil(state.update(touches: [touch(2, 150, 400)], value: initial, geometry: geometry))
        let moved = state.update(touches: [touch(2, 160, 400)], value: initial, geometry: geometry)
        XCTAssertEqual(moved?.rotation, 0)
        XCTAssertEqual(moved?.scale, 1)
        XCTAssertGreaterThan(moved?.x ?? 0, initial.x)
    }

    func testRotatedOverlayCannotBeDraggedOutOfTheCanvas() throws {
        var state = OverlayGestureState()
        let rotated = OverlayGestureValue(x: 0.5, y: 0.5, scale: 1, rotation: .pi / 4)
        _ = state.update(touches: [touch(1, 200, 400)], value: rotated, geometry: geometry)
        let bounded = try XCTUnwrap(state.update(touches: [touch(1, 2_000, -2_000)], value: rotated, geometry: geometry))
        let half = (100 + 130) / sqrt(2.0) / 2
        XCTAssertEqual(bounded.x * 400 + half, 400, accuracy: 0.000_001)
        XCTAssertEqual(bounded.y * 800 - half, 0, accuracy: 0.000_001)
        XCTAssertEqual(bounded.scale, rotated.scale)
        XCTAssertEqual(bounded.rotation, rotated.rotation)
    }

    func testCancelAndCanvasResizeDiscardOldTouchOrigins() {
        var state = OverlayGestureState()
        _ = state.update(touches: [touch(1, 150, 400), touch(2, 250, 400)], value: initial, geometry: geometry)
        state.cancel()
        XCTAssertNil(state.update(touches: [touch(3, 10, 10)], value: initial, geometry: geometry))
        let resized = OverlayGestureGeometry(canvas: CGSize(width: 500, height: 900), content: geometry.content, scaleRange: geometry.scaleRange)
        XCTAssertNil(state.update(touches: [touch(3, 100, 100)], value: initial, geometry: resized))
    }

    func testHitTestingUsesRotatedArtworkWithoutRotatingTheCanvasCoordinates() {
        let rotated = OverlayGestureValue(x: 0.5, y: 0.5, scale: 1, rotation: .pi / 2)
        XCTAssertTrue(geometry.contains(CGPoint(x: 250, y: 420), value: rotated))
        XCTAssertFalse(geometry.contains(CGPoint(x: 200, y: 460), value: rotated))
        XCTAssertFalse(geometry.contains(CGPoint(x: 10, y: 10), value: rotated))
    }

    func testInvalidPointsCannotPoisonTheNextGesture() {
        var state = OverlayGestureState()
        _ = state.update(touches: [touch(1, 100, 100)], value: initial, geometry: geometry)
        XCTAssertNil(state.update(touches: [touch(1, .nan, 100)], value: initial, geometry: geometry))
        XCTAssertNil(state.update(touches: [touch(1, 120, 100)], value: initial, geometry: geometry))
    }
}
