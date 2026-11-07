import SwiftUI
import UIKit

/// A source-clock range selector. Moving a handle changes only its binding;
/// the owner validates the kept duration and rebuilds once interaction ends.
struct EditorTimelineView: View {
    let videoURL: URL
    let duration: Double
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let sourcePosition: Double
    let interactionBegan: () -> Void
    let seek: (Double) -> Void
    let interactionEnded: () -> Void

    @State private var zoom = 1.0
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var scrollOffset: CGFloat = 0
    @State private var scrolling = false
    @State private var activeHandle: Handle?
    @State private var gestureOrigin = 0.0
    @State private var dragPosition: Double?
    @State private var isDraggingPlayhead = false

    private enum Handle { case start, end }
    private let sidePadding: CGFloat = 24
    private let stripHeight: CGFloat = 64
    private let rulerHeight: CGFloat = 20

    init(videoURL: URL, duration: Double, trimStart: Binding<Double>, trimEnd: Binding<Double>,
         cuts: [EditInterval] = [], sourcePosition: Double, splitMarkers: [Double] = [],
         selectedSegment: EditInterval? = nil, onSelectSegment: @escaping (EditInterval) -> Void = { _ in },
         interactionBegan: @escaping () -> Void, seek: @escaping (Double) -> Void,
         interactionEnded: @escaping () -> Void) {
        self.videoURL = videoURL
        self.duration = duration
        _trimStart = trimStart
        _trimEnd = trimEnd
        self.sourcePosition = sourcePosition
        self.interactionBegan = interactionBegan
        self.seek = seek
        self.interactionEnded = interactionEnded
    }

    private var total: Double { duration.isFinite ? max(0.01, duration) : 0.01 }
    private var minimum: Double { min(0.2, total) }
    private var current: Double { bounded(dragPosition ?? sourcePosition) }

    var body: some View {
        GeometryReader { geometry in
            let viewport = max(100, geometry.size.width)
            let baseWidth = max(52, viewport - sidePadding * 2)
            let trackWidth = baseWidth * zoom
            let pointsPerSecond = trackWidth / total
            let maxZoom = max(4, min(512, total * 100 / baseWidth))
            VStack(spacing: 4) {
                header(maxZoom: maxZoom)
                ScrollView(.horizontal, showsIndicators: false) {
                    track(width: trackWidth, pointsPerSecond: pointsPerSecond, viewport: viewport)
                        .frame(width: trackWidth + sidePadding * 2, height: 104)
                }
                .scrollPosition($scrollPosition)
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, offset in
                    scrollOffset = offset
                }
                .onScrollPhaseChange { _, phase in scrolling = phase != .idle }
                .onChange(of: sourcePosition) { _, position in
                    guard zoom > 1, !scrolling, activeHandle == nil, !isDraggingPlayhead else { return }
                    reveal(position, viewport: viewport, trackWidth: trackWidth)
                }
                .onChange(of: zoom) { _, _ in
                    reveal(current, viewport: viewport, trackWidth: trackWidth)
                }
                HStack {
                    Text("Start \(timeLabel(trimStart))")
                    Spacer(minLength: 8)
                    Text("End \(timeLabel(trimEnd))")
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(RoastTheme.muted).monospacedDigit()
            }
        }
        .frame(height: 168)
        .accessibilityIdentifier("editorThumbnailTimeline")
    }

    private func header(maxZoom: Double) -> some View {
        HStack(spacing: 2) {
            Text(timeLabel(current)).font(.system(size: 14, weight: .semibold, design: .monospaced))
                .monospacedDigit().accessibilityLabel("Playhead \(timeLabel(current))")
            Spacer(minLength: 4)
            Button { zoom = max(1, zoom / 2) } label: {
                Image(systemName: "minus.magnifyingglass").frame(width: 44, height: 44)
            }.disabled(zoom <= 1).accessibilityLabel("Zoom out timeline")
            Text(zoom == 1 ? "Fit" : "\(Int(zoom))×").font(.system(size: 11, weight: .medium))
                .foregroundStyle(RoastTheme.muted).frame(minWidth: 26)
            Button { zoom = min(maxZoom, zoom * 2) } label: {
                Image(systemName: "plus.magnifyingglass").frame(width: 44, height: 44)
            }.disabled(zoom >= maxZoom).accessibilityLabel("Zoom in timeline")
        }
        .buttonStyle(.plain).foregroundStyle(RoastTheme.ink)
    }

