import Foundation

/// Identifies the video without changing the user's entered link. Tracking
/// parameters and YouTube's share/watch URL variants do not mean a new video.
enum SourceLinkIdentity {
    static func same(_ input: String, as other: String?) -> Bool {
        guard let other, let left = key(input), let right = key(other) else { return false }
        return left == right
    }
    static func key(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              let host = components.host?.lowercased() else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        func domain(_ root: String) -> Bool { host == root || host.hasSuffix("." + root) }
        if domain("youtu.be"), let id = parts.first { return "youtube:\(id)" }
        if domain("youtube.com") {
            if let id = components.queryItems?.first(where: { $0.name == "v" })?.value, !id.isEmpty { return "youtube:\(id)" }
            if parts.count >= 2, ["shorts", "embed", "live"].contains(parts[0]) { return "youtube:\(parts[1])" }
        }
        if domain("instagram.com"), parts.count >= 2, ["reel", "reels", "p", "tv"].contains(parts[0]) { return "instagram:\(parts[1])" }
        if domain("x.com") || domain("twitter.com"), let index = parts.firstIndex(of: "status"), parts.count > index + 1 { return "x:\(parts[index + 1])" }
        if domain("tiktok.com"), let index = parts.firstIndex(of: "video"), parts.count > index + 1 { return "tiktok:\(parts[index + 1])" }
        return "\(host):/\(parts.joined(separator: "/"))"
    }
}
