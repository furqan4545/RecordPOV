import SwiftUI

/// First launch only: a welcome, then four screens showing how RecordPOV works.
/// Start (on the last screen) opens Create; the flow never appears again.
struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0
    private let lastPage = 4

    private var shareInstructions: String {
        #if APP_STORE
        "Save your take to Photos, then share it anywhere."
        #else
        "Export your video, then share it to Instagram, TikTok, YouTube or X."
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                WelcomePage().tag(0)
                #if APP_STORE
                StepPage(number: 1, title: "Choose a video",
                         text: "Pick a video or photo from your library.") {
                    LocalMediaArt()
                }.tag(1)
                #else
                StepPage(number: 1, title: "Paste a link",
                         text: "Copy a video from Instagram, YouTube, TikTok or X, then paste it into RecordPOV.") {
                    PasteArt()
                }.tag(1)
                #endif
                StepPage(number: 2, title: "Turn on camera and mic",
                         text: "Your face goes on top of the video. The background is removed right on your iPhone.") {
                    CameraArt()
                }.tag(2)
                StepPage(number: 3, title: "Tap record",
                         text: "React while the video plays. Stop whenever you’re done.") {
                    RecordArt()
                }.tag(3)
                StepPage(number: 4, title: "Export and share", text: shareInstructions) {
                    ShareArt()
                }.tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            PageDots(count: lastPage + 1, current: page).padding(.top, 10).padding(.bottom, 16)
            PrimaryButton(title: page == 0 ? "Get started" : (page < lastPage ? "Next" : "Start")) {
                if page < lastPage { withAnimation(.easeInOut(duration: 0.3)) { page += 1 } } else { onFinish() }
            }
            .accessibilityIdentifier("onboardingNextButton")
            .padding(.horizontal, 22)
        }
        .padding(.bottom, 16)
        .foregroundStyle(RoastTheme.ink)
        .background(RoastTheme.paper)
    }
}

// MARK: - Pages

private struct WelcomePage: View {
    private var instructions: String {
        #if APP_STORE
        "Pick a video from your library and record your reaction over it."
        #else
        "Paste a link, hit record, and you’re on top of it."
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 30)
                Text("RecordPOV").font(.system(size: 22, weight: .bold, design: .rounded))
            }
            .padding(.top, 8)
            ReactionVideo()
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                .padding(.top, 18)
                .accessibilityHidden(true)
            Text("React to any video")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .padding(.top, 22)
                .accessibilityAddTraits(.isHeader)
            Text(instructions)
                .font(.system(size: 17)).foregroundStyle(RoastTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .padding(.horizontal, 22)
    }
}

private struct StepPage<Art: View>: View {
    let number: Int
    let title: String
    let text: String
    let art: Art

    init(number: Int, title: String, text: String, @ViewBuilder art: () -> Art) {
        self.number = number; self.title = title; self.text = text; self.art = art()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("STEP \(number) OF 4")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(RoastTheme.muted)
                .padding(.top, 10)
            art
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                .padding(.top, 12)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .padding(.top, 22)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.system(size: 17)).foregroundStyle(RoastTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .padding(.horizontal, 22)
    }
}

// MARK: - Step art

private enum OnboardingArt {
    static let card = Color(red: 0.90, green: 0.89, blue: 0.85)
}

#if APP_STORE
private struct LocalMediaArt: View {
    var body: some View {
        VStack(spacing: 14) {
            Image("OnboardingVideo").resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxHeight: .infinity)
            Label("Choose video or photo", systemImage: "photo.on.rectangle.angled")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoastTheme.lime, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(14)
        .background(OnboardingArt.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}
#else
/// Step 1: the video you copied, the link field and where links can come from.
private struct PasteArt: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image("OnboardingVideo").resizable().scaledToFit()
                .overlay(alignment: .topLeading) { PlatformTile(platform: .instagram, size: 32).padding(10) }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxHeight: .infinity)
            HStack(spacing: 10) {
                Image(systemName: "link").foregroundStyle(RoastTheme.muted)
                Text("instagram.com/reel/C9x…").font(.system(size: 15)).foregroundStyle(RoastTheme.muted).lineLimit(1)
                Spacer(minLength: 4)
                Text("Paste").font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).frame(height: 32).background(RoastTheme.lime, in: Capsule())
            }
            .padding(.horizontal, 14).frame(height: 52)
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 14) {
                ForEach(VideoPlatform.allCases, id: \.self) { PlatformTile(platform: $0, size: 46) }
            }
            .padding(.vertical, 4)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(OnboardingArt.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

#endif

/// Step 2: you with your room behind you, then a sweep removes the background.
private struct CameraArt: View {
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                limeCircle("camera.fill")
                limeCircle("mic.fill")
            }
            .padding(.top, 16)
            BackgroundRemovalDemo()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Label("Background removed on your iPhone", systemImage: "sparkles")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 34)
                .background(.white.opacity(0.12), in: Capsule())
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoastTheme.ink, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func limeCircle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .semibold)).foregroundStyle(RoastTheme.ink)
            .frame(width: 50, height: 50).background(RoastTheme.lime, in: Circle())
    }
}

