package studio.roast.app

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.URI

class TikTokPhoneResolverTest {
    private val id="7412345678901234567"
    private val cookie="msToken=abc; tt_chain_token=def"
    private val now=1_000_000L

    @Test fun h264OnlyPageBecomesADirectlyPlayableManifestWithThePageCookie() {
        val json=TikTokPhoneResolver.manifest(page(item(listOf(stream("h264",720,1280,1_200_000,"v19-webapp-prime"),stream("h264",540,960,600_000)))),id,cookie,now)
        assertEquals("tiktok",json.getString("platform"))
        assertEquals(2,json.getInt("qualityVersion"))
        assertEquals("A fixture clip",json.getString("title"))
        assertEquals(15.0,json.getDouble("duration"),0.0)
        assertEquals("https://www.tiktok.com/@creator/video/$id",json.getString("sourceUrl"))
        val plan=DirectImportPolicy.plan(json,now)
        assertFalse(plan.convert);assertNull(plan.fallback)
        assertEquals(DirectImportPolicy.MAX_BYTES,plan.maxBytes)
        val asset=plan.assets.single()
        assertEquals("muxed",asset.role)
        assertEquals("The largest H.264 raster is the playable set","v19-webapp-prime.tiktok.com",URI(asset.url).host)
        assertEquals(cookie,asset.headers["Cookie"])
        assertEquals("https://www.tiktok.com/",asset.headers["Referer"])
        assertEquals(TikTokPhoneResolver.USER_AGENT,asset.headers["User-Agent"])
        assertEquals(ExpectedMedia(15.0,720,1280,true,null,VideoCodec.Unknown,AudioCodec.Unknown),plan.expected)
        assertEquals(ImportChoice.Primary,DirectImportPolicy.choose(plan){_,_,_,_->false})
    }
    @Test fun betterHevcOriginalIsConvertedWithTheH264AsFallback() {
        val json=TikTokPhoneResolver.manifest(page(item(listOf(stream("bytevc1",1080,1920,2_000_000,"v19-webapp-prime"),stream("h264",720,1280,1_200_000)))),id,cookie,now)
        val plan=DirectImportPolicy.plan(json,now)
        assertTrue(plan.convert)
        assertEquals("v19-webapp-prime.tiktok.com",URI(plan.assets.single().url).host)
        assertEquals(1080,plan.expected.width)
        val fallback=checkNotNull(plan.fallback)
        assertEquals(720,fallback.expected.width)
        assertEquals(cookie,fallback.assets.single().headers["Cookie"])
        // The codec is "unknown", so the original is downloaded and decided after the download.
        assertEquals(ImportChoice.Primary,DirectImportPolicy.choose(plan){_,_,_,_->false})
    }
    @Test fun nothingAbove1080pIsUsedAndThe1080pH264PlaysDirectly() {
        val json=TikTokPhoneResolver.manifest(page(item(listOf(stream("bytevc1",2160,3840,6_000_000,"v19-webapp-prime"),stream("h264",1080,1920,2_500_000)))),id,cookie,now)
        val plan=DirectImportPolicy.plan(json,now)
        assertFalse(plan.convert);assertNull(plan.fallback)
        assertEquals(1080,plan.expected.width)
        assertEquals("v16-webapp-prime.tiktok.com",URI(plan.assets.single().url).host)
    }
    @Test fun hevcWithTheSameRasterKeepsThePlayableH264() {
        val json=TikTokPhoneResolver.manifest(page(item(listOf(stream("h265_hvc1",720,1280,900_000,"v19-webapp-prime"),stream("h264",720,1280,1_200_000)))),id,cookie,now)
        val plan=DirectImportPolicy.plan(json,now)
        assertFalse(plan.convert);assertNull(plan.fallback)
        assertEquals("v16-webapp-prime.tiktok.com",URI(plan.assets.single().url).host)
    }
    @Test fun unavailableAgeRestrictedLongAndUnusablePagesExplainWhy() {
        assertEquals(TikTokPhoneResolver.UNAVAILABLE,message(page(JSONObject().put("statusCode",10204).put("statusMsg","item doesn't exist"))))
        assertEquals(TikTokPhoneResolver.AGE_RESTRICTED,message(page(item(listOf(stream("h264",720,1280,1)),classified=true))))
        assertEquals("Choose a video under 60 minutes.",message(page(item(listOf(stream("h264",720,1280,1)),duration=3601))))
        assertEquals(TikTokPhoneResolver.UNUSABLE,message("<html><body>Please wait…</body></html>"))
        assertEquals(TikTokPhoneResolver.UNUSABLE,message(page(item(emptyList(),playAddr=null))))
        assertEquals("This TikTok video is private or unavailable.",TikTokPhoneResolver.UNAVAILABLE)
        assertEquals("This TikTok video is age-restricted and can't be imported.",TikTokPhoneResolver.AGE_RESTRICTED)
        assertEquals("This TikTok video couldn't be opened. Try another link.",TikTokPhoneResolver.UNUSABLE)
    }
    @Test fun videoIdsComeFromCanonicalLinksAndShortLinksMustBeFollowed() {
        assertEquals(id,TikTokPhoneResolver.videoId("https://www.tiktok.com/@someone/video/$id?is_from_webapp=1&sender_device=pc"))
        assertEquals(id,TikTokPhoneResolver.videoId("https://m.tiktok.com/@i/video/$id"))
        listOf("https://vt.tiktok.com/ZSabc123/","https://vm.tiktok.com/ZMdef456/","https://www.tiktok.com/t/ZTghi789/",
            "https://www.tiktok.com/@someone","https://www.tiktok.com/@someone/video/notanumber","https://example.com/@a/video/$id")
            .forEach{assertNull(it,TikTokPhoneResolver.videoId(it))}
        assertTrue(TikTokPhoneResolver.handles("https://vt.tiktok.com/ZSabc123/"))
        assertTrue(TikTokPhoneResolver.handles("https://www.tiktok.com/t/ZTghi789/"))
        assertFalse(TikTokPhoneResolver.handles("https://tiktok.com.evil.test/@a/video/$id"))
        assertFalse(TikTokPhoneResolver.handles("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    }
    @Test fun cookieHeaderIsAllowedOnlyForTikTok() {
        val headers=DirectImportPolicy.headers(JSONObject().put("Cookie",cookie).put("Referer","https://www.tiktok.com/"),"tiktok")
        assertEquals(cookie,headers["Cookie"])
        listOf("youtube","instagram","x",null).forEach{platform->
            assertThrows(IllegalArgumentException::class.java){DirectImportPolicy.headers(JSONObject().put("Cookie",cookie),platform)}
        }
    }
    @Test fun webappPrimeHostsFollowTheNumberedPatternOnly() {
        listOf("v16-webapp-prime.tiktok.com","v19-webapp-prime.tiktok.com","v45-webapp-prime.tiktok.com")
            .forEach{assertTrue(it,DirectImportPolicy.allowedUrl("https://$it/video/a.mp4","tiktok"))}
        listOf("v-webapp-prime.tiktok.com","v16a-webapp-prime.tiktok.com","xv16-webapp-prime.tiktok.com","v16-webapp-prime.tiktok.com.evil.test","www.tiktok.com")
            .forEach{assertFalse(it,DirectImportPolicy.allowedUrl("https://$it/video/a.mp4","tiktok"))}
        assertFalse(DirectImportPolicy.allowedUrl("https://v16-webapp-prime.tiktok.com/video/a.mp4","youtube"))
    }

    private fun stream(codec:String,width:Int,height:Int,bitrate:Int,host:String="v16-webapp-prime")=JSONObject().put("CodecType",codec).put("Bitrate",bitrate)
        .put("PlayAddr",JSONObject().put("Width",width).put("Height",height).put("UrlList",JSONArray().put("https://$host.tiktok.com/video/tos/$codec-$width.mp4?sig=1")))
    private fun item(bitrates:List<JSONObject>,duration:Int=15,playAddr:String?="https://v16-webapp-prime.tiktok.com/video/tos/play.mp4?sig=1",
        classified:Boolean=false):JSONObject {
        val video=JSONObject().put("width",576).put("height",1024).put("duration",duration).put("bitrateInfo",JSONArray().apply{bitrates.forEach{put(it)}})
        if(playAddr!=null)video.put("playAddr",playAddr)
        return JSONObject().put("statusCode",0).put("statusMsg","ok").put("itemInfo",JSONObject().put("itemStruct",JSONObject()
            .put("id",id).put("desc","  A fixture clip ").put("author",JSONObject().put("uniqueId","creator"))
            .put("isContentClassified",classified).put("video",video)))
    }
    private fun page(detail:JSONObject)="<html><head><script id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__\" type=\"application/json\">"+
        JSONObject().put("__DEFAULT_SCOPE__",JSONObject().put("webapp.video-detail",detail)).toString()+"</script></head><body></body></html>"
    private fun message(html:String):String?=try{TikTokPhoneResolver.manifest(html,id,cookie,now);null}catch(e:Exception){e.message}
}
