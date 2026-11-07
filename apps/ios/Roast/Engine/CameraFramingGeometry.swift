import CoreGraphics

/// Camera framing is independent of the size and position of the PiP itself.
enum CameraFramingGeometry {
    static func contentRect(source: CGSize, viewport: CGSize, style: PiPStyle,
                            framingScale: Double) -> CGRect {
        guard source.width.isFinite, source.height.isFinite,
              viewport.width.isFinite, viewport.height.isFinite,
              source.width > 0, source.height > 0,
              viewport.width > 0, viewport.height > 0 else { return .zero }
        let isCutout = style == .cutout
        let fitScale = isCutout
            ? min(viewport.width / source.width, viewport.height / source.height)
            : max(viewport.width / source.width, viewport.height / source.height)
        // Framed cameras cover their complete shape at the widest setting.
        // Cutout keeps transparent space around the fitted person as needed.
        let minimum = isCutout ? 0.55 : 1.0
        let zoom = framingScale.isFinite ? min(2.5, max(minimum, framingScale)) : 1
        let size = CGSize(width: source.width * fitScale * zoom,
                          height: source.height * fitScale * zoom)
        return CGRect(x: (viewport.width - size.width) / 2,
                      y: (viewport.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}