    private func track(width: CGFloat, pointsPerSecond: CGFloat, viewport: CGFloat) -> some View {
        let count = max(1, Int(ceil(width / 44)))
        let cellWidth = width / CGFloat(count)
        let startX = sidePadding + bounded(trimStart) * pointsPerSecond
        let endX = sidePadding + bounded(trimEnd) * pointsPerSecond
        let cursorX = sidePadding + current * pointsPerSecond
        return ZStack(alignment: .topLeading) {
            ruler(width: width, pointsPerSecond: pointsPerSecond, viewport: viewport)
                .offset(x: sidePadding)
            LazyHStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    TimelineThumbnail(videoURL: videoURL,
                        time: min(max(0, total - 0.05), (Double(index) + 0.5) * total / Double(count)))
                        .frame(width: cellWidth, height: stripHeight).clipped()
                }
            }
            .frame(width: width, height: stripHeight).background(RoastTheme.ink)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .offset(x: sidePadding, y: rulerHeight)
            Rectangle().fill(RoastTheme.paper.opacity(0.75))
                .frame(width: max(0, startX - sidePadding), height: stripHeight)
                .offset(x: sidePadding, y: rulerHeight).allowsHitTesting(false)
            Rectangle().fill(RoastTheme.paper.opacity(0.75))
                .frame(width: max(0, sidePadding + width - endX), height: stripHeight)
                .offset(x: endX, y: rulerHeight).allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 5).stroke(RoastTheme.ink, lineWidth: 2)
                .frame(width: max(1, endX - startX), height: stripHeight)
                .offset(x: startX, y: rulerHeight).allowsHitTesting(false)

            TimelineGestureSurface(panEnabled: zoom <= 1, began: { point in
                gestureOrigin = bounded((point.x - sidePadding) / pointsPerSecond)
                isDraggingPlayhead = true
                interactionBegan()
                updateSeek(gestureOrigin)
            }, changed: { translation in
                updateSeek(gestureOrigin + translation.width / pointsPerSecond)
            }, ended: endInteraction, tapped: { point in
                interactionBegan()
                updateSeek((point.x - sidePadding) / pointsPerSecond)
                endInteraction()
            })
            .frame(width: width + sidePadding * 2, height: stripHeight + rulerHeight)
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3).fill(RoastTheme.ink).frame(width: 10, height: 8)
                Rectangle().fill(.white).frame(width: 2, height: stripHeight + 10)
                    .shadow(color: .black.opacity(0.4), radius: 1)
            }
            .frame(width: 44, height: 94)
            .position(x: cursorX, y: rulerHeight + stripHeight / 2)
            .allowsHitTesting(false).accessibilityHidden(true)
            TimelineGestureSurface(began: { _ in
                gestureOrigin = current
                isDraggingPlayhead = true
                interactionBegan()
            }, changed: { translation in
                updateSeek(gestureOrigin + translation.width / pointsPerSecond)
            }, ended: endInteraction)
            .frame(width: 44, height: 94).position(x: cursorX, y: rulerHeight + stripHeight / 2)
            .accessibilityElement(children: .ignore).accessibilityLabel("Video playhead")
            .accessibilityValue(timeLabel(current))
            .accessibilityAdjustableAction { direction in
                adjustPlayhead(direction == .increment ? 0.1 : -0.1)
            }

            handleVisual(.start).position(x: startX, y: rulerHeight + stripHeight / 2)
            handleVisual(.end).position(x: endX, y: rulerHeight + stripHeight / 2)
            TimelineGestureSurface(hitZones: [
                CGRect(x: startX - 22, y: 0, width: 44, height: 100),
                CGRect(x: endX - 22, y: 0, width: 44, height: 100)
            ], began: { point in
                let handle: Handle = abs(point.x - startX) <= abs(point.x - endX) ? .start : .end
                activeHandle = handle
                gestureOrigin = handle == .start ? trimStart : trimEnd
                interactionBegan()
            }, changed: { translation in
                guard let handle = activeHandle else { return }
                updateHandle(handle, proposed: gestureOrigin + translation.width / pointsPerSecond)
            }, ended: endInteraction, tapped: { point in
                interactionBegan()
                updateSeek(abs(point.x - startX) <= abs(point.x - endX) ? trimStart : trimEnd)
                endInteraction()
            })
            .frame(width: width + sidePadding * 2, height: 100).accessibilityHidden(true)
        }
    }

    private func ruler(width: CGFloat, pointsPerSecond: CGFloat, viewport: CGFloat) -> some View {
        let desired = 56 / pointsPerSecond
        let step = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600].first { $0 >= desired } ?? 600
        let first = max(0, Int(max(0, scrollOffset - sidePadding) / pointsPerSecond / step) - 1)
        let last = min(Int(total / step) + 1, first + Int(ceil(viewport / pointsPerSecond / step)) + 4)
        return ZStack(alignment: .topLeading) {
            ForEach(first..<max(first, last), id: \.self) { index in
                let seconds = Double(index) * step
                Text(timeLabel(seconds, precision: step < 1))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(RoastTheme.muted)
                    .fixedSize().offset(x: seconds * pointsPerSecond - 12, y: 1)
            }
        }.frame(width: width, height: rulerHeight, alignment: .topLeading)
            .allowsHitTesting(false).accessibilityHidden(true)
    }

    private func handleVisual(_ handle: Handle) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(RoastTheme.lime)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(RoastTheme.ink, lineWidth: 1))
            .overlay(Capsule().fill(RoastTheme.ink).frame(width: 2, height: 20))
            .frame(width: 12, height: stripHeight + 4)
            .frame(width: 44, height: 94)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(handle == .start ? "Trim start" : "Trim end")
            .accessibilityValue(timeLabel(handle == .start ? trimStart : trimEnd))
            .accessibilityAdjustableAction { direction in
                interactionBegan()
                let value = handle == .start ? trimStart : trimEnd
                updateHandle(handle, proposed: value + (direction == .increment ? 0.1 : -0.1))
                endInteraction()
            }
            .accessibilityIdentifier(handle == .start ? "timelineTrimStart" : "timelineTrimEnd")
    }

    private func updateHandle(_ handle: Handle, proposed: Double) {
        switch handle {
        case .start: trimStart = min(max(0, proposed), max(0, trimEnd - minimum))
        case .end: trimEnd = max(min(total, proposed), min(total, trimStart + minimum))
        }
        updateSeek(handle == .start ? trimStart : trimEnd)
    }

    private func updateSeek(_ value: Double) {
        let value = bounded(value)
        dragPosition = value
        seek(value)
    }

    private func adjustPlayhead(_ amount: Double) {
        interactionBegan()
        updateSeek(current + amount)
        endInteraction()
    }

    private func endInteraction() {
        activeHandle = nil
        isDraggingPlayhead = false
        dragPosition = nil
        interactionEnded()
    }

    private func reveal(_ seconds: Double, viewport: CGFloat, trackWidth: CGFloat) {
        let offset = sidePadding + bounded(seconds) / total * trackWidth - viewport / 2
        scrollPosition.scrollTo(x: min(max(0, trackWidth + sidePadding * 2 - viewport), max(0, offset)))
    }

    private func bounded(_ value: Double) -> Double { min(total, max(0, value.isFinite ? value : 0)) }
    private func timeLabel(_ seconds: Double, precision: Bool = true) -> String {
        let hundredths = Int((bounded(seconds) * 100).rounded())
        let base = String(format: "%d:%02d", hundredths / 6_000, hundredths / 100 % 60)
        return precision ? base + String(format: ".%02d", hundredths % 100) : base
    }
}

