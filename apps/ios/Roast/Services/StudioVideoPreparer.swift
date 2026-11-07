import AVFoundation
import Foundation

enum VideoLinkLoadingPhase: Equatable {
    case idle, preparing, downloading, loading

    static func resuming(hasResolvedMedia: Bool, stage: String) -> Self {
        guard hasResolvedMedia else { return .preparing }
        return stage == "preparing" ? .loading : .downloading
    }

    var buttonTitle: String {
        switch self { case .idle: "Open video"; case .preparing: "Getting your video…"; case .downloading: "Downloading…"; case .loading: "Almost ready…" }
    }
    var message: String {
        switch self {
        case .idle: ""
        case .preparing: "Getting your video ready…"
        case .downloading: "Please wait, we’re downloading your video."
        case .loading: "Loading your video…"
        }
    }
    var accessibilityValue: String {
        switch self { case .idle: ""; case .preparing: "Preparing video"; case .downloading: "Downloading"; case .loading: "Loading" }
    }
}

struct PreparedStudioVideo: Sendable {
    let url: URL
    fileprivate let ownsFile: Bool

    /// Only a canceled, unpresented download is disposable. Imported local
    /// files and media already handed to the studio must remain available.
    func discardBeforeLaunch() {
        if ownsFile { try? FileManager.default.removeItem(at: url) }
    }
}

enum StudioVideoPreparer {
    typealias Download = @Sendable (URL) async throws -> (URL, URLResponse)
    typealias Validate = @Sendable (URL) async throws -> Void

    /// Download once into the same durable folder used by StudioEngine. Passing
    /// this local URL to the studio bypasses its remote-download branch, keeping
    /// recording/source-audio reconstruction independent of server cache expiry.
    static func prepare(_ source: URL, directory: URL? = nil,
                        download: Download = { try await downloadFile($0) },
                        validate: Validate = { try await validateVideo($0) }) async throws -> PreparedStudioVideo {
        try Task.checkCancellation()
        var downloadedURL: URL?
        do {
            let localURL: URL
            if source.isFileURL { localURL = source }
            else {
                let (temporary, response) = try await download(source)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                let folder = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("SourceVideos", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                localURL = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
                try FileManager.default.moveItem(at: temporary, to: localURL)
                downloadedURL = localURL
            }
            try await validate(localURL)
            try Task.checkCancellation()
            return PreparedStudioVideo(url: localURL, ownsFile: downloadedURL != nil)
        } catch {
            if let downloadedURL { try? FileManager.default.removeItem(at: downloadedURL) }
            throw error
        }
    }

    private static func downloadFile(_ url: URL) async throws -> (URL, URLResponse) {
        try await URLSession.shared.download(from: url)
    }

    private static func validateVideo(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        defer { withExtendedLifetime(asset) {} }
        let playable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration).seconds
        guard playable, !tracks.isEmpty, duration.isFinite, duration > 0 else {
            throw PreparationError.unplayable
        }
        try Task.checkCancellation()
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 1280)
        _ = try await generator.image(at: .zero)
    }

    private enum PreparationError: LocalizedError {
        case unplayable
        var errorDescription: String? {
            "This video couldn’t be loaded. Open the link again or import a local copy."
        }
    }
}
