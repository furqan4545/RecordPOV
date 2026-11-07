import Foundation

struct MediaDelivery: Codable, Sendable {
    let kind: String
    let assets: [DirectMediaAsset]?
    let expected: DirectMediaExpectation?
    let maxBytes: Int64?
    let url: URL?
    /// True when the primary set is a better original that must be converted on the phone.
    var convert: Bool? = nil
    /// The best directly playable set, offered when the primary needs conversion.
    var fallback: DirectMediaFallback? = nil
}
struct DirectMediaFallback: Codable, Sendable {
    let assets: [DirectMediaAsset]
    let expected: DirectMediaExpectation
}
struct DirectMediaAsset: Codable, Sendable {
    let role: String
    let url: URL
    let headers: [String: String]
}
struct DirectMediaExpectation: Codable, Sendable {
    let duration: Double?
    let width: Int?
    let height: Int?
    let hasAudio: Bool
    var fps: Double? = nil
    /// 'h264' | 'hevc' | 'vp9' | 'av1' | 'unknown'
    var videoCodec: String? = nil
    /// 'aac-lc' | 'he-aac' | 'aac' | 'unknown' | 'none'
    var audioCodec: String? = nil
}

/// Background URLSession follows redirects itself. Send only unprivileged
/// headers to narrowly trusted CDN hosts, and validate the final response too.
/// This is not per-hop DNS pinning; the server also checks the initial host.
enum DirectMediaPolicy {
    static let byteLimit: Int64 = 2 * 1024 * 1024 * 1024
    static let maxDuration: Double = 3600
    static let headerNames = Set(["user-agent", "referer", "origin", "accept"])
    static func allows(_ url: URL, platform: String) -> Bool {
        guard url.scheme?.lowercased() == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.fragment == nil,
              let host = url.host?.lowercased(), host.count <= 253,
              !host.hasSuffix("."), !host.contains(":") else { return false }
        func within(_ domains: [String]) -> Bool {
            domains.contains { host == $0 || host.hasSuffix("." + $0) }
        }
        switch platform {
        case "instagram": return within(["cdninstagram.com", "fbcdn.net"])
        case "youtube": return within(["googlevideo.com"])
        case "x", "twitter": return host == "video.twimg.com"
        case "tiktok":
            return within(["tiktokcdn.com", "tiktokcdn-us.com", "tiktokcdn-eu.com", "tiktokv.com", "ibytedtos.com", "byteoversea.com"])
                || host.range(of: #"^v[0-9]+-webapp-prime\.tiktok\.com$"#, options: .regularExpression) != nil
        default: return false
        }
    }
    static func serviceFile(_ url: URL, base: URL) -> Bool {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.scheme?.lowercased() == base.scheme?.lowercased(),
              url.host?.lowercased() == base.host?.lowercased(), effectivePort(url) == effectivePort(base),
              url.user == nil, url.password == nil, url.fragment == nil, url.query == nil else { return false }
        return url.path.range(of: #"^/v1/media/[a-f0-9]{24}/file$"#, options: .regularExpression) != nil
    }
    private static func effectivePort(_ url: URL) -> Int { url.port ?? (url.scheme == "https" ? 443 : 80) }
    static func request(_ asset: DirectMediaAsset, platform: String) throws -> URLRequest {
        guard allows(asset.url, platform: platform), asset.headers.count <= 4 else { throw DirectImportError.invalidDelivery }
        var request = URLRequest(url: asset.url)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in asset.headers {
            // Only the phone's own TikTok lookup sends the page cookie; server manifests never contain one.
            let allowed = headerNames.contains(name.lowercased()) || (platform == "tiktok" && name.lowercased() == "cookie")
            guard allowed, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), value.utf8.count <= 2048 else {
                throw DirectImportError.invalidDelivery
            }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
    /// Validates the primary set and, when present, the fallback set; returns the primary assets.
    static func validate(_ media: ResolvedMedia, checkExpiry: Bool = true) throws -> [DirectMediaAsset] {
        guard let delivery = media.delivery, delivery.kind == "direct", let assets = delivery.assets,
              let expected = delivery.expected, let maxBytes = delivery.maxBytes,
              maxBytes > 0, maxBytes <= byteLimit else { throw DirectImportError.invalidDelivery }
        try validateSet(assets, expected: expected, platform: media.platform)
        if let fallback = delivery.fallback {
            try validateSet(fallback.assets, expected: fallback.expected, platform: media.platform)
        }
        if checkExpiry {
            guard let date = expiryDate(media),
                  date > .now, date <= .now.addingTimeInterval(600) else { throw DirectImportError.expired }
        }
        return assets
    }
    private static func validateSet(_ assets: [DirectMediaAsset], expected: DirectMediaExpectation, platform: String) throws {
        let roles = assets.map(\.role).sorted()
        guard roles == ["muxed"] || roles == ["audio", "video"],
              roles == ["muxed"] || expected.hasAudio else { throw DirectImportError.invalidDelivery }
        if let duration = expected.duration, (!duration.isFinite || duration <= 0 || duration > maxDuration) { throw DirectImportError.invalidDelivery }
        if let width = expected.width, let height = expected.height {
            guard width > 0, height > 0, max(width, height) <= 3840, min(width, height) <= 2160 else { throw DirectImportError.invalidDelivery }
        }
        for asset in assets { _ = try request(asset, platform: platform) }
    }
    /// A manifest without a readable expiry counts as expiring: a fresh resolve
    /// is cheaper than a direct transfer that the CDN rejects mid-flight.
    static func expiresSoon(_ media: ResolvedMedia, margin: TimeInterval = 10) -> Bool {
        guard let date = expiryDate(media) else { return true }
        return date <= .now.addingTimeInterval(margin)
    }
    private static func expiryDate(_ media: ResolvedMedia) -> Date? {
        guard let expires = media.expiresAt else { return nil }
        return ISO8601DateFormatter.fractional.date(from: expires) ?? ISO8601DateFormatter().date(from: expires)
    }
}

extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let result = ISO8601DateFormatter()
        result.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return result
    }
}

enum DirectImportError: LocalizedError {
    case invalidDelivery, expired, incompatible, tooLarge, interrupted
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "This video is too large. Choose a shorter video."
        case .interrupted: return "The download was interrupted. Open the link again to retry."
        default: return "This video needs another download method. Please try again."
        }
    }
}
