import Foundation

/// Looks a TikTok video up on the phone, the way a browser does: the page sets
/// its cookies, the rehydration JSON names the video files, and the downloads
/// send that cookie (TikTok answers 403 without it). The server is not called.
enum TikTokPhoneResolver {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"
    static let referer = "https://www.tiktok.com/"
    static let unavailableMessage = "This TikTok video is private or unavailable."
    static let ageRestrictedMessage = "This TikTok video is age-restricted and can't be imported."
    static let unusableMessage = "This TikTok video couldn't be opened. Try another link."

    static func handles(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "tiktok.com" || host.hasSuffix(".tiktok.com")
    }

    static func resolve(_ raw: String) async throws -> ResolvedMedia {
        guard let input = URL(string: raw), handles(input) else { throw ResolverError(unusableMessage) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        guard let cookies = configuration.httpCookieStorage else { throw ResolverError(unusableMessage) }
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        // Short links (vt./vm./t/) redirect to the canonical /@user/video/<id> page.
        var id = videoID(in: input)
        if id == nil {
            let (_, response) = try await load(input, using: session)
            if let final = response.url, handles(final) { id = videoID(in: final) }
        }
        guard let id, let page = URL(string: "https://www.tiktok.com/@i/video/\(id)") else { throw ResolverError(unusableMessage) }
        let (data, response) = try await load(page, using: session)
        guard response.statusCode == 200, let html = String(data: data, encoding: .utf8) else { throw ResolverError(unusableMessage) }
        // The cookies the page set for tiktok.com, sent as one Cookie header with each download.
        let set = URL(string: referer).flatMap { cookies.cookies(for: $0) } ?? []
        let cookie = set.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: set)["Cookie"]
        return try manifest(page: html, videoID: id, cookie: cookie)
    }

