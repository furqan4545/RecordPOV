package studio.roast.app

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class DirectImportTest {
    @Test fun cdnHostsAreRestrictedPerPlatform() {
        mapOf("instagram" to listOf("https://scontent.cdninstagram.com/video.mp4","https://video.fbcdn.net/v.mp4"),
            "youtube" to listOf("https://rr1.sn-1.googlevideo.com/videoplayback?signature=private"),
            "x" to listOf("https://video.twimg.com/video.mp4"),
            "tiktok" to listOf("https://v16.tiktokcdn.com/x","https://a.tiktokcdn-us.com/x","https://a.tiktokcdn-eu.com/x","https://a.tiktokv.com/x","https://a.ibytedtos.com/x","https://a.byteoversea.com/x","https://v16-webapp-prime.tiktok.com/x","https://v19-webapp-prime.tiktok.com/x"))
            .forEach{(platform,urls)->urls.forEach{assertTrue(it,DirectImportPolicy.allowedUrl(it,platform))}}
        assertFalse(DirectImportPolicy.allowedUrl("https://video.twimg.com/v.mp4","instagram"))
    }
    @Test fun unsafeUrlAndSuffixTricksAreRejectedOnEveryRedirect() {
        listOf("http://video.twimg.com/x","https://video.twimg.com:8443/x","https://user@video.twimg.com/x",
            "https://video.twimg.com/x#token","https://video.twimg.com.evil.test/x","https://sub.video.twimg.com/x",
            "https://127.0.0.1/x","https://[::1]/x","https://video.twimg.com./x","https://evil.test/x")
            .forEach{assertFalse(it,DirectImportPolicy.allowedUrl(it,"x"))}
        assertFalse(DirectImportPolicy.allowedUrl("https://www.tiktok.com/x","tiktok"))
        assertFalse(DirectImportPolicy.allowedUrl("https://a.akamaized.net/x","tiktok"))
    }
    @Test fun headersNeverAcceptCookiesOrApiAuthorization() {
        val safe=JSONObject().put("User-Agent","Browser").put("Referer","https://www.instagram.com/").put("Origin","https://www.instagram.com").put("Accept","*/*")
        assertEquals(4,DirectImportPolicy.headers(safe).size)
        listOf("Authorization","Cookie","X-YouTube-Session-Token","X-Forwarded-For").forEach{
            assertThrows(IllegalArgumentException::class.java){DirectImportPolicy.headers(JSONObject().put(it,"secret"))}
        }
        assertThrows(IllegalArgumentException::class.java){DirectImportPolicy.headers(JSONObject().put("Referer","safe\r\nCookie: secret"))}
    }
    @Test fun preparedFilesCannotRedirectToAnotherOriginOrArbitraryApiPath() {
        val path="/v1/media/"+"a".repeat(24)+"/file"
        assertTrue(DirectImportPolicy.apiFile("https://api.recordpov.app","https://api.recordpov.app$path"))
        assertTrue(DirectImportPolicy.apiFile("http://10.0.2.2:8787","http://10.0.2.2:8787$path"))
        listOf("https://evil.test$path","http://api.recordpov.app$path","https://api.recordpov.app$path?token=secret","https://api.recordpov.app/v1/auth/session")
            .forEach{assertFalse(DirectImportPolicy.apiFile("https://api.recordpov.app",it))}
    }
    @Test fun plansRequireExactlyMuxedOrVideoPlusAudio() {
        assertEquals(1,DirectImportPolicy.plan(plan(),1000).assets.size)
        val split=plan().apply{getJSONObject("delivery").put("assets",JSONArray().put(asset("audio")).put(asset("video")))}
        assertEquals(setOf("audio","video"),DirectImportPolicy.plan(split,1000).assets.map{it.role}.toSet())
        listOf(JSONArray(),JSONArray().put(asset("audio")),JSONArray().put(asset("video")).put(asset("video")),JSONArray().put(asset("muxed")).put(asset("audio")))
            .forEach{assets->assertThrows(IllegalArgumentException::class.java){DirectImportPolicy.plan(plan().apply{getJSONObject("delivery").put("assets",assets)},1000)}}
    }
    @Test fun expiryAndAggregateByteLimitsAreMandatory() {
        assertThrows(IllegalArgumentException::class.java){DirectImportPolicy.plan(plan().put("expiresAt",Instant.ofEpochMilli(999).toString()),1000)}
        assertThrows(IllegalArgumentException::class.java){DirectImportPolicy.plan(plan().put("expiresAt",Instant.ofEpochMilli(999999).toString()),1000)}
        assertThrows(IllegalArgumentException::class.java){DirectImportPolicy.plan(plan().apply{getJSONObject("delivery").put("maxBytes",DirectImportPolicy.MAX_BYTES+1)},1000)}
        val budget=ImportByteBudget(10);budget.add(6);budget.add(4)
        assertThrows(IllegalArgumentException::class.java){budget.add(1)}
    }
    @Test fun sixtyMinuteManifestsUpToTwoGibAreAcceptedAndLongerOrLargerAreRejected() {
        fun long(duration:Double,bytes:Long)=plan().apply{getJSONObject("delivery").put("maxBytes",bytes).getJSONObject("expected").put("duration",duration)}
        assertEquals(2_147_483_648L,DirectImportPolicy.MAX_BYTES)
        val accepted=DirectImportPolicy.plan(long(3599.0,2_147_483_648L),1000)
        assertEquals(3599.0,accepted.expected.duration!!,0.0);assertEquals(2_147_483_648L,accepted.maxBytes)
        assertEquals(3600.0,DirectImportPolicy.plan(long(3600.0,1000),1000).expected.duration!!,0.0)
        assertEquals(3600.1,DirectImportPolicy.plan(long(3600.1,1000),1000).expected.duration!!,0.0)
        assertThrows(IllegalArgumentException::class.java){DirectImportPolicy.plan(long(3600.3,1000),1000)}
        assertThrows(IllegalArgumentException::class.java){DirectImportPolicy.plan(long(3601.0,1000),1000)}
        assertThrows(IllegalArgumentException::class.java){DirectImportPolicy.plan(long(3599.0,2_147_483_649L),1000)}
        assertTrue(DirectImportPolicy.MAX_FILE_BYTES>DirectImportPolicy.MAX_BYTES)
        assertEquals(3_600_000_000L,DirectImportPolicy.MAX_DURATION_US)
    }
    @Test fun expectedGeometryDurationAndAudioMustMatchActualMedia() {
        val expected=ExpectedMedia(20.0,720,1280,true)
        assertTrue(DirectImportPolicy.matches(20.1,720,1280,true,expected))
        assertFalse(DirectImportPolicy.matches(25.0,720,1280,true,expected))
        assertFalse(DirectImportPolicy.matches(20.0,1280,720,true,expected))
        assertFalse(DirectImportPolicy.matches(20.0,720,1280,false,expected))
        assertFalse(DirectImportPolicy.matches(3601.0,720,1280,true,ExpectedMedia(null,null,null,true)))
        assertTrue(DirectImportPolicy.matches(3599.0,720,1280,true,ExpectedMedia(null,null,null,true)))
        assertTrue(DirectImportPolicy.matches(3600.1,720,1280,true,ExpectedMedia(null,null,null,true)))
        assertFalse(DirectImportPolicy.matches(3600.3,720,1280,true,ExpectedMedia(null,null,null,true)))
        assertTrue(DirectImportPolicy.matches(20.0,1920,1080,true,ExpectedMedia(null,null,null,true)))
        assertTrue(DirectImportPolicy.matches(20.0,720,1280,false,ExpectedMedia(null,null,null,false)))
        assertTrue(DirectImportPolicy.matches(27.467,576,1024,true,ExpectedMedia(27.0,576,1024,true)))
        assertFalse(DirectImportPolicy.matches(27.6,576,1024,true,ExpectedMedia(27.1,576,1024,true)))
    }
    @Test fun fallbackRunsExactlyOnceAndDoesNotSwallowCancellation()=runBlocking {
        val calls=mutableListOf<String>()
        assertEquals("fallback",importWithFallback({calls+="primary";error("conversion failed")},{calls+="fallback-fresh-transfer";"fallback"}))
        assertEquals(listOf("primary","fallback-fresh-transfer"),calls)
        calls.clear()
        try{importWithFallback<String>({throw CancellationException()},{calls+="unexpected";"bad"});fail()}catch(_:CancellationException){}
        assertTrue(calls.isEmpty())
        var retries=0
        try{importWithFallback<String>({error("mux failed")},{retries++;error("fallback failed")});fail()}catch(_:IllegalStateException){}
        assertEquals(1,retries)
    }
    @Test fun muxClockPreservesInitialDelayAndBFramePresentationOrder() {
        val video=listOf(0L,100000L,33333L,66666L);val audio=listOf(20000L,43220L)
        val origin=MuxTiming.origin(listOf(video.first(),audio.first()))
        assertEquals(video,video.map{MuxTiming.timestamp(it,origin)})
        assertEquals(20000L,MuxTiming.timestamp(audio.first(),origin)-MuxTiming.timestamp(video.first(),origin))
    }
    @Test fun negativeAudioPrimingUsesOneCommonClock() {
        val origin=MuxTiming.origin(listOf(0L,-21333L))
        assertEquals(21333L,MuxTiming.timestamp(0,origin));assertEquals(0L,MuxTiming.timestamp(-21333,origin))
        assertFalse(MuxTiming.compatibleDurations(100.0,20.0));assertTrue(MuxTiming.compatibleDurations(100.0,100.2))
    }
    @Test fun spsVerifiesActualEightBit420AcrossAnnexBAndAvcConfiguration() {
        val high=byteArrayOf(0x67,100,0,31,0xac.toByte())
        assertTrue(AvcFormatPolicy.eightBit420(byteArrayOf(0,0,0,1)+high))
        assertTrue(AvcFormatPolicy.eightBit420(byteArrayOf(1,100,0,31,0xff.toByte(),0xe1.toByte(),0,5)+high))
        assertTrue(AvcFormatPolicy.eightBit420(byteArrayOf(0x67,66,0,30,0x80.toByte())))
        assertFalse(AvcFormatPolicy.eightBit420(byteArrayOf(0x67,100,0,31,0xa7.toByte()))) // ten-bit luma
        assertFalse(AvcFormatPolicy.eightBit420(byteArrayOf(0x67,100,0,31,0xbc.toByte()))) // 4:2:2 chroma
        assertFalse(AvcFormatPolicy.eightBit420(byteArrayOf(0x67,110,0,31,0xac.toByte())))
        assertFalse(AvcFormatPolicy.eightBit420(byteArrayOf(0x67,100)))
    }
    @Test fun signedAssetUrlsAreRedactedFromDiagnosticStrings() {
        val asset=DirectAsset("muxed","https://video.twimg.com/x?secret=private",mapOf("Referer" to "private"))
        assertFalse(asset.toString().contains("secret"));assertFalse(asset.toString().contains("private"))
    }
    private fun asset(role:String)=JSONObject().put("role",role).put("url","https://video.twimg.com/v.mp4").put("headers",JSONObject())
    private fun plan()=JSONObject().put("platform","x").put("expiresAt",Instant.ofEpochMilli(100000).toString()).put("delivery",JSONObject()
        .put("kind","direct").put("assets",JSONArray().put(asset("muxed"))).put("expected",JSONObject().put("hasAudio",true)).put("maxBytes",1000))
}
