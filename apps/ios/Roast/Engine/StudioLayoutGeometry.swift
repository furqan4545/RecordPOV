import CoreGraphics

enum StudioLayoutGeometry {
    static func splitRects(canvas: CGRect, originalFraction: Double) -> (source: CGRect, camera: CGRect) {
        let ratio = originalFraction.isFinite ? min(0.8, max(0.2, originalFraction)) : 0.7
        let cameraHeight = canvas.height * (1 - ratio)
        return (CGRect(x: canvas.minX, y: canvas.minY + cameraHeight,
                       width: canvas.width, height: canvas.height - cameraHeight),
                CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width, height: cameraHeight))
    }

    /// The divider changes the available pane, never which part of the original
    /// is visible. Center its complete aspect ratio inside that pane.
    static func splitSourceRect(source: CGSize, in pane: CGRect) -> CGRect {
        guard source.width.isFinite, source.height.isFinite,
              source.width > 0, source.height > 0,
              pane.width.isFinite, pane.height.isFinite,
              pane.width > 0, pane.height > 0 else {
            return CGRect(origin: pane.origin, size: .zero)
        }
        let scale = min(pane.width / source.width, pane.height / source.height)
        let width = source.width * scale
        let height = source.height * scale
        return CGRect(x: pane.midX - width / 2, y: pane.midY - height / 2,
                      width: width, height: height)
    }

    static func sourceOverlayRect(canvas: CGRect, sourceAspectRatio: Double,
                                  transform: SourceOverlayTransform) -> CGRect {
        let aspect = sourceAspectRatio.isFinite && sourceAspectRatio > 0 ? sourceAspectRatio : 9.0 / 16
        let scale = transform.scale.isFinite ? min(2.5, max(0.5, transform.scale)) : 1
        let x = transform.x.isFinite ? min(1, max(0, transform.x)) : 0.76
        let y = transform.y.isFinite ? min(1, max(0, transform.y)) : 0.23
        let width = canvas.width * 0.32 * scale
        let height = width / aspect
        return CGRect(x: canvas.minX + canvas.width * x - width / 2,
                      y: canvas.minY + canvas.height * (1 - y) - height / 2,
                      width: width, height: height)
    }
}
