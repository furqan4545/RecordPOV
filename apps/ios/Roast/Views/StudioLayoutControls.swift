import SwiftUI

struct SplitDivider: View {
    let engine: StudioEngine
    let size: CGSize
    @State private var startRatio: Double?

    private var originalPercent: Int { Int((engine.pip.splitRatio * 100).rounded()) }

    var body: some View {
        HStack(spacing: 10) {
            Text("Original \(originalPercent)%")
                .padding(.horizontal, 8).padding(.vertical, 5).background(.black.opacity(0.4), in: Capsule())
            Spacer(minLength: 0)
            Capsule().fill(.white).frame(width: 38, height: 4)
                .padding(.horizontal, 12).frame(height: 26).background(.black.opacity(0.45), in: Capsule())
            Spacer(minLength: 0)
            Text("You \(100 - originalPercent)%")
                .padding(.horizontal, 8).padding(.vertical, 5).background(.black.opacity(0.4), in: Capsule())
        }
        .font(.system(size: 9, weight: .medium)).monospacedDigit().foregroundStyle(.white)
        .padding(.horizontal, 10).frame(width: size.width, height: 44).contentShape(Rectangle())
        .position(x: size.width / 2, y: size.height * engine.pip.splitRatio)
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("studioCanvas"))
            .onChanged { value in
                if startRatio == nil { startRatio = engine.pip.splitRatio }
                var pip = engine.pip
                pip.splitRatio = min(0.8, max(0.2, (startRatio ?? 0.7) + value.translation.height / size.height * 0.65))
                engine.setPiP(pip)
            }.onEnded { _ in startRatio = nil })
        .accessibilityElement(children: .ignore).accessibilityLabel("Split screen divider")
        .accessibilityValue("\(originalPercent) percent original, \(100 - originalPercent) percent you")
        .accessibilityHint("Drag up or down to change how much space each video uses.")
        .accessibilityAdjustableAction { direction in
            var pip = engine.pip
            pip.splitRatio += direction == .increment ? 0.05 : -0.05
            engine.setPiP(pip)
        }
        .accessibilityIdentifier("splitScreenDivider")
    }
}

struct SourceOverlayInteractionLayer: View {
    let engine: StudioEngine
    let size: CGSize

    var body: some View {
        let transform = engine.pip.sourceOverlay
        let rect = StudioLayoutGeometry.sourceOverlayRect(canvas: CGRect(origin: .zero, size: size),
            sourceAspectRatio: engine.sourceAspectRatio, transform: transform)
        let scale = transform.scale.isFinite ? min(2.5, max(0.5, transform.scale)) : 1
        let content = CGSize(width: rect.width / scale, height: rect.height / scale)
        ZStack {
            OverlayTouchSurface(
                geometry: .init(canvas: size, content: content, scaleRange: 0.5...2.5),
                currentValue: {
                    let value = engine.pip.sourceOverlay
                    return .init(x: value.x, y: value.y, scale: value.scale, rotation: value.rotation)
                }, onChanged: { value in
                    var pip = engine.pip
                    pip.sourceOverlay.x = value.x; pip.sourceOverlay.y = value.y
                    pip.sourceOverlay.scale = value.scale; pip.sourceOverlay.rotation = value.rotation
                    engine.setPiP(pip)
                })
            Color.clear.frame(width: max(44, rect.width), height: max(44, rect.height))
                .rotationEffect(.radians(transform.rotation))
                .position(x: rect.midX, y: size.height - rect.midY)
                .allowsHitTesting(false)
                .accessibilityElement().accessibilityLabel("Original video overlay")
                .accessibilityHint("Move with one finger. Resize and turn with two fingers.")
                .accessibilityAdjustableAction { direction in
                    var pip = engine.pip
                    pip.sourceOverlay.scale += direction == .increment ? 0.1 : -0.1
                    engine.setPiP(pip)
                }
                .accessibilityAction(named: "Reset original overlay") {
                    var pip = engine.pip; pip.sourceOverlay = SourceOverlayTransform(); engine.setPiP(pip)
                }
                .accessibilityIdentifier("sourceVideoOverlay")
        }.frame(width: size.width, height: size.height)
    }
}
