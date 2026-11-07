package studio.roast.app

import org.json.JSONObject
import java.net.URI
import java.time.Instant
import kotlin.math.abs

internal data class DirectAsset(val role:String,val url:String,val headers:Map<String,String>) {
    override fun toString()="DirectAsset(role=$role, url=[redacted], headers=[redacted])"
}
internal enum class VideoCodec(val wire:String) {
    H264("h264"),HEVC("hevc"),VP9("vp9"),AV1("av1"),Unknown("unknown");
    companion object {
        fun fromMime(mime:String?)=when(mime) {
            "video/avc"->H264;"video/hevc"->HEVC;"video/x-vnd.on2.vp9"->VP9;"video/av01"->AV1;else->Unknown
        }
    }
}
internal enum class AudioCodec(val wire:String) {AacLc("aac-lc"),HeAac("he-aac"),Aac("aac"),Unknown("unknown"),None("none")}
internal data class ExpectedMedia(val duration:Double?,val width:Int?,val height:Int?,val hasAudio:Boolean,
    val fps:Double?=null,val videoCodec:VideoCodec?=null,val audioCodec:AudioCodec?=null)
/** One downloadable set: a muxed file, or separate video + audio files. */
internal data class DirectAssetSet(val assets:List<DirectAsset>,val expected:ExpectedMedia)
/** Hybrid manifest: the primary set (converted on the phone when [convert]) and an optional directly playable fallback. */
internal data class DirectPlan(val platform:String,val assets:List<DirectAsset>,val expected:ExpectedMedia,val maxBytes:Long,
    val convert:Boolean=false,val fallback:DirectAssetSet?=null) {
    val primary get()=DirectAssetSet(assets,expected)
}
internal sealed interface ImportChoice {
    data object Primary:ImportChoice
    data object Fallback:ImportChoice
    data class Unsupported(val message:String):ImportChoice
}
internal object DirectImportPolicy {
    const val UNSUPPORTED_FORMAT="This phone can't convert this video's format. Try another link."
    const val MAX_BYTES=2L*1024*1024*1024
    /** One whole prepared, combined, local or stored file; keeps the earlier ~1.9x headroom over MAX_BYTES. */
    const val MAX_FILE_BYTES=4_000_000_000L
    const val MAX_DURATION=3600.0
    const val MAX_DURATION_US=3_600_000_000L
    /** Same 0.2 s measurement slack as the server and iOS (3600.2 s). */
    const val MAX_DURATION_TOLERANCE=0.2
    const val MAX_DURATION_TOLERANCE_US=200_000L
    const val MAX_LONG_SIDE=3840
    const val MAX_SHORT_SIDE=2160
    private fun below(host:String,suffix:String)=host==suffix||host.endsWith(".$suffix")
    fun allowedUrl(value:String,platform:String):Boolean=runCatching {
        if(value.length>16384 || value.any{it.code<32||it.code==127})return false
        val uri=URI(value);val host=uri.host?.lowercase(java.util.Locale.ROOT) ?: return false
        if(uri.scheme!="https"||uri.port !in listOf(-1,443)||uri.rawUserInfo!=null||uri.rawFragment!=null||host.endsWith('.'))return false
        when(platform) {
            "instagram"->listOf("cdninstagram.com","fbcdn.net").any{below(host,it)}
            "youtube"->below(host,"googlevideo.com")
            "x"->host=="video.twimg.com"
            "tiktok"->listOf("tiktokcdn.com","tiktokcdn-us.com","tiktokcdn-eu.com","tiktokv.com","ibytedtos.com","byteoversea.com").any{below(host,it)} ||
                host.matches(Regex("^v[0-9]+-webapp-prime\\.tiktok\\.com$"))
            else->false
        }
    }.getOrDefault(false)
    fun headers(json:JSONObject,platform:String?=null):Map<String,String> {
        require(json.length()<=4)
        return json.keys().asSequence().associate {key->
            // Only the phone's own TikTok lookup sends the page cookie; server manifests never contain one.
            require(key in listOf("User-Agent","Referer","Origin","Accept")||platform=="tiktok"&&key=="Cookie") {"Unsupported video headers."}
            val value=json.get(key) as? String ?: error("Invalid video header.")
            require(value.length<=2048 && value.none{it.code<32||it.code==127}) {"Invalid video header."}
            key to value
        }
    }
    fun plan(json:JSONObject,now:Long=System.currentTimeMillis()):DirectPlan {
        val expires=Instant.parse(json.getString("expiresAt")).toEpochMilli()
        require(expires>now && expires-now<=330_000) {"This video link expired."}
        val delivery=json.getJSONObject("delivery");require(delivery.getString("kind")=="direct")
        val platform=json.getString("platform")
        val primary=assetSet(delivery,platform)
        val limit=delivery.getLong("maxBytes");require(limit in 1..MAX_BYTES)
        val convert=if(delivery.has("convert")&&!delivery.isNull("convert"))delivery.get("convert").let{require(it is Boolean);it as Boolean}else false
        val fallback=if(delivery.has("fallback")&&!delivery.isNull("fallback"))assetSet(delivery.getJSONObject("fallback"),platform)else null
        return DirectPlan(platform,primary.assets,primary.expected,limit,convert,fallback)
    }
    /** The same host, header, role, raster and duration rules for the primary and the fallback set. */
    private fun assetSet(source:JSONObject,platform:String):DirectAssetSet {
        val values=source.getJSONArray("assets")
        require(values.length() in 1..2)
        val assets=(0 until values.length()).map {index->values.getJSONObject(index).let{asset->
            val url=asset.getString("url");require(allowedUrl(url,platform)) {"Unsupported video download address."}
            DirectAsset(asset.getString("role"),url,headers(asset.optJSONObject("headers")?:JSONObject(),platform))
        }}
        require(assets.map{it.role}==listOf("muxed") || assets.map{it.role}.toSet()==setOf("video","audio")&&assets.size==2)
        val expected=source.getJSONObject("expected")
        require(expected.get("hasAudio") is Boolean)
        fun present(key:String)=expected.has(key)&&!expected.isNull(key)
        fun dimension(key:String)=if(expected.has(key))expected.getInt(key).also{require(it in 1..MAX_LONG_SIDE)}else null
        val duration=if(expected.has("duration"))expected.getDouble("duration").also{require(it.isFinite()&&it>0&&it<=MAX_DURATION+MAX_DURATION_TOLERANCE)}else null
        val fps=if(present("fps"))expected.getDouble("fps").also{require(it.isFinite()&&it>0)}else null
        val videoCodec=if(present("videoCodec"))expected.getString("videoCodec").let{wire->requireNotNull(VideoCodec.entries.firstOrNull{it.wire==wire})}else null
        val audioCodec=if(present("audioCodec"))expected.getString("audioCodec").let{wire->requireNotNull(AudioCodec.entries.firstOrNull{it.wire==wire})}else null
        val info=ExpectedMedia(duration,dimension("width"),dimension("height"),expected.getBoolean("hasAudio"),fps,videoCodec,audioCodec)
        if(info.width!=null&&info.height!=null)require(rasterAllowed(info.width,info.height)) {"The source dimensions need conversion."}
        if(assets.size==2)require(info.hasAudio)
        return DirectAssetSet(assets,info)
    }
    /**
     * Hybrid rule on this phone: a plain plan downloads its primary; a conversion plan downloads the
     * original when this phone decodes its codec (an unknown codec is decided after download),
     * otherwise the directly playable fallback, otherwise nothing.
     */
    fun choose(plan:DirectPlan,canDecode:(VideoCodec,Int?,Int?,Double?)->Boolean):ImportChoice {
        if(!plan.convert)return ImportChoice.Primary
        val expected=plan.expected;val codec=expected.videoCodec
        if(codec==null||codec==VideoCodec.Unknown||canDecode(codec,expected.width,expected.height,expected.fps))return ImportChoice.Primary
        return if(plan.fallback!=null)ImportChoice.Fallback else ImportChoice.Unsupported(UNSUPPORTED_FORMAT)
    }
    fun apiFile(base:String,value:String):Boolean=runCatching {
        val origin=URI(base);val uri=URI(value)
        fun port(u:URI)=if(u.port>=0)u.port else if(u.scheme=="https")443 else 80
        uri.scheme in listOf("http","https")&&uri.scheme==origin.scheme&&uri.host.equals(origin.host,true)&&port(uri)==port(origin)&&
            uri.rawUserInfo==null&&uri.rawFragment==null&&uri.rawQuery==null&&
            uri.rawPath.matches(Regex(Regex.escape(origin.rawPath.orEmpty().trimEnd('/'))+"/v1/media/[a-f0-9]{24}/file"))
    }.getOrDefault(false)
    fun matches(duration:Double,width:Int,height:Int,audio:Boolean,expected:ExpectedMedia):Boolean =
        duration.isFinite()&&duration>0&&duration<=MAX_DURATION+MAX_DURATION_TOLERANCE&&rasterAllowed(width,height)&&audio==expected.hasAudio&&
            (expected.duration==null||abs(duration-expected.duration)<=durationTolerance(expected.duration))&&
            (expected.width==null||width==expected.width)&&(expected.height==null||height==expected.height)
    fun durationTolerance(expected:Double)=maxOf(if(expected%1.0==0.0)1.05 else .35,expected*.005)
    fun rasterAllowed(width:Int,height:Int)=minOf(width,height)>0&&maxOf(width,height)<=MAX_LONG_SIDE&&minOf(width,height)<=MAX_SHORT_SIDE
    /** Inspect real sample timestamps; never rewrite them or impose an output frame rate. */
    fun frameTimingAllowed(durationUs:Long,presentationTimes:List<Long>):Boolean {
        if(durationUs<=0||presentationTimes.isEmpty())return false
        val ordered=presentationTimes.sorted()
        return presentationTimes.size/(durationUs/1_000_000.0)<=60.05&&
            ordered.zipWithNext().all{(x,y)->y-x>=16_000}
    }
}

