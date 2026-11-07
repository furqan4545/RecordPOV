import CoreGraphics
import Foundation

struct OverlayGestureValue: Equatable {
    var x: Double
    var y: Double
    var scale: Double
    var rotation: Double
}

struct OverlayTouchPoint: Equatable {
    let id: Int
    let location: CGPoint
}

struct OverlayGestureGeometry {
    let canvas: CGSize
    /// Overlay size at scale 1, in the same fixed canvas coordinates as touches.
    let content: CGSize
    let scaleRange: ClosedRange<Double>

    func contains(_ point: CGPoint, value: OverlayGestureValue) -> Bool {
        let dx = point.x - canvas.width * value.x
        let dy = point.y - canvas.height * value.y
        let cosine = cos(value.rotation), sine = sin(value.rotation)
        // Undo the artwork's rotation; never rotate the touch coordinate space.
        let localX = dx * cosine + dy * sine
        let localY = -dx * sine + dy * cosine
        return abs(localX) <= max(44, content.width * value.scale) / 2 &&
            abs(localY) <= max(44, content.height * value.scale) / 2
    }

    func keepingVisible(_ value: OverlayGestureValue) -> OverlayGestureValue {
        var next = value
        let cosine = abs(cos(next.rotation)), sine = abs(sin(next.rotation))
        let halfWidth = (content.width * cosine + content.height * sine) * next.scale / 2
        let halfHeight = (content.width * sine + content.height * cosine) * next.scale / 2
        // An intentionally oversized overlay stays centered on an axis that
        // cannot contain it. Keep the chosen size instead of changing it here.
        let horizontalInset = min(0.5, max(0.02, halfWidth / canvas.width))
        let verticalInset = min(0.5, max(0.02, halfHeight / canvas.height))
        next.x = min(1 - horizontalInset, max(horizontalInset, next.x))
        next.y = min(1 - verticalInset, max(verticalInset, next.y))
        return next
    }
}

/// One touch stream owns all three operations. Changing the participating
/// fingers rebases the next move, so a lifted finger can never keep rotating.
struct OverlayGestureState {
    static let dragSensitivity = 0.65
    static let rotationSensitivity = 0.35
    static let pinchSensitivity = 0.65
    private var previous: [OverlayTouchPoint] = []
    private var previousCanvas: CGSize?

    mutating func cancel() { previous = []; previousCanvas = nil }

    mutating func update(touches: [OverlayTouchPoint], value: OverlayGestureValue,
                         geometry: OverlayGestureGeometry) -> OverlayGestureValue? {
        let current = touches.sorted { $0.id < $1.id }
        guard geometry.canvas.width.isFinite, geometry.canvas.height.isFinite,
              geometry.canvas.width > 0, geometry.canvas.height > 0,
              geometry.content.width.isFinite, geometry.content.height.isFinite,
              geometry.content.width > 0, geometry.content.height > 0,
              [value.x, value.y, value.scale, value.rotation].allSatisfy(\.isFinite),
              current.allSatisfy({ $0.location.x.isFinite && $0.location.y.isFinite }),
              Set(current.map(\.id)).count == current.count else { cancel(); return nil }
        defer { previous = current; previousCanvas = geometry.canvas }
        guard previousCanvas == geometry.canvas,
              current.count == 1 || current.count == 2,
              current.map(\.id) == previous.map(\.id) else { return nil }

        let before = centroid(previous), after = centroid(current)
        var next = value
        next.x += (after.x - before.x) / geometry.canvas.width * Self.dragSensitivity
        next.y += (after.y - before.y) / geometry.canvas.height * Self.dragSensitivity

        if current.count == 2 {
            let beforeVector = vector(previous), afterVector = vector(current)
            let beforeDistance = hypot(beforeVector.x, beforeVector.y)
            let afterDistance = hypot(afterVector.x, afterVector.y)
            // Crossing fingers must not create a 180-degree flip or huge zoom.
            if beforeDistance >= 12, afterDistance >= 12 {
                let ratio = afterDistance / beforeDistance
                let difference = atan2(afterVector.y, afterVector.x) - atan2(beforeVector.y, beforeVector.x)
                let shortestTurn = atan2(sin(difference), cos(difference))
                // A pair that crosses between delivered events can stay far
                // apart yet jump by half a turn. Rebase that sample instead of
                // turning or resizing the artwork unexpectedly.
                if abs(shortestTurn) <= .pi / 2 {
                    next.scale *= pow(ratio, Self.pinchSensitivity)
                    next.rotation += shortestTurn * Self.rotationSensitivity
                }
            }
        }
        next.scale = min(geometry.scaleRange.upperBound, max(geometry.scaleRange.lowerBound, next.scale))
        next = geometry.keepingVisible(next)
        return next == value ? nil : next
    }

    private func centroid(_ points: [OverlayTouchPoint]) -> CGPoint {
        CGPoint(x: points.reduce(0) { $0 + $1.location.x } / Double(points.count),
                y: points.reduce(0) { $0 + $1.location.y } / Double(points.count))
    }

    private func vector(_ points: [OverlayTouchPoint]) -> CGPoint {
        CGPoint(x: points[1].location.x - points[0].location.x,
                y: points[1].location.y - points[0].location.y)
    }
}
