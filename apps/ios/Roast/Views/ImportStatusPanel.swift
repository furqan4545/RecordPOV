import SwiftUI
import UIKit

/// Status under the import button. It reads the coordinator itself so
/// download progress ticks re-render only this view, not the whole Create screen.
struct ImportStatusPanel: View {
    /// The typed link, used until the import job exists (for example before restoration finishes).
    let link: String
    let onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let importer = VideoImportCoordinator.shared
    /// Keeps the last value while the bar fades out, so it never snaps to empty.
    @State private var shownProgress = 0.0

    var body: some View {
        let progress = importer.progress
        let guidance = ImportGuidance.current(phase: importer.phase)
        // After the download the last step has no percentage, so a moving bar shows it is still working.
        let finishing = importer.phase == .loading && progress == nil
        VStack(alignment: .leading, spacing: 10) {
            // Our own bar (the system ProgressView drew past its frame while fading out).
            ImportProgressBar(progress: progress ?? shownProgress, working: finishing, reduceMotion: reduceMotion)
                .opacity(progress == nil && !finishing ? 0 : 1)
                .animation(.easeInOut(duration: 0.25), value: progress == nil && !finishing)
                .accessibilityElement()
                .accessibilityLabel(finishing ? "Finishing your video" : "Video download")
                .accessibilityValue(finishing ? "" : "\(ImportGuidance.percentValue(progress ?? shownProgress) ?? 0) percent")
                .accessibilityHidden(progress == nil && !finishing)
            HStack(alignment: .center, spacing: 10) {
                // Fades with the bar, so the number is shown only while the bar is.
                Text(ImportGuidance.percentText(progress ?? shownProgress) ?? "0%")
                    .font(.caption.weight(.medium)).monospacedDigit()
                    .foregroundStyle(RoastTheme.muted)
                    .opacity(progress == nil ? 0 : 1)
                    .animation(.easeInOut(duration: 0.25), value: progress == nil)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Button(action: onCancel) {
                    Text("Cancel").font(.caption.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .padding(.leading, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ZStack {
                if let guidance {
                    ImportGuidanceChip(guidance: guidance)
                        .id(guidance.text)
                        .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(.smooth(duration: 0.3), value: guidance)
        }
        .onChange(of: progress) { old, new in
            // Written only when the bar starts fading out, never on each tick.
            if new == nil, let old { shownProgress = old }
        }
        .onChange(of: guidance?.tone) { old, new in
            guard new == .go, old != .go, let text = guidance?.text else { return }
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }
}

/// The import bar: the download (or conversion) percentage, or, while the last step has no
/// percentage, a segment sliding back and forth. Everything is drawn into the bar's own bounds
/// (track first, then the fill clipped to it), so nothing can ever reach past the track.
/// Reduce Motion pulses the working bar in place instead of sliding it.
private struct ImportProgressBar: View {
    let progress: Double
    let working: Bool
    let reduceMotion: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !working)) { context in
            // 0 -> 1 -> 0 every 1.8 s, eased at both ends.
            let phase = (1 - cos(context.date.timeIntervalSinceReferenceDate * .pi / 0.9)) / 2
            Canvas { graphics, size in
                let radius = size.height / 2
                let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius)
                graphics.fill(track, with: .color(RoastTheme.ink.opacity(0.12)))
                graphics.clip(to: track)
                let fill: CGRect
                if working {
                    let width = reduceMotion ? size.width : size.width * 0.32
                    fill = CGRect(x: reduceMotion ? 0 : (size.width - width) * phase, y: 0, width: width, height: size.height)
                } else {
                    fill = CGRect(x: 0, y: 0, width: size.width * min(max(progress, 0), 1), height: size.height)
                }
                graphics.fill(Path(roundedRect: fill, cornerRadius: radius),
                              with: .color(RoastTheme.ink.opacity(working && reduceMotion ? 0.35 + 0.55 * phase : 1)))
            }
        }
        .frame(height: 4)
    }
}

private struct ImportGuidanceChip: View {
    let guidance: ImportGuidance
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: guidance.symbol).font(.system(size: 15, weight: .semibold))
                .frame(width: 18, height: 18).accessibilityHidden(true)
            Text(guidance.text).font(.footnote.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(RoastTheme.ink)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(guidance.tone == .go ? RoastTheme.lime.opacity(0.45) : RoastTheme.paper,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("importProgressMessage")
    }
}
