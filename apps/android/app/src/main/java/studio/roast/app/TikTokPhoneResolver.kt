package studio.roast.app

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.URI
import java.time.Instant
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Looks a TikTok video up on the phone, the way a browser does: the page sets its cookies, the rehydration
 * JSON names the video files, and the downloads send that cookie (TikTok answers 403 without it). The server is not called.
 */
internal object TikTokPhoneResolver {
    const val USER_AGENT="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"
    const val REFERER="https://www.tiktok.com/"
    const val UNAVAILABLE="This TikTok video is private or unavailable."
    const val AGE_RESTRICTED="This TikTok video is age-restricted and can't be imported."
    const val UNUSABLE="This TikTok video couldn't be opened. Try another link."
    val TOO_LONG="Choose a video under ${(DirectImportPolicy.MAX_DURATION/60).toInt()} minutes."
    private const val ACCEPT="text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

    fun handles(link:String):Boolean=host(link)?.let{it=="tiktok.com"||it.endsWith(".tiktok.com")}?:false
    private fun host(link:String):String?=runCatching{URI(link.trim()).host?.lowercase(Locale.ROOT)}.getOrNull()

    /** The numeric id of a canonical video URL; null for short links, which must be followed first. */
    fun videoId(link:String):String? {
        if(!handles(link))return null
        val parts=runCatching{URI(link.trim()).path}.getOrNull().orEmpty().split('/').filter{it.isNotEmpty()}
        val index=parts.indexOf("video")
        if(index<0||index+1>=parts.size)return null
        return parts[index+1].takeIf{value->value.isNotEmpty()&&value.all{it in '0'..'9'}}
    }

    /** Returns the same direct manifest the service would: platform "tiktok", qualityVersion 2, five minutes to start. */
    suspend fun resolve(link:String):JSONObject {
        val input=link.trim()
        if(!handles(input))throw IOException(UNUSABLE)
        // Its own in-memory cookies for this one lookup only.
        val cookies=LookupCookies()
        val client=OkHttpClient.Builder().cookieJar(cookies).connectTimeout(15,TimeUnit.SECONDS)
            .readTimeout(30,TimeUnit.SECONDS).callTimeout(60,TimeUnit.SECONDS).build()
        try {
            // Short links (vt./vm./t/) redirect to the canonical /@user/video/<id> page.
            val id=videoId(input) ?: load(client,input,readBody=false).url.toString().let{landed->if(handles(landed))videoId(landed)else null}
                ?: throw IOException(UNUSABLE)
            val page=load(client,"https://www.tiktok.com/@i/video/$id",readBody=true)
            val html=page.body?.takeIf{page.code==200} ?: throw IOException(UNUSABLE)
            // The cookies the page set for tiktok.com, sent as one Cookie header with each download.
            return manifest(html,id,cookies.header(REFERER.toHttpUrl()))
        }finally{client.dispatcher.cancelAll();client.connectionPool.evictAll();client.dispatcher.executorService.shutdown()}
    }

    private class Page(val code:Int,val url:HttpUrl,val body:String?)
    private suspend fun load(client:OkHttpClient,url:String,readBody:Boolean):Page {
        val request=runCatching{Request.Builder().url(url).header("User-Agent",USER_AGENT).header("Accept",ACCEPT).build()}.getOrNull()
            ?: throw IOException(UNUSABLE)
        val call=client.newCall(request)
        return suspendCancellableCoroutine {continuation->
            continuation.invokeOnCancellation{call.cancel()}
            call.enqueue(object:Callback {
                override fun onFailure(call:Call,e:IOException){if(continuation.isActive)continuation.resumeWithException(IOException(UNUSABLE))}
                override fun onResponse(call:Call,response:Response) {
                    try {
                        val page=response.use{Page(it.code,it.request.url,if(readBody)it.body.string()else null)}
                        if(continuation.isActive)continuation.resume(page)
                    }catch(e:Exception){if(continuation.isActive)continuation.resumeWithException(IOException(UNUSABLE))}
                }
            })
        }
    }

    private class Stream(val url:String,val width:Int,val height:Int,val hevc:Boolean,val bitrate:Int) {
        val raster get()=width*height
    }

