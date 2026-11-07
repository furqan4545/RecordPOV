import Foundation

/// Learns only the sensor-crop/output axis relationship, never image orientation.
/// Epochs and first-applied timestamps reject stale mode/lens/frame callbacks.
struct CameraAspectCalibration {
    private(set) var generation = UUID()
    private(set) var requestID = UUID()
    private(set) var axesTransposed: Bool?
    private(set) var firstAppliedTime: Double?
    private var rotation: Double?

    mutating func reset() { self = CameraAspectCalibration() }
    mutating func beginRequest() -> UUID {
        requestID = UUID()
        firstAppliedTime = nil
        return requestID
    }

    @discardableResult
    mutating func applied(at time: Double, generation: UUID, request: UUID) -> Bool {
        guard self.generation == generation, requestID == request, time.isFinite else { return false }
        firstAppliedTime = time
        return true
    }

    @discardableResult
    mutating func observe(width: Int, height: Int, sensorWidth: Int, sensorHeight: Int,
                          frameTime: Double, generation: UUID, request: UUID) -> Bool? {
        guard axesTransposed == nil, self.generation == generation, requestID == request,
              let firstAppliedTime, frameTime.isFinite, frameTime >= firstAppliedTime,
              width > 0, height > 0, sensorWidth > 0, sensorHeight > 0,
              sensorWidth != sensorHeight else { return nil }
        if width == sensorWidth, height == sensorHeight { axesTransposed = false }
        else if width == sensorHeight, height == sensorWidth { axesTransposed = true }
        return axesTransposed
    }

    /// A quarter-turn changes output axes without changing the calibrated crop.
    /// Returns true only when an existing mapping changes.
    @discardableResult
    mutating func updateRotation(_ angle: Double) -> Bool {
        guard angle.isFinite else { return false }
        defer { rotation = angle }
        guard let previous = rotation, let current = axesTransposed else { return false }
        func parity(_ value: Double) -> Int {
            abs(Int((value.truncatingRemainder(dividingBy: 360) / 90).rounded())) % 2
        }
        guard parity(angle) != parity(previous) else { return false }
        axesTransposed = !current
        return true
    }

    func sensorLandscape(forOutputLandscape landscape: Bool) -> Bool {
        landscape != (axesTransposed ?? false)
    }
}
