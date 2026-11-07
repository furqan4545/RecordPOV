import SwiftUI
import UIKit

/// A transparent canvas-sized input surface, hit-tested only over the artwork.
/// Its coordinate system stays fixed while the artwork moves, turns or scales.
struct OverlayTouchSurface: UIViewRepresentable {
    let geometry: OverlayGestureGeometry
    let currentValue: () -> OverlayGestureValue
    let onChanged: (OverlayGestureValue) -> Void

    func makeUIView(context: Context) -> OverlayTouchView {
        let view = OverlayTouchView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: OverlayTouchView, context: Context) {
        view.geometry = geometry
        view.currentValue = currentValue
        view.onChanged = onChanged
    }

    static func dismantleUIView(_ view: OverlayTouchView, coordinator: ()) {
        view.cancelTouches()
        view.currentValue = nil
        view.onChanged = nil
    }
}

final class OverlayTouchView: UIView {
    var geometry: OverlayGestureGeometry?
    var currentValue: (() -> OverlayGestureValue)?
    var onChanged: ((OverlayGestureValue) -> Void)?
    private var nextTouchID = 0
    private var active: [ObjectIdentifier: (id: Int, touch: UITouch)] = [:]
    private var gesture = OverlayGestureState()

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard bounds.contains(point), let geometry, let value = currentValue?() else { return false }
        // A second finger can join just outside the artwork without losing the
        // active gesture. Other controls above this surface retain precedence.
        return !active.isEmpty || geometry.contains(point, value: value)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard active[key] == nil else { continue }
            nextTouchID += 1
            active[key] = (nextTouchID, touch)
        }
        publishMove()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        publishMove()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { active.removeValue(forKey: ObjectIdentifier(touch)) }
        // Update membership now, rather than waiting for another move. One
        // remaining finger immediately becomes drag-only with a fresh origin.
        publishMove()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelTouches() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelTouches() }
    }

    func cancelTouches() {
        active.removeAll()
        gesture.cancel()
    }

    private func publishMove() {
        guard let geometry, let value = currentValue?() else { cancelTouches(); return }
        let points = active.values.map { OverlayTouchPoint(id: $0.id, location: $0.touch.location(in: self)) }
        if let updated = gesture.update(touches: points, value: value, geometry: geometry) { onChanged?(updated) }
    }
}
