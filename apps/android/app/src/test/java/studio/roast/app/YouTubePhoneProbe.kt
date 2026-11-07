package studio.roast.app

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.Request
import org.json.JSONObject
import java.io.File
import java.net.InetAddress
import java.net.URI
import java.util.concurrent.TimeUnit

/** Explicit manual integration entry point; never runs as part of unit tests. */
object YouTubePhoneProbe {
    @JvmStatic fun main(args:Array<String>) {
        if(args.contentEquals(arrayOf("--check"))) {
            println("Android JVM phone-transport probe compiled. No network request was made.")
            return
        }
        require(args.size==3 && args[0]=="--run" && System.getenv("ROAST_YOUTUBE_PROBE_OPT_IN")=="yes") {
            "Explicit opt-in required: ROAST_YOUTUBE_PROBE_OPT_IN=yes, --run, one YouTube URL, output directory."
        }
        val link=args[1]
        require(YouTubeTransportPolicy.isYouTubeLink(link)) {"One public YouTube control URL is required."}
        val directory=File(args[2]).canonicalFile
        check(directory.mkdirs() || directory.isDirectory)
        val destination=File(directory,"control.mp4");val pending=File(directory,"control.download")
        check(!destination.exists() && !pending.exists()) {"Use an empty output directory; existing media will not be overwritten."}
        val base="https://api.recordpov.app"
        val client=YouTubePhoneRelay.client()
        val started=System.nanoTime()
        try {
            val response=runBlocking {withTimeout(YouTubeTransportPolicy.SESSION_MILLIS+25_000) {
                YouTubePhoneFetch.resolve(base,link,client,lookup={host->
                    InetAddress.getAllByName(host).toList().also{answers ->
                        // Counts only: no public IP addresses, token, or credentials are logged.
                        println("DNS $host: IPv4=${answers.count{it.address.size==4}}, IPv6=${answers.count{it.address.size==16}}")
                    }
                })
            }}
            val elapsed=(System.nanoTime()-started)/1_000_000
            val playback=URI(response.getString("playbackUrl"))
            require(playback.scheme=="https" && playback.host=="api.recordpov.app" && playback.port in listOf(-1,443) && playback.rawUserInfo==null)
            File(directory,"resolved.json").writeText(response.toString(2))
            println("Resolved id=${response.getString("id")} in ${elapsed}ms; phone relay has closed.")
            client.newBuilder().readTimeout(120,TimeUnit.SECONDS).callTimeout(180,TimeUnit.SECONDS).build()
                .newCall(Request.Builder().url(playback.toString()).build()).execute().use {result ->
                    check(result.isSuccessful){"Final MP4 transfer failed with HTTP ${result.code}."}
                    check(result.body.contentLength()<=DirectImportPolicy.MAX_FILE_BYTES)
                    result.body.byteStream().use {input->pending.outputStream().use {output->
                        val buffer=ByteArray(65536);var total=0L
                        while(true) {val count=input.read(buffer);if(count<0)break;total+=count;check(total<=DirectImportPolicy.MAX_FILE_BYTES);output.write(buffer,0,count)}
                    }}
                }
            check(pending.length()>0 && pending.renameTo(destination))
            File(directory,"probe.json").writeText(JSONObject().put("resolverMillis",elapsed).put("bytes",destination.length())
                .put("id",response.getString("id")).put("file",destination.absolutePath).toString(2))
            println("Downloaded ${destination.length()} bytes to ${destination.absolutePath}")
        } finally {
            pending.delete();client.dispatcher.cancelAll();client.connectionPool.evictAll();client.dispatcher.executorService.shutdown()
        }
    }
}