private struct TimelineThumbnail: View {
    let videoURL: URL
    let time: Double
    @State private var image: UIImage?
    private struct Request: Equatable { let url: URL; let time: Double }
    var body: some View {
        ZStack {
            RoastTheme.ink.opacity(0.85)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "film").font(.caption).foregroundStyle(.white.opacity(0.3)) }
        }
        .task(id: Request(url: videoURL, time: time)) {
            image = await TimelineThumbnailLoader.shared.thumbnail(videoURL: videoURL, at: time)
        }
        .accessibilityHidden(true)
    }
}

/// Native directional recognition lets vertical drags reach the editor's parent
/// scroll view. Handle gestures take precedence over the horizontal filmstrip.
private struct TimelineGestureSurface: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    var panEnabled = true
    var hitZones: [CGRect]?
    var began: (CGPoint) -> Void
    var changed: (CGSize) -> Void
    var ended: () -> Void
    var tapped: ((CGPoint) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        view.pan.delegate = context.coordinator
        view.addGestureRecognizer(view.pan)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: view.pan)
        view.addGestureRecognizer(tap)
        return view
    }
    func updateUIView(_ view: Surface, context: Context) {
        context.coordinator.parent = self
        let panEnabled = panEnabled && isEnabled
        if view.pan.isEnabled != panEnabled { view.pan.isEnabled = panEnabled }
        view.isUserInteractionEnabled = isEnabled
        view.hitZones = hitZones
    }

    final class Surface: UIView {
        var pan: UIPanGestureRecognizer!
        var hitZones: [CGRect]?
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            if let hitZones { return hitZones.contains { $0.contains(point) } }
            return super.point(inside: point, with: event)
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { scroll.panGestureRecognizer.require(toFail: pan); break }
                ancestor = view.superview
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TimelineGestureSurface
        private var active = false
        init(_ parent: TimelineGestureSurface) { self.parent = parent }
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view?.window)
            return abs(velocity.x) >= abs(velocity.y)
        }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let movement = gesture.translation(in: gesture.view?.window)
            switch gesture.state {
            case .began:
                active = true
                let point = gesture.location(in: gesture.view)
                parent.began(CGPoint(x: point.x - movement.x, y: point.y - movement.y))
                parent.changed(CGSize(width: movement.x, height: movement.y))
            case .changed: if active { parent.changed(CGSize(width: movement.x, height: movement.y)) }
            case .ended, .cancelled, .failed:
                if active { active = false; parent.ended() }
            default: break
            }
        }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended { parent.tapped?(gesture.location(in: gesture.view)) }
        }
    }
}