/** Pure H.264 output settings for on-device conversion. */
internal object ConversionPolicy {
    /** Source video data rate x1.6 for VP9/AV1 or x1.3 for HEVC, clamped by the output's short side. */
    fun videoBitrate(sourceBitsPerSecond:Long,codec:VideoCodec,width:Int,height:Int):Int {
        val factor=when(codec){VideoCodec.VP9,VideoCodec.AV1->1.6;VideoCodec.HEVC->1.3;else->1.0}
        val short=minOf(width,height)
        val (low,high)=when {
            short<=720->1_500_000L to 8_000_000L
            short<=1080->3_000_000L to 12_000_000L
            else->12_000_000L to 40_000_000L
        }
        return (sourceBitsPerSecond.coerceAtLeast(0)*factor).toLong().coerceIn(low,high).toInt()
    }
    private val levels=listOf(Triple(31,3600L,108_000.0),Triple(32,5120L,216_000.0),Triple(40,8192L,245_760.0),
        Triple(42,8704L,522_240.0),Triple(50,22080L,589_824.0),Triple(51,36864L,983_040.0),Triple(52,36864L,2_073_600.0))
    /** Lowest H.264 level_idc (3.1 to 5.2) for the frame size and rate, so the output stays within the existing level rule. */
    fun avcLevel(width:Int,height:Int,fps:Double):Int? {
        if(width<=0||height<=0||!fps.isFinite()||fps<=0)return null
        val macroblocks=((width+15)/16).toLong()*((height+15)/16)
        return levels.firstOrNull{(_,frame,rate)->macroblocks<=frame&&macroblocks*fps<=rate}?.first
    }
}