/// The same photo twice, lined up: with its real background, then cut out.
/// A lime line sweeps across to show the background coming off, then it loops.
private struct BackgroundRemovalDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var removed: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Color.white.opacity(0.06)
                Image("OnboardingMe").resizable().scaledToFill()
                    .frame(width: width, height: geo.size.height).clipped()
                    .mask(alignment: .trailing) { Rectangle().frame(width: width * (1 - removed)) }
                Image("OnboardingMeCutout").resizable().scaledToFill()
                    .frame(width: width, height: geo.size.height).clipped()
                    .mask(alignment: .leading) { Rectangle().frame(width: width * removed) }
                Rectangle().fill(RoastTheme.lime).frame(width: 3, height: geo.size.height)
                    .shadow(color: RoastTheme.lime.opacity(0.8), radius: 6)
                    .offset(x: (width + 8) * removed - 5)
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .task { await play() }
    }

    private func play() async {
        guard !reduceMotion else { removed = 1; return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeInOut(duration: 1.6)) { removed = 1 }
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeInOut(duration: 1.2)) { removed = 0 }
            try? await Task.sleep(for: .seconds(1.2))
        }
    }
}

/// Step 3: recording a reaction on top of the video.
private struct RecordArt: View {
    var body: some View {
        VStack(spacing: 14) {
            ReactionVideo()
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("REC 0:07").font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 10).frame(height: 28)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            ZStack {
                Circle().stroke(.white, lineWidth: 3).frame(width: 62, height: 62)
                Circle().fill(RoastTheme.lime).frame(width: 48, height: 48)
            }
        }
        .padding(14)
        .background(RoastTheme.ink, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// Step 4: the finished video, ready to share.
private struct ShareArt: View {
    var body: some View {
        VStack(spacing: 14) {
            ReactionVideo()
                .overlay(alignment: .topLeading) {
                    Label("Exported", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(RoastTheme.ink)
                    .frame(width: 44, height: 44).background(RoastTheme.lime, in: Circle())
                #if APP_STORE
                Text("Save and share").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                #else
                ForEach([VideoPlatform.instagram, .tiktok, .youtube, .x], id: \.self) {
                    PlatformTile(platform: $0, size: 44, onDark: true)
                }
                #endif
            }
        }
        .padding(14)
        .background(RoastTheme.ink, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

// MARK: - Shared pieces

/// The example vertical video with you on top, background removed, over the
/// bottom-right corner, the way a Cutout reaction looks in Studio.
private struct ReactionVideo: View {
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                Image("OnboardingVideo").resizable().scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                Image("OnboardingMeCutout").resizable().scaledToFit()
                    .frame(height: geo.size.height * 0.46)
                    .offset(x: geo.size.width * 0.025)
            }
        }
    }
}

enum VideoPlatform: CaseIterable {
    case instagram, youtube, tiktok, x

    var asset: String {
        switch self {
        case .instagram: "BrandInstagram"
        case .youtube: "BrandYouTube"
        case .tiktok: "BrandTikTok"
        case .x: "BrandX"
        }
    }
}

/// A platform's own glyph on its own colours, like its app icon.
struct PlatformTile: View {
    let platform: VideoPlatform
    var size: CGFloat = 46
    var onDark = false

    var body: some View {
        Image(platform.asset).renderingMode(.template).resizable().scaledToFit()
            .foregroundStyle(platform == .youtube ? Color(red: 1, green: 0, blue: 0) : .white)
            .padding(size * 0.24)
            .frame(width: size, height: size)
            .background(background, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .stroke(onDark ? Color.white.opacity(0.18) : RoastTheme.ink.opacity(0.08), lineWidth: 1))
    }

    private var background: AnyShapeStyle {
        switch platform {
        case .instagram:
            AnyShapeStyle(LinearGradient(colors: [
                Color(red: 0.996, green: 0.855, blue: 0.459), Color(red: 0.980, green: 0.494, blue: 0.118),
                Color(red: 0.839, green: 0.161, blue: 0.463), Color(red: 0.588, green: 0.184, blue: 0.749),
                Color(red: 0.310, green: 0.357, blue: 0.835),
            ], startPoint: .bottomLeading, endPoint: .topTrailing))
        case .youtube: AnyShapeStyle(Color.white)
        case .tiktok, .x: AnyShapeStyle(Color.black)
        }
    }
}

/// Small Instagram, YouTube, TikTok and X icons, used under Create's link field.
struct PlatformIconRow: View {
    var size: CGFloat = 24

    var body: some View {
        HStack(spacing: 8) {
            ForEach(VideoPlatform.allCases, id: \.self) { PlatformTile(platform: $0, size: size) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Works with Instagram, YouTube, TikTok and X")
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule().fill(index == current ? RoastTheme.ink : RoastTheme.ink.opacity(0.18))
                    .frame(width: index == current ? 20 : 7, height: 7)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: current)
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}
