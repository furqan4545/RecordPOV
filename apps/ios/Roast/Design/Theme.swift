import SwiftUI
import UIKit

enum RoastTheme {
    static let paper = Color(red: 0.969, green: 0.961, blue: 0.941)
    static let ink = Color(red: 0.125, green: 0.137, blue: 0.149)
    static let lime = Color(red: 0.867, green: 0.988, blue: 0.404)
    static let muted = Color(red: 0.43, green: 0.44, blue: 0.42)

    @MainActor static func exampleImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 720, height: 1280))
        return renderer.image { context in
            UIColor(red: 0.90, green: 0.89, blue: 0.85, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 720, height: 1280))
            UIColor.white.withAlphaComponent(0.8).setFill()
            UIBezierPath(roundedRect: CGRect(x: 48, y: 130, width: 624, height: 760), cornerRadius: 32).fill()
            let title = "Example\nvideo"
            title.draw(in: CGRect(x: 92, y: 220, width: 540, height: 300), withAttributes: [
                .font: UIFont.systemFont(ofSize: 78, weight: .bold),
                .foregroundColor: UIColor(RoastTheme.ink)
            ])
            "Add your camera to record a reaction.".draw(in: CGRect(x: 94, y: 565, width: 490, height: 110), withAttributes: [
                .font: UIFont.systemFont(ofSize: 31, weight: .medium),
                .foregroundColor: UIColor.darkGray
            ])
            UIColor(RoastTheme.lime).setFill()
            UIBezierPath(roundedRect: CGRect(x: 92, y: 726, width: 190, height: 58), cornerRadius: 29).fill()
            "RECORDPOV".draw(at: CGPoint(x: 114, y: 743), withAttributes: [
                .font: UIFont.systemFont(ofSize: 20, weight: .bold),
                .foregroundColor: UIColor(RoastTheme.ink)
            ])
        }
    }
}

struct BrandMark: View {
    var size: CGFloat = 34
    var body: some View {
        Image("RecordPOVMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct PrimaryButton: View {
    let title: String
    var symbol: String = "arrow.up.right"
    var isLoading = false
    /// Shows the spinner where the symbol sits (right side) instead of before the title.
    var spinnerAtTrailing = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading && !spinnerAtTrailing { ProgressView().tint(RoastTheme.ink) }
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                if isLoading && spinnerAtTrailing { ProgressView().tint(RoastTheme.ink) }
                else if !isLoading { Image(systemName: symbol).font(.system(size: 14, weight: .semibold)) }
            }
            .padding(.horizontal, 16).frame(minHeight: 48)
            .foregroundStyle(RoastTheme.ink)
            .background(RoastTheme.lime, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

struct InlineError: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.footnote).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