    /**
     * Builds the direct manifest from the page. Playable = best H.264 by raster; an HEVC original with a larger
     * raster is downloaded and converted, with the H.264 as fallback.
     */
    fun manifest(html:String,videoId:String,cookie:String?,now:Long=System.currentTimeMillis()):JSONObject {
        val start=Regex("""<script[^>]*id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>""").find(html) ?: throw IOException(UNUSABLE)
        val end=html.indexOf("</script>",start.range.last+1).takeIf{it>=0} ?: throw IOException(UNUSABLE)
        val root=runCatching{JSONObject(html.substring(start.range.last+1,end))}.getOrNull() ?: throw IOException(UNUSABLE)
        val detail=root.optJSONObject("__DEFAULT_SCOPE__")?.optJSONObject("webapp.video-detail") ?: throw IOException(UNUSABLE)
        val found=detail.optJSONObject("itemInfo")?.optJSONObject("itemStruct")
        if(flag(found?.opt("isContentClassified")))throw IOException(AGE_RESTRICTED)
        val status=(detail.opt("statusCode") as? Number)?.toInt()
        if(status!=null&&status!=0)throw IOException(UNAVAILABLE)
        val item=found ?: throw IOException(if(detail.opt("statusMsg") is String)UNAVAILABLE else UNUSABLE)
        val video=item.optJSONObject("video") ?: throw IOException(UNUSABLE)
        val duration=(video.opt("duration") as? Number)?.toDouble()
        if(duration!=null&&duration>DirectImportPolicy.MAX_DURATION)throw IOException(TOO_LONG)
        fun number(value:Any?)=(value as? Number)?.toInt()?:0
        fun allowed(raw:Any?)=(raw as? String)?.takeIf{DirectImportPolicy.allowedUrl(it,"tiktok")}
        val streams=ArrayList<Stream>()
        allowed(video.opt("playAddr"))?.let{streams+=Stream(it,number(video.opt("width")),number(video.opt("height")),false,0)}
        val bitrates=video.optJSONArray("bitrateInfo") ?: JSONArray()
        for(index in 0 until bitrates.length()) {
            val entry=bitrates.optJSONObject(index) ?: continue
            val type=(entry.opt("CodecType") as? String)?.lowercase(Locale.ROOT).orEmpty()
            val hevc=when {
                type=="h264"->false
                type.startsWith("h265")||type=="bytevc1"||type=="hevc"->true
                else->continue
            }
            val address=entry.optJSONObject("PlayAddr") ?: continue
            val url=allowed(address.optJSONArray("UrlList")?.opt(0)) ?: continue
            streams+=Stream(url,number(address.opt("Width")),number(address.opt("Height")),hevc,number(entry.opt("Bitrate")))
        }
        fun best(candidates:List<Stream>)=candidates.maxWithOrNull(compareBy<Stream>({it.raster},{it.bitrate}))
        // Owner's rule: nothing above 1080p is used (measured like YouTube: the short side, or the 16:9 equivalent
        // for wider pictures); the HEVC original is converted only when the best H.264 is below 1080p.
        fun quality(stream:Stream)=maxOf(minOf(stream.width,stream.height),Math.round(maxOf(stream.width,stream.height)*9/16.0).toInt())
        val usable=streams.filter{quality(it)<=1080}
        val playable=best(usable.filter{!it.hevc})
        val original=best(usable) ?: playable ?: throw IOException(UNUSABLE)
        fun headers()=JSONObject().put("User-Agent",USER_AGENT).put("Referer",REFERER).apply{if(!cookie.isNullOrEmpty())put("Cookie",cookie)}
        fun assets(stream:Stream)=JSONArray().put(JSONObject().put("role","muxed").put("url",stream.url).put("headers",headers()))
        fun expected(stream:Stream)=JSONObject().put("hasAudio",true).put("videoCodec","unknown").put("audioCodec","unknown").apply {
            if(duration!=null&&duration>0)put("duration",duration)
            if(stream.width>0)put("width",stream.width)
            if(stream.height>0)put("height",stream.height)
        }
        val delivery=JSONObject().put("kind","direct").put("maxBytes",DirectImportPolicy.MAX_BYTES)
        if(original.hevc&&original.raster>(playable?.raster?:0)&&(playable?.let{quality(it)}?:0)<1080) {
            delivery.put("assets",assets(original)).put("expected",expected(original)).put("convert",true)
            playable?.let{delivery.put("fallback",JSONObject().put("assets",assets(it)).put("expected",expected(it)))}
        }else {
            val primary=playable?:original
            delivery.put("assets",assets(primary)).put("expected",expected(primary)).put("convert",false)
        }
        val id=(item.opt("id") as? String)?.takeIf{value->value.isNotEmpty()&&value.all{it in '0'..'9'}} ?: videoId
        val author=(item.optJSONObject("author")?.opt("uniqueId") as? String)?.takeIf{it.matches(Regex("^[A-Za-z0-9._]+$"))} ?: "i"
        val description=((item.opt("desc") as? String) ?: "").trim()
        val title=if(description.isEmpty())"TikTok video"
            else description.substring(0,description.offsetByCodePoints(0,minOf(300,description.codePointCount(0,description.length))))
        return JSONObject().put("id","tiktok-$id").put("title",title).put("platform","tiktok").put("qualityVersion",2)
            .put("expiresAt",Instant.ofEpochMilli(now+300_000).toString()).put("sourceUrl","https://www.tiktok.com/@$author/video/$id")
            .put("delivery",delivery).apply{if(duration!=null)put("duration",duration)}
    }
    private fun flag(value:Any?)=value==true||(value is Number&&value.toDouble()!=0.0)
}

/** Cookies for one lookup only, kept in memory and dropped with it. */
private class LookupCookies:CookieJar {
    private val stored=ArrayList<Cookie>()
    @Synchronized override fun saveFromResponse(url:HttpUrl,cookies:List<Cookie>) {
        for(cookie in cookies) {
            stored.removeAll{it.name==cookie.name&&it.domain==cookie.domain&&it.path==cookie.path}
            stored.add(cookie)
        }
    }
    @Synchronized override fun loadForRequest(url:HttpUrl):List<Cookie> {
        val now=System.currentTimeMillis()
        stored.removeAll{it.expiresAt<now}
        return stored.filter{it.matches(url)}
    }
    /** One Cookie header value, as a browser sends it, or null when the page set none. */
    fun header(url:HttpUrl):String?=loadForRequest(url).takeIf{it.isNotEmpty()}?.joinToString("; "){"${it.name}=${it.value}"}
}
