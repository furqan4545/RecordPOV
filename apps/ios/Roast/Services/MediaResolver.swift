import Foundation
import OSLog
#if DEBUG
import AVFoundation
import CoreMedia
#endif

struct ResolvedMedia: Codable, Sendable {
    let id: String
    let title: String
    let creator: String?
    let duration: Double?
    let playbackUrl: URL?
    var delivery: MediaDelivery? = nil
    var expiresAt: String? = nil
    var qualityVersion: Int? = nil
    let sourceUrl: URL
    let platform: String
}

enum MediaResolver {
    private static let logger = Logger(subsystem: "app.roast", category: "MediaConnection")
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 930
        configuration.timeoutIntervalForResource = 960
        return URLSession(configuration: configuration)
    }()
    private static let youtubeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 650
        configuration.timeoutIntervalForResource = 650
        return URLSession(configuration: configuration, delegate: YouTubeServiceRedirectGuard(), delegateQueue: nil)
    }()
    static let defaultAddress = MediaServiceSettings.defaultAddress(
        configured: Bundle.main.object(forInfoDictionaryKey: "RoastMediaServiceURL") as? String)
    private static let supportedDomains = ["instagram.com", "youtube.com", "youtu.be", "x.com", "twitter.com", "tiktok.com"]

    static func supports(_ raw: String) -> Bool {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return false }
        return supportedDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func resolve(_ raw: String, address: String) async throws -> ResolvedMedia {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supports(input) else {
            throw ResolverError("Paste an Instagram, YouTube, TikTok, or X video link.")
        }
        // TikTok is looked up on the phone, like a browser; the server is not called.
        if let url = URL(string: input), TikTokPhoneResolver.handles(url) {
            return try await TikTokPhoneResolver.resolve(input)
        }
        guard let base = URL(string: address), ["http", "https"].contains(base.scheme ?? ""),
              base.host != nil, base.user == nil, base.password == nil else {
            throw ResolverError("Check the video service address in Settings.")
        }
        if MediaServiceConnection.isLocal(base) {
            try await MediaServiceConnection.waitUntilReachable(base)
        }
        let resolvePath = "v2/media/resolve"
        let host = URL(string: input)?.host?.lowercased() ?? ""
        let isYouTube = ["youtube.com", "youtu.be"].contains { host == $0 || host.hasSuffix("." + $0) }
        if isYouTube {
            guard base.scheme == "https" else { throw YouTubeRelayError.secureServiceRequired }
            let ticketData = try await post("v1/media/youtube/sessions", body: ["url": input],
                                           base: base, using: youtubeSession, timeout: 20)
            let ticket = try JSONDecoder().decode(YouTubePhoneSessionTicket.self, from: ticketData)
            let peer = try await YouTubePhoneTransport.connect(ticket: ticket, api: base)
            defer { peer.close() }
            return try await withThrowingTaskGroup(of: ResolvedMedia.self) { group in
                group.addTask {
                    let data = try await post(resolvePath, body: ["url": input, "youtubeSessionId": ticket.sessionId],
                                              base: base, using: youtubeSession, timeout: 650, token: ticket.token)
                    return try JSONDecoder().decode(ResolvedMedia.self, from: data)
                }
                group.addTask {
                    try await peer.waitForFailure()
                    throw YouTubeRelayError.connectionFailed
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
        }
        let data = try await post(resolvePath, body: ["url": input], base: base, using: session, timeout: 930)
        return try JSONDecoder().decode(ResolvedMedia.self, from: data)
    }

    private static func post(_ path: String, body: [String: String], base: URL,
                             using client: URLSession, timeout: TimeInterval,
                             token: String? = nil) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        if let token { request.setValue(token, forHTTPHeaderField: "X-YouTube-Session-Token") }
        request.timeoutInterval = timeout
        let data: Data
        let response: URLResponse
        do { (data, response) = try await client.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch {
            let underlying = error as NSError
            logger.error("Video service failed: \(underlying.domain, privacy: .public), code \(underlying.code, privacy: .public)")
            throw ResolverError(transportMessage(for: underlying, service: base), underlyingError: underlying)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let failure = try? JSONDecoder().decode(ServerFailure.self, from: data)
            throw ResolverError(failure?.error.message ?? "This link couldn’t be opened. Try importing the video instead.", statusCode: (response as? HTTPURLResponse)?.statusCode)
        }
        return data
    }

    private struct ServerFailure: Decodable {
        struct Detail: Decodable { let code: String; let message: String }
        let error: Detail
    }

    private static func transportMessage(for error: NSError, service: URL) -> String {
        guard error.domain == NSURLErrorDomain else {
            return "The video connection failed. Please try again."
        }
        let local = MediaServiceConnection.isLocal(service)
        switch URLError.Code(rawValue: error.code) {
        case .appTransportSecurityRequiresSecureConnection:
            return "iOS blocked the video connection. Update RecordPOV and try again."
        case .notConnectedToInternet:
            return local
                ? "Connect your iPhone and Mac to the same Wi-Fi, and allow Local Network for RecordPOV in iPhone Settings."
                : "Your phone is offline. Reconnect and try again."
        case .cannotFindHost, .dnsLookupFailed:
            return "The video service address couldn’t be found. Check it in Settings."
        case .cannotConnectToHost, .networkConnectionLost, .timedOut:
            return local
                ? "Your phone can’t reach the Mac’s video service. Keep both on the same Wi-Fi and the service running."
                : "The video service isn’t responding. Please try again shortly."
        default:
            return "The video connection failed. Please try again."
        }
    }

    #if DEBUG
    /// Opt-in developer probe; never runs during an ordinary app launch.
    static func runConnectionDiagnostics() async {
        guard let base = URL(string: UserDefaults.standard.string(forKey: "resolverAddress") ?? defaultAddress) else { return }
        let endpoint = base.appendingPathComponent("health")
        var diagnostic: [String: Any] = [
            "runIdentifier": ProcessInfo.processInfo.environment["ROAST_DIAGNOSTIC_RUN_ID"] ?? UUID().uuidString,
            "timestamp": ISO8601DateFormatter().string(from: .now),
            "serviceHost": base.host ?? "",
            "servicePort": base.port ?? (base.scheme == "https" ? 443 : 80),
            "serviceScheme": base.scheme ?? "",
            "usingSavedAddress": UserDefaults.standard.string(forKey: "resolverAddress") != nil
        ]
        do {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 12
            let (_, response) = try await URLSession.shared.data(for: request)
            diagnostic["httpStatus"] = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            var chain: [[String: Any]] = []
            var current: NSError? = error as NSError
            for _ in 0..<5 {
                guard let value = current else { break }
                chain.append(["domain": value.domain, "code": value.code, "description": value.localizedDescription])
                current = value.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            diagnostic["errors"] = chain
            if MediaServiceConnection.isLocal(base) {
                do {
                    try await MediaServiceConnection.waitUntilReachable(base)
                    diagnostic["tcpConnection"] = "reachable"
                } catch let failure as MediaConnectionFailure {
                    diagnostic["tcpConnection"] = failure.offersSettings ? "localNetworkDenied" : "unreachable"
                } catch { diagnostic["tcpConnection"] = "cancelled" }
            }
        }
        if diagnostic["httpStatus"] as? Int == 200,
           let videoURL = ProcessInfo.processInfo.environment["ROAST_VERIFY_VIDEO_URL"], supports(videoURL) {
            do {
                let began = Date()
                let file = try await VideoImportCoordinator.shared.prepareForDiagnostics(raw: videoURL, address: base.absoluteString)
                diagnostic["totalSeconds"] = Date().timeIntervalSince(began)
                diagnostic["videoResolved"] = true
                diagnostic["videoDuration"] = try await AVURLAsset(url: file).load(.duration).seconds
                diagnostic["deliveryKind"] = await VideoImportCoordinator.shared.lastDeliveryKind
                if let report = await VideoImportCoordinator.shared.lastImportReport {
                    diagnostic["deliveryPlan"] = report.deliveryPlan
                    diagnostic["sourceVideoCodec"] = report.sourceVideoCodec
                    diagnostic["sourceAudioCodec"] = report.sourceAudioCodec
                    diagnostic["downloadSeconds"] = report.downloadSeconds
                    diagnostic["conversionSeconds"] = report.conversionSeconds
                }
                if let track = try await AVURLAsset(url: file).loadTracks(withMediaType: .video).first {
                    let subtype = try await track.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
                    diagnostic["outputVideoCodec"] = ImportReport.videoCodecName(subtype)
                    let size = try await track.load(.naturalSize)
                    diagnostic["outputWidth"] = Int(size.width.rounded())
                    diagnostic["outputHeight"] = Int(size.height.rounded())
                    diagnostic["outputFps"] = Double(try await track.load(.nominalFrameRate))
                }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 1280, height: 1280)
                let frame = try await generator.image(at: .zero)
                diagnostic["videoFrameDecoded"] = true
                diagnostic["videoFrameWidth"] = frame.image.width
                diagnostic["videoFrameHeight"] = frame.image.height
            } catch { diagnostic["videoError"] = error.localizedDescription }
        }
        if let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("MediaConnectionDiagnostic.json"), options: .atomic)
        }
    }
    #endif
}

struct ResolverError: LocalizedError {
    let message: String
    let underlyingError: NSError?
    let statusCode: Int?
    init(_ message: String, underlyingError: NSError? = nil, statusCode: Int? = nil) {
        self.message = message
        self.underlyingError = underlyingError
        self.statusCode = statusCode
    }
    var errorDescription: String? { message }
}

