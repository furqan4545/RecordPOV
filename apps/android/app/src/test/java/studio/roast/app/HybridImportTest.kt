package studio.roast.app

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class HybridImportTest {
    @Test fun manifestWithoutHybridFieldsStillParsesAsAPlainDirectPlan() {
        val plan=DirectImportPolicy.plan(manifest(),1000)
        assertFalse(plan.convert);assertNull(plan.fallback)
        assertNull(plan.expected.fps);assertNull(plan.expected.videoCodec);assertNull(plan.expected.audioCodec)
        assertEquals(listOf("muxed"),plan.assets.map{it.role})
        assertEquals(ImportChoice.Primary,DirectImportPolicy.choose(plan){_,_,_,_->fail("plain plans need no decoder check");false})
    }
    @Test fun hybridManifestParsesConvertCodecsAndFallback() {
        val json=manifest(split(expected(1080,1920,"vp9","he-aac").put("fps",30.0)))
        json.getJSONObject("delivery").put("convert",true).put("fallback",JSONObject()
            .put("assets",JSONArray().put(asset("muxed","https://scontent.cdninstagram.com/fallback.mp4")))
            .put("expected",expected(720,1280,"h264","aac-lc")))
        val plan=DirectImportPolicy.plan(json,1000)
        assertTrue(plan.convert)
        assertEquals(ExpectedMedia(18.0,1080,1920,true,30.0,VideoCodec.VP9,AudioCodec.HeAac),plan.expected)
        assertEquals(setOf("video","audio"),plan.assets.map{it.role}.toSet())
        val fallback=checkNotNull(plan.fallback)
        assertEquals(listOf("muxed"),fallback.assets.map{it.role})
        assertEquals(ExpectedMedia(18.0,720,1280,true,null,VideoCodec.H264,AudioCodec.AacLc),fallback.expected)
        assertEquals(DirectAssetSet(plan.assets,plan.expected),plan.primary)
    }
    @Test fun unknownCodecProgressiveFallbackParsesWithoutGeometry() {
        val json=manifest(split(expected(1080,1920,"vp9","he-aac")))
        json.getJSONObject("delivery").put("convert",true).put("fallback",JSONObject()
            .put("assets",JSONArray().put(asset("muxed","https://scontent.cdninstagram.com/3.mp4")))
            .put("expected",JSONObject().put("hasAudio",true).put("videoCodec","unknown").put("audioCodec","unknown")))
        val fallback=checkNotNull(DirectImportPolicy.plan(json,1000).fallback)
        assertEquals(ExpectedMedia(null,null,null,true,null,VideoCodec.Unknown,AudioCodec.Unknown),fallback.expected)
    }
    @Test fun fallbackSetUsesTheSameHostHeaderRoleRasterAndDurationRules() {
        fun withFallback(assets:JSONArray,expected:JSONObject)=manifest(split(expected(1080,1920,"av1","aac-lc"))).apply {
            getJSONObject("delivery").put("convert",true).put("fallback",JSONObject().put("assets",assets).put("expected",expected))
        }
        val good=JSONArray().put(asset("muxed","https://scontent.cdninstagram.com/ok.mp4"))
        assertNotNull(DirectImportPolicy.plan(withFallback(good,expected(720,1280,"h264","aac-lc")),1000).fallback)
        listOf(
            withFallback(JSONArray().put(asset("muxed","https://video.twimg.com/elsewhere.mp4")),expected(720,1280,"h264","aac-lc")),
            withFallback(JSONArray().put(asset("muxed","http://scontent.cdninstagram.com/plain.mp4")),expected(720,1280,"h264","aac-lc")),
            withFallback(JSONArray().put(asset("muxed","https://scontent.cdninstagram.com/ok.mp4").put("headers",JSONObject().put("Cookie","secret"))),expected(720,1280,"h264","aac-lc")),
            withFallback(JSONArray().put(asset("video","https://scontent.cdninstagram.com/v.mp4")),expected(720,1280,"h264","aac-lc")),
            withFallback(JSONArray().put(asset("muxed","https://scontent.cdninstagram.com/a.mp4")).put(asset("audio","https://scontent.cdninstagram.com/b.m4a")),expected(720,1280,"h264","aac-lc")),
            withFallback(JSONArray(),expected(720,1280,"h264","aac-lc")),
            withFallback(good,expected(3841,2160,"h264","aac-lc")),
            withFallback(good,expected(2161,3840,"h264","aac-lc")),
            withFallback(good,expected(720,1280,"h264","aac-lc").put("duration",3600.3)),
            withFallback(good,expected(720,1280,"mpeg2","aac-lc")),
            withFallback(good,expected(720,1280,"h264","opus")),
            withFallback(good,expected(720,1280,"h264","aac-lc").put("fps",0)),
            withFallback(good,JSONObject().put("width",720))
        ).forEach{json->assertThrows(Exception::class.java){DirectImportPolicy.plan(json,1000)}}
        assertThrows(IllegalArgumentException::class.java){DirectImportPolicy.plan(manifest().apply{getJSONObject("delivery").put("convert","yes")},1000)}
    }
    @Test fun everyPlanAcceptsTheTwoGibBudget() {
        val json=manifest().apply{getJSONObject("delivery").put("maxBytes",DirectImportPolicy.MAX_BYTES)}
        assertEquals(2_147_483_648L,DirectImportPolicy.plan(json,1000).maxBytes)
        assertThrows(IllegalArgumentException::class.java){DirectImportPolicy.plan(manifest().apply{getJSONObject("delivery").put("maxBytes",DirectImportPolicy.MAX_BYTES+1)},1000)}
    }
    @Test fun choiceDownloadsTheOriginalOnlyWhenThisPhoneDecodesIt() {
        val fallback=DirectAssetSet(listOf(DirectAsset("muxed","https://scontent.cdninstagram.com/f.mp4",emptyMap())),ExpectedMedia(18.0,720,1280,true,null,VideoCodec.H264,AudioCodec.AacLc))
        fun plan(codec:VideoCodec?,convert:Boolean=true,withFallback:Boolean=true)=DirectPlan("instagram",
            listOf(DirectAsset("video","https://scontent.cdninstagram.com/v.mp4",emptyMap()),DirectAsset("audio","https://scontent.cdninstagram.com/a.m4a",emptyMap())),
            ExpectedMedia(18.0,1080,1920,true,30.0,codec,AudioCodec.HeAac),DirectImportPolicy.MAX_BYTES,convert,if(withFallback)fallback else null)
        val asked=mutableListOf<List<Any?>>()
        val decodes={codec:VideoCodec,w:Int?,h:Int?,fps:Double?->asked.add(listOf(codec,w,h,fps));true}
        assertEquals(ImportChoice.Primary,DirectImportPolicy.choose(plan(VideoCodec.VP9),decodes))
        assertEquals(listOf(listOf<Any?>(VideoCodec.VP9,1080,1920,30.0)),asked)
        val none={_:VideoCodec,_:Int?,_:Int?,_:Double?->false}
        assertEquals(ImportChoice.Fallback,DirectImportPolicy.choose(plan(VideoCodec.AV1),none))
        assertEquals(ImportChoice.Fallback,DirectImportPolicy.choose(plan(VideoCodec.HEVC),none))
        assertEquals(ImportChoice.Unsupported("This phone can't convert this video's format. Try another link."),
            DirectImportPolicy.choose(plan(VideoCodec.VP9,withFallback=false),none))
        // Unknown codecs are decided after download by inspecting the file.
        assertEquals(ImportChoice.Primary,DirectImportPolicy.choose(plan(VideoCodec.Unknown,withFallback=false),none))
        assertEquals(ImportChoice.Primary,DirectImportPolicy.choose(plan(null,withFallback=false),none))
        // A directly playable primary never needs a decoder check.
        assertEquals(ImportChoice.Primary,DirectImportPolicy.choose(plan(VideoCodec.H264,convert=false,withFallback=false),none))
    }
    @Test fun codecMimesMapToManifestCodecs() {
        assertEquals(VideoCodec.H264,VideoCodec.fromMime("video/avc"))
        assertEquals(VideoCodec.HEVC,VideoCodec.fromMime("video/hevc"))
        assertEquals(VideoCodec.VP9,VideoCodec.fromMime("video/x-vnd.on2.vp9"))
        assertEquals(VideoCodec.AV1,VideoCodec.fromMime("video/av01"))
        assertEquals(VideoCodec.Unknown,VideoCodec.fromMime("video/mp4v-es"));assertEquals(VideoCodec.Unknown,VideoCodec.fromMime(null))
    }
    @Test fun convertedBitrateFollowsTheSourceWithinPerRasterClamps() {
        assertEquals(4_800_000,ConversionPolicy.videoBitrate(3_000_000,VideoCodec.VP9,1080,1920))
        assertEquals(4_800_000,ConversionPolicy.videoBitrate(3_000_000,VideoCodec.AV1,1920,1080))
        assertEquals(3_900_000,ConversionPolicy.videoBitrate(3_000_000,VideoCodec.HEVC,1080,1920))
        assertEquals(3_000_000,ConversionPolicy.videoBitrate(500_000,VideoCodec.VP9,1080,1920))
        assertEquals(12_000_000,ConversionPolicy.videoBitrate(20_000_000,VideoCodec.VP9,1080,1920))
        assertEquals(1_500_000,ConversionPolicy.videoBitrate(200_000,VideoCodec.VP9,720,1280))
        assertEquals(8_000_000,ConversionPolicy.videoBitrate(9_000_000,VideoCodec.HEVC,1280,720))
        assertEquals(12_000_000,ConversionPolicy.videoBitrate(1_000_000,VideoCodec.AV1,2160,3840))
        assertEquals(40_000_000,ConversionPolicy.videoBitrate(60_000_000,VideoCodec.AV1,3840,2160))
        assertEquals(1_500_000,ConversionPolicy.videoBitrate(0,VideoCodec.Unknown,540,960))
    }
    @Test fun outputLevelStaysWithinTheExistingAvcLevelRule() {
        assertEquals(31,ConversionPolicy.avcLevel(720,1280,30.0))
        assertEquals(32,ConversionPolicy.avcLevel(1280,720,60.0))
        assertEquals(40,ConversionPolicy.avcLevel(1080,1920,30.0))
        assertEquals(42,ConversionPolicy.avcLevel(1920,1080,60.0))
        assertEquals(51,ConversionPolicy.avcLevel(3840,2160,30.0))
        assertEquals(52,ConversionPolicy.avcLevel(2160,3840,60.0))
        assertNull(ConversionPolicy.avcLevel(0,1080,30.0));assertNull(ConversionPolicy.avcLevel(1920,1080,Double.NaN))
    }

    private fun asset(role:String,url:String)=JSONObject().put("role",role).put("url",url).put("headers",JSONObject())
    private fun expected(w:Int,h:Int,video:String,audio:String)=JSONObject().put("hasAudio",true).put("duration",18.0)
        .put("width",w).put("height",h).put("videoCodec",video).put("audioCodec",audio)
    private fun split(expected:JSONObject)=JSONObject().put("kind","direct").put("assets",JSONArray()
        .put(asset("video","https://scontent.cdninstagram.com/v.mp4")).put(asset("audio","https://scontent.cdninstagram.com/a.m4a")))
        .put("expected",expected).put("maxBytes",DirectImportPolicy.MAX_BYTES)
    private fun manifest(delivery:JSONObject=JSONObject().put("kind","direct").put("assets",JSONArray()
        .put(asset("muxed","https://scontent.cdninstagram.com/v.mp4"))).put("expected",JSONObject().put("hasAudio",true)).put("maxBytes",1000))=
        JSONObject().put("platform","instagram").put("expiresAt",Instant.ofEpochMilli(100000).toString()).put("delivery",delivery)
}
