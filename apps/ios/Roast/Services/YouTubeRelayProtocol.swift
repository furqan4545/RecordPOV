import Darwin
import Foundation

enum YouTubeRelayError: LocalizedError, Sendable {
    case invalidProtocol, rejectedDestination, connectionFailed, expired, limitExceeded, secureServiceRequired
    var errorDescription: String? {
        switch self {
        case .secureServiceRequired: "Use an HTTPS video service to open YouTube links."
        case .expired: "This video connection expired. Open the link again."
        default: "This YouTube video couldn’t be prepared. Keep the app open and try again."
        }
    }
}

enum YouTubeRelayPolicy {
    static let window = 262_144
    static let maximumPayload = 32_768
    static let maximumFrame = 65_536
    static let maximumSessionBytes = 750 * 1024 * 1024

    static func allowedHost(_ raw: String, port: Int) -> String? {
        guard port == 443, !raw.isEmpty, raw.utf8.count <= 253,
              raw.utf8.allSatisfy({ $0 < 128 }), !raw.hasSuffix(".") else { return nil }
        let host = raw.lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        let domains = ["youtube.com", "googlevideo.com", "ytimg.com"]
        guard host == "youtubei.googleapis.com" || domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return host
    }

    static func isPublicAddress(_ address: String) -> Bool {
        guard !address.contains("%") else { return false }
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { publicIPv4(Array($0)) }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        return withUnsafeBytes(of: &v6) { bytes in
            let b = Array(bytes)
            if Array(b.prefix(12)) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff] {
                return publicIPv4(Array(b.suffix(4)))
            }
            // Explicit DNS64 exception; a private embedded IPv4 stays forbidden.
            if Array(b.prefix(12)) == [0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] {
                return publicIPv4(Array(b.suffix(4)))
            }
            guard b[0] & 0xe0 == 0x20 else { return false } // 2000::/3 only
            if b[0] == 0x20, b[1] == 0x01, b[2] & 0xfe == 0 { return false } // 2001::/23
            if Array(b.prefix(4)) == [0x20, 0x01, 0x0d, 0xb8] { return false }
            if b[0] == 0x20, b[1] == 0x02 { return false } // 6to4
            if b[0] == 0x3f, b[1] == 0xfe { return false } // retired 6bone
            if b[0] == 0x3f, b[1] == 0xff, b[2] & 0xf0 == 0 { return false }
            return true
        }
    }

    private static func publicIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        let a = b[0], second = b[1], third = b[2]
        return !(a == 0 || a == 10 || a == 127 || a >= 224
            || (a == 100 && (64...127).contains(second))
            || (a == 169 && second == 254)
            || (a == 172 && (16...31).contains(second))
            || (a == 192 && second == 168)
            || (a == 192 && second == 0 && (third == 0 || third == 2))
            || (a == 192 && second == 88 && third == 99)
            || (a == 198 && (second == 18 || second == 19))
            || (a == 198 && second == 51 && third == 100)
            || (a == 203 && second == 0 && third == 113))
    }
}

struct YouTubeRelayCredit {
    private(set) var available = YouTubeRelayPolicy.window
    mutating func consume(_ bytes: Int) throws {
        guard bytes > 0, bytes <= YouTubeRelayPolicy.maximumPayload, bytes <= available else { throw YouTubeRelayError.invalidProtocol }
        available -= bytes
    }
    mutating func acknowledge(_ bytes: Int) throws {
        guard bytes > 0, bytes <= YouTubeRelayPolicy.maximumPayload,
              bytes <= YouTubeRelayPolicy.window - available else { throw YouTubeRelayError.invalidProtocol }
        available += bytes
    }
}

struct YouTubeRelayControl: Codable {
    let type: String
    var id: UInt32? = nil
    var host: String? = nil
    var port: Int? = nil
    var bytes: Int? = nil
    var version: Int? = nil
    var message: String? = nil
}

enum YouTubeRelayFrame {
    static func encode(id: UInt32, payload: Data) throws -> Data {
        guard id > 0, (1...YouTubeRelayPolicy.maximumPayload).contains(payload.count) else { throw YouTubeRelayError.invalidProtocol }
        var frame = Data([1, UInt8(truncatingIfNeeded: id >> 24), UInt8(truncatingIfNeeded: id >> 16),
                          UInt8(truncatingIfNeeded: id >> 8), UInt8(truncatingIfNeeded: id)])
        frame.append(payload)
        return frame
    }
    static func decode(_ frame: Data) throws -> (id: UInt32, payload: Data) {
        guard (6...(5 + YouTubeRelayPolicy.maximumPayload)).contains(frame.count) else { throw YouTubeRelayError.invalidProtocol }
        let header = Array(frame.prefix(5))
        guard header[0] == 1 else { throw YouTubeRelayError.invalidProtocol }
        let id = UInt32(header[1]) << 24 | UInt32(header[2]) << 16 | UInt32(header[3]) << 8 | UInt32(header[4])
        guard id > 0 else { throw YouTubeRelayError.invalidProtocol }
        return (id, Data(frame.dropFirst(5)))
    }
}

struct YouTubePhoneSessionTicket: Decodable, Sendable {
    let sessionId: String
    let token: String
    let socketUrl: URL
    let expiresAt: String

    func validate(api: URL, now: Date = .now) throws -> TimeInterval {
        guard api.scheme?.lowercased() == "https" else { throw YouTubeRelayError.secureServiceRequired }
        guard (8...128).contains(sessionId.utf8.count), sessionId.utf8.allSatisfy(Self.unreserved),
              token.utf8.count == 43, token.utf8.allSatisfy(Self.unreserved),
              socketUrl.scheme?.lowercased() == "wss", socketUrl.host?.lowercased() == api.host?.lowercased(),
              (socketUrl.port ?? 443) == (api.port ?? 443), socketUrl.user == nil, socketUrl.password == nil,
              socketUrl.query == nil, socketUrl.fragment == nil,
              socketUrl.path == api.appendingPathComponent("v1/media/youtube/sessions")
                .appendingPathComponent(sessionId).appendingPathComponent("socket").path else { throw YouTubeRelayError.invalidProtocol }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var expiration = parser.date(from: expiresAt)
        if expiration == nil { parser.formatOptions = [.withInternetDateTime]; expiration = parser.date(from: expiresAt) }
        guard let expiration, expiration > now else { throw YouTubeRelayError.expired }
        return min(630, expiration.timeIntervalSince(now))
    }

    private static func unreserved(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
    }
}