/** One shared origin retains A/V offsets. Never zero each source track independently. */
internal object MuxTiming {
    fun origin(firstSamples:List<Long>):Long {require(firstSamples.isNotEmpty());return minOf(0,firstSamples.min())}
    fun timestamp(source:Long,origin:Long):Long=(source-origin).also{require(it>=0)}
    fun compatibleDurations(video:Double,audio:Double)=abs(video-audio)<=maxOf(1.0,minOf(2.0,video*.01))
}

internal object AvcFormatPolicy {
    fun eightBit420(csd:ByteArray):Boolean=runCatching {
        val nal=findSps(csd) ?: return false
        val unescaped=ArrayList<Int>();var zeros=0
        nal.drop(1).forEach {byte->val value=byte.toInt() and 255
            if(zeros>=2&&value==3){zeros=0}else{unescaped.add(value);zeros=if(value==0)zeros+1 else 0}}
        if(unescaped.size<4)return false
        val profile=unescaped[0]
        if(unescaped[2] !in setOf(9,10,11,12,13,20,21,22,30,31,32,40,41,42,50,51,52))return false
        if(profile in listOf(66,77,88))return true
        if(profile!=100)return false
        val bits=Bits(unescaped.drop(3));bits.ue() // seq_parameter_set_id
        val chroma=bits.ue();if(chroma!=1)return false
        bits.ue()==0&&bits.ue()==0
    }.getOrDefault(false)
    private fun findSps(bytes:ByteArray):ByteArray? {
        if(bytes.isNotEmpty()&&bytes[0].toInt() and 31==7)return bytes
        for(i in 0 until bytes.size-4) {
            val start=when {
                bytes[i]==0.toByte()&&bytes[i+1]==0.toByte()&&bytes[i+2]==1.toByte()->i+3
                bytes[i]==0.toByte()&&bytes[i+1]==0.toByte()&&bytes[i+2]==0.toByte()&&bytes[i+3]==1.toByte()->i+4
                else->continue
            }
            if(start<bytes.size&&bytes[start].toInt() and 31==7)return bytes.copyOfRange(start,bytes.size)
        }
        if(bytes.size>8&&bytes[0]==1.toByte()) {
            val size=((bytes[6].toInt() and 255) shl 8) or (bytes[7].toInt() and 255)
            if(size>0&&size<=bytes.size-8&&bytes[8].toInt() and 31==7)return bytes.copyOfRange(8,8+size)
        }
        return null
    }
    private class Bits(private val bytes:List<Int>) {
        private var position=0
        private fun bit():Int {require(position<bytes.size*8);val value=(bytes[position/8] shr (7-position%8)) and 1;position++;return value}
        fun ue():Int {var zeros=0;while(bit()==0){zeros++;require(zeros<24)};var value=1;repeat(zeros){value=(value shl 1) or bit()};return value-1}
    }
}
