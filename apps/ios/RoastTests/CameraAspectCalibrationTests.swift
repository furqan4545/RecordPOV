import XCTest
@testable import Roast

final class CameraAspectCalibrationTests: XCTestCase {
    func testOnlyFramesAtOrAfterAppliedTimestampCanCalibrate() {
        var state = CameraAspectCalibration()
        let generation = state.generation
        let request = state.beginRequest()
        XCTAssertTrue(state.applied(at: 100, generation: generation, request: request))
        XCTAssertNil(state.observe(width: 1280, height: 720, sensorWidth: 720, sensorHeight: 1280,
                                   frameTime: 99.999, generation: generation, request: request))
        XCTAssertNil(state.axesTransposed)
        XCTAssertEqual(state.observe(width: 1280, height: 720, sensorWidth: 720, sensorHeight: 1280,
                                     frameTime: 100, generation: generation, request: request), true)
        XCTAssertTrue(state.sensorLandscape(forOutputLandscape: false))
        XCTAssertFalse(state.sensorLandscape(forOutputLandscape: true))
    }

    func testRetiredCameraCannotApplyOrCalibrateANewSelection() {
        var state = CameraAspectCalibration()
        let retiredGeneration = state.generation
        let retiredRequest = state.beginRequest()
        state.reset()
        let currentRequest = state.beginRequest()
        XCTAssertFalse(state.applied(at: 100, generation: retiredGeneration, request: retiredRequest))
        XCTAssertTrue(state.applied(at: 200, generation: state.generation, request: currentRequest))
        XCTAssertNil(state.observe(width: 1280, height: 720, sensorWidth: 720, sensorHeight: 1280,
                                   frameTime: 201, generation: retiredGeneration, request: retiredRequest))
        XCTAssertEqual(state.observe(width: 720, height: 1280, sensorWidth: 720, sensorHeight: 1280,
                                     frameTime: 201, generation: state.generation, request: currentRequest), false)
    }

    func testOldModeCallbacksAreRejectedAndMappingCannotLearnTwice() {
        var state = CameraAspectCalibration()
        let generation = state.generation
        let oldRequest = state.beginRequest()
        let currentRequest = state.beginRequest()
        XCTAssertFalse(state.applied(at: 100, generation: generation, request: oldRequest))
        XCTAssertTrue(state.applied(at: 101, generation: generation, request: currentRequest))
        XCTAssertNil(state.observe(width: 720, height: 1280, sensorWidth: 720, sensorHeight: 1280,
                                   frameTime: 102, generation: generation, request: oldRequest))
        XCTAssertEqual(state.observe(width: 1280, height: 720, sensorWidth: 720, sensorHeight: 1280,
                                     frameTime: 102, generation: generation, request: currentRequest), true)
        let next = state.beginRequest()
        state.applied(at: 103, generation: generation, request: next)
        XCTAssertNil(state.observe(width: 1280, height: 720, sensorWidth: 1280, sensorHeight: 720,
                                   frameTime: 104, generation: generation, request: next))
        XCTAssertEqual(state.axesTransposed, true, "Corrected-mode frames must not invert the mapping again.")
    }

    func testRotationChangesAxesWithoutChangingTheRecordedOrientationPolicy() {
        var state = CameraAspectCalibration()
        state.updateRotation(0)
        let request = state.beginRequest()
        state.applied(at: 1, generation: state.generation, request: request)
        state.observe(width: 1280, height: 720, sensorWidth: 720, sensorHeight: 1280,
                      frameTime: 2, generation: state.generation, request: request)
        XCTAssertTrue(state.updateRotation(90))
        XCTAssertEqual(state.axesTransposed, false)
        XCTAssertTrue(state.updateRotation(180))
        XCTAssertEqual(state.axesTransposed, true)
        XCTAssertFalse(state.updateRotation(180))
        XCTAssertEqual(state.axesTransposed, true)
    }

    func testInvalidOrSquareMetadataCannotGuessAnAxisMapping() {
        var state = CameraAspectCalibration()
        let request = state.beginRequest()
        XCTAssertFalse(state.applied(at: .nan, generation: state.generation, request: request))
        state.applied(at: 1, generation: state.generation, request: request)
        XCTAssertNil(state.observe(width: 1280, height: 1280, sensorWidth: 1280, sensorHeight: 1280,
                                   frameTime: 2, generation: state.generation, request: request))
        XCTAssertNil(state.observe(width: 0, height: 0, sensorWidth: 720, sensorHeight: 1280,
                                   frameTime: 2, generation: state.generation, request: request))
        XCTAssertNil(state.observe(width: 1280, height: 720, sensorWidth: 720, sensorHeight: 1280,
                                   frameTime: .nan, generation: state.generation, request: request))
        XCTAssertNil(state.axesTransposed)
    }

    func testIncrementalRotationAndFullTurnWrapUseAbsoluteQuarterTurnParity() {
        var state = CameraAspectCalibration()
        state.updateRotation(0)
        let request = state.beginRequest()
        state.applied(at: 1, generation: state.generation, request: request)
        state.observe(width: 1280, height: 720, sensorWidth: 720, sensorHeight: 1280,
                      frameTime: 2, generation: state.generation, request: request)
        XCTAssertFalse(state.updateRotation(30))
        XCTAssertTrue(state.updateRotation(60))
        XCTAssertFalse(state.updateRotation(90))
        XCTAssertEqual(state.axesTransposed, false)
        XCTAssertTrue(state.updateRotation(360))
        XCTAssertFalse(state.updateRotation(0))
        XCTAssertEqual(state.axesTransposed, true)
        XCTAssertTrue(state.updateRotation(-90))
        XCTAssertFalse(state.updateRotation(270))
        XCTAssertEqual(state.axesTransposed, false)
    }
}