    /// The numeric id of a canonical video URL; nil for short links, which must be followed first.
    static func videoID(in url: URL) -> String? {
        guard handles(url) else { return nil }
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "video"), parts.count > index + 1 else { return nil }
        let value = parts[index + 1]
        return !value.isEmpty && value.allSatisfy(\.isASCII) && value.allSatisfy(\.isNumber) ? value : nil
    }

    private static func load(_ url: URL, using session: URLSession) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ResolverError(unusableMessage) }
            return (data, http)
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as ResolverError { throw error }
        catch { throw ResolverError(unusableMessage, underlyingError: error as NSError) }
    }

    private struct Stream {
        let url: URL
        let width: Int
        let height: Int
        let codec: SourceVideoCodec
        let bitrate: Int
        var raster: Int { width * height }
    }

    /// Builds the direct manifest from the page. Playable = best H.264 by raster; an HEVC
    /// original with a larger raster is downloaded and converted, with the H.264 as fallback.
    static func manifest(page html: String, videoID: String, cookie: String?, now: Date = .now) throws -> ResolvedMedia {
        guard let start = html.range(of: #"<script[^>]*id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>"#, options: .regularExpression),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let root = try? JSONSerialization.jsonObject(with: Data(html[start.upperBound..<end.lowerBound].utf8)) as? [String: Any],
              let scope = root["__DEFAULT_SCOPE__"] as? [String: Any],
              let detail = scope["webapp.video-detail"] as? [String: Any] else { throw ResolverError(unusableMessage) }
        let found = (detail["itemInfo"] as? [String: Any])?["itemStruct"] as? [String: Any]
        if (found?["isContentClassified"] as? NSNumber)?.boolValue == true { throw ResolverError(ageRestrictedMessage) }
        if let status = (detail["statusCode"] as? NSNumber)?.intValue, status != 0 { throw ResolverError(unavailableMessage) }
        guard let item = found else {
            throw ResolverError(detail["statusMsg"] is String ? unavailableMessage : unusableMessage)
        }
        guard let video = item["video"] as? [String: Any] else { throw ResolverError(unusableMessage) }
        let duration = (video["duration"] as? NSNumber)?.doubleValue
        if let duration, duration > DirectMediaPolicy.maxDuration {
            throw ResolverError("Choose a video under \(Int(DirectMediaPolicy.maxDuration / 60)) minutes.")
        }
        func number(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        func allowed(_ raw: Any?) -> URL? {
            guard let raw = raw as? String, let url = URL(string: raw), DirectMediaPolicy.allows(url, platform: "tiktok") else { return nil }
            return url
        }
        var streams: [Stream] = []
        if let url = allowed(video["playAddr"]) {
            streams.append(Stream(url: url, width: number(video["width"]), height: number(video["height"]), codec: .h264, bitrate: 0))
        }
        for entry in video["bitrateInfo"] as? [[String: Any]] ?? [] {
            let type = (entry["CodecType"] as? String)?.lowercased() ?? ""
            let codec: SourceVideoCodec
            if type == "h264" { codec = .h264 }
            else if type.hasPrefix("h265") || type == "bytevc1" || type == "hevc" { codec = .hevc }
            else { continue }
            guard let address = entry["PlayAddr"] as? [String: Any],
                  let url = allowed((address["UrlList"] as? [Any])?.first) else { continue }
            streams.append(Stream(url: url, width: number(address["Width"]), height: number(address["Height"]),
                                  codec: codec, bitrate: number(entry["Bitrate"])))
        }
        func best(_ candidates: [Stream]) -> Stream? {
            candidates.max { ($0.raster, $0.bitrate) < ($1.raster, $1.bitrate) }
        }
        // Owner's rule: nothing above 1080p is used (measured like YouTube: the short side, or the 16:9 equivalent
        // for wider pictures); the HEVC original is converted only when the best H.264 is below 1080p.
        func quality(_ stream: Stream) -> Int {
            max(min(stream.width, stream.height), Int((Double(max(stream.width, stream.height)) * 9 / 16).rounded()))
        }
        let usable = streams.filter { quality($0) <= 1080 }
        let playable = best(usable.filter { $0.codec == .h264 })
        guard let original = best(usable) ?? playable else { throw ResolverError(unusableMessage) }
        var headers = ["User-Agent": userAgent, "Referer": referer]
        if let cookie, !cookie.isEmpty { headers["Cookie"] = cookie }
        func assets(_ stream: Stream) -> [DirectMediaAsset] { [.init(role: "muxed", url: stream.url, headers: headers)] }
        func expected(_ stream: Stream) -> DirectMediaExpectation {
            DirectMediaExpectation(duration: duration.flatMap { $0 > 0 ? $0 : nil },
                                   width: stream.width > 0 ? stream.width : nil, height: stream.height > 0 ? stream.height : nil,
                                   hasAudio: true, videoCodec: "unknown", audioCodec: "unknown")
        }
        let delivery: MediaDelivery
        if original.codec == .hevc, original.raster > (playable?.raster ?? 0), (playable.map(quality) ?? 0) < 1080 {
            delivery = MediaDelivery(kind: "direct", assets: assets(original), expected: expected(original),
                                     maxBytes: DirectMediaPolicy.byteLimit, url: nil, convert: true,
                                     fallback: playable.map { DirectMediaFallback(assets: assets($0), expected: expected($0)) })
        } else {
            let primary = playable ?? original
            delivery = MediaDelivery(kind: "direct", assets: assets(primary), expected: expected(primary),
                                     maxBytes: DirectMediaPolicy.byteLimit, url: nil, convert: false)
        }
        let id = (item["id"] as? String).flatMap { $0.allSatisfy(\.isNumber) && !$0.isEmpty ? $0 : nil } ?? videoID
        let author = ((item["author"] as? [String: Any])?["uniqueId"] as? String).flatMap {
            $0.range(of: #"^[A-Za-z0-9._]+$"#, options: .regularExpression) != nil ? $0 : nil
        } ?? "i"
        guard let source = URL(string: "https://www.tiktok.com/@\(author)/video/\(id)") else { throw ResolverError(unusableMessage) }
        let description = ((item["desc"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ResolvedMedia(id: "tiktok-\(id)", title: description.isEmpty ? "TikTok video" : String(description.prefix(300)),
                             creator: nil, duration: duration, playbackUrl: nil, delivery: delivery,
                             expiresAt: ISO8601DateFormatter.fractional.string(from: now.addingTimeInterval(300)),
                             qualityVersion: 2, sourceUrl: source, platform: "tiktok")
    }
}
