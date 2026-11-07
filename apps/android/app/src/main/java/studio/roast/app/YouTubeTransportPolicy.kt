package studio.roast.app

import java.net.URI

/** Independent of DNS: callers must validate every locally resolved address before connecting. */
internal object YouTubeTransportPolicy {
    const val WINDOW = 262_144
    const val PAYLOAD = 32_768
    const val MAX_FRAME = 65_536
    const val MAX_STREAMS = 8
    const val MAX_BYTES = 750L * 1024 * 1024
    const val SESSION_MILLIS = 630_000L
    private val label = Regex("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")

    fun destination(host: String, port: Int): Boolean {
        if (port != 443 || host.length !in 1..253 || host.any { it.code !in 33..126 }) return false
        val name = host.lowercase(java.util.Locale.ROOT)
        if (!name.split('.').all { label.matches(it) }) return false
        return name == "youtubei.googleapis.com" || listOf("youtube.com", "googlevideo.com", "ytimg.com")
            .any { name == it || name.endsWith(".$it") }
    }

    fun isYouTubeLink(link: String): Boolean = runCatching {
        val uri = URI(link.trim())
        val host = uri.host?.lowercase(java.util.Locale.ROOT) ?: return false
        uri.scheme in listOf("http", "https") && uri.rawUserInfo == null &&
            (host == "youtu.be" || host == "youtube.com" || host.endsWith(".youtube.com"))
    }.getOrDefault(false)

    fun publicAddress(bytes: ByteArray): Boolean {
        val b = bytes.map { it.toInt() and 255 }
        if (b.size == 4) return publicV4(b)
        if (b.size != 16) return false
        // JVMs may retain IPv4-mapped addresses or normalize them to four bytes.
        if (b.take(10).all { it == 0 } && b[10] == 255 && b[11] == 255) return publicV4(b.takeLast(4))
        // Only the well-known DNS64 prefix is deliberately supported.
        if (b.take(12) == listOf(0, 100, 255, 155, 0, 0, 0, 0, 0, 0, 0, 0)) return publicV4(b.takeLast(4))
        if (b[0] !in 0x20..0x3f) return false // global unicast 2000::/3 only
        if (b[0] == 0x20 && b[1] == 1 && b[2] < 2) return false // IETF special-purpose 2001::/23
        if (b.take(4) == listOf(0x20, 1, 0x0d, 0xb8)) return false // documentation
        if (b[0] == 0x20 && b[1] == 2) return false // deprecated 6to4 can embed non-public IPv4
        if (b[0] == 0x3f && b[1] == 0xff && b[2] < 0x10) return false // 3fff::/20 documentation
        return true
    }

    private fun publicV4(b: List<Int>): Boolean {
        val a=b[0]; val c=b[1]; val d=b[2]
        if (a == 0 || a == 10 || a == 127 || a >= 224) return false
        if (a == 100 && c in 64..127 || a == 169 && c == 254 || a == 172 && c in 16..31) return false
        if (a == 192 && (c == 168 || c == 0 && d in listOf(0, 2) || c == 88 && d == 99)) return false
        if (a == 198 && (c in 18..19 || c == 51 && d == 100) || a == 203 && c == 0 && d == 113) return false
        return true
    }

    fun socketEndpoint(base: String, sessionId: String, token: String, socket: String): URI {
        require(Regex("[A-Za-z0-9_-]{1,128}").matches(sessionId)) { "Invalid YouTube session." }
        require(Regex("[A-Za-z0-9_-]{43}").matches(token)) { "Invalid YouTube session." }
        val api=apiEndpoint(base); val ws=URI(socket)
        require(ws.scheme == "wss" && ws.host.equals(api.host,true) && ws.port in listOf(-1,443) &&
            ws.rawUserInfo == null && ws.rawQuery == null && ws.rawFragment == null &&
            ws.rawPath == "/v1/media/youtube/sessions/$sessionId/socket") { "Invalid YouTube connection." }
        return ws
    }
    fun apiEndpoint(base:String):URI {
        val api=URI(base)
        require(api.scheme == "https" && api.host != null && api.rawUserInfo == null &&
            api.port in listOf(-1,443) && api.rawPath in listOf("", "/") && api.rawQuery == null && api.rawFragment == null) {
            "YouTube needs a secure video service. Check Settings."
        }
        return api
    }
}

/** Each direction owns a separate ledger; acknowledgements are never allowed to mint credit. */
internal class RelayCredit(private val window: Int = YouTubeTransportPolicy.WINDOW) {
    var available: Int = window
        private set
    @Synchronized fun consume(bytes: Int) {
        require(bytes in 1..YouTubeTransportPolicy.PAYLOAD && bytes <= available) { "YouTube flow limit exceeded." }
        available -= bytes
    }
    @Synchronized fun acknowledge(bytes: Int) {
        require(bytes > 0 && bytes <= window - available) { "Invalid YouTube acknowledgement." }
        available += bytes
    }
    @Synchronized fun remaining() = available
}

internal class RelayByteBudget(private val maximum: Long = YouTubeTransportPolicy.MAX_BYTES) {
    private var used=0L
    @Synchronized fun accept(bytes: Int) {
        require(bytes > 0 && bytes.toLong() <= maximum-used) { "This YouTube video is too large. Try a shorter clip." }
        used += bytes
    }
}
