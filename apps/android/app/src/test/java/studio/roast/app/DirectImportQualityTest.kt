package studio.roast.app

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class DirectImportQualityTest {
    @Test fun fullHdAndFourKUprightRastersKeepTheirOriginalGeometry() {
        listOf(1920 to 1080,1080 to 1920,3840 to 2160,2160 to 3840,2560 to 1440,1080 to 1080).forEach{(w,h)->
            assertTrue(DirectImportPolicy.matches(18.947,w,h,true,ExpectedMedia(18.947,w,h,true)))
        }
        listOf(3841 to 2160,3840 to 2161,2161 to 3840,4096 to 2160,0 to 1080).forEach{(w,h)->
            assertFalse(DirectImportPolicy.matches(18.947,w,h,true,ExpectedMedia(null,null,null,true)))
        }
        assertFalse(DirectImportPolicy.matches(18.947,1920,1080,true,ExpectedMedia(18.947,3840,2160,true)))
    }
    @Test fun manifestAcceptsPortraitAndLandscapeFourKWithoutLooseningBudgetOrDuration() {
        listOf(3840 to 2160,2160 to 3840).forEach{(w,h)->
            val plan=DirectImportPolicy.plan(manifest(w,h),1000)
            assertEquals(w,plan.expected.width);assertEquals(h,plan.expected.height)
            assertEquals(250L*1024*1024,plan.maxBytes)
        }
        assertThrows(IllegalArgumentException::class.java){DirectImportPolicy.plan(manifest(3840,2161),1000)}
        assertFalse(DirectImportPolicy.matches(3601.0,3840,2160,true,ExpectedMedia(null,null,null,true)))
    }
    @Test fun sampledOriginalCadencesThroughSixtyIncludingFractionalRatesAreAcceptedUnchanged() {
        listOf(24.0,29.97,30.0,50.0,59.94,60.0).forEach{fps->
            val pts=List(120){(it*1_000_000.0/fps).toLong()};val original=pts.toList()
            assertTrue("$fps",DirectImportPolicy.frameTimingAllowed((120*1_000_000.0/fps).toLong(),pts))
            assertEquals(original,pts)
            assertEquals(pts,MuxTiming.origin(listOf(0)).let{origin->pts.map{MuxTiming.timestamp(it,origin)}})
        }
    }
    @Test fun aboveSixtyAndDuplicateTimestampsAreRejectedWhileBFrameDecodeOrderIsPreserved() {
        assertFalse(DirectImportPolicy.frameTimingAllowed(2_000_000,List(122){(it*1_000_000.0/61).toLong()}))
        assertFalse(DirectImportPolicy.frameTimingAllowed(1_000_000,listOf(0,0,33333)))
        assertFalse(DirectImportPolicy.frameTimingAllowed(0,listOf(0)))
        assertFalse(DirectImportPolicy.frameTimingAllowed(1_000_000,emptyList()))
        val bFrames=listOf(0L,50000L,16667L,33333L,100000L,66667L,83333L)
        assertTrue(DirectImportPolicy.frameTimingAllowed(116667,bFrames))
        assertEquals(listOf(0L,50000L,16667L,33333L,100000L,66667L,83333L),bFrames)
    }
    @Test fun highProfileLevel52RemainsEightBit420AndHigherLevelOrBitDepthDoesNotSlipThrough() {
        val high52=byteArrayOf(0x67,100,0,52,0xac.toByte())
        assertTrue(AvcFormatPolicy.eightBit420(byteArrayOf(0,0,0,1)+high52))
        assertTrue(AvcFormatPolicy.eightBit420(byteArrayOf(1,100,0,52,0xff.toByte(),0xe1.toByte(),0,5)+high52))
        assertFalse(AvcFormatPolicy.eightBit420(byteArrayOf(0x67,100,0,60,0xac.toByte())))
        assertFalse(AvcFormatPolicy.eightBit420(byteArrayOf(0x67,100,0,52,0xa7.toByte())))
        assertFalse(AvcFormatPolicy.eightBit420(byteArrayOf(0x67,100,0,52,0xbc.toByte())))
    }
    private fun manifest(w:Int,h:Int)=JSONObject().put("platform","x").put("expiresAt",Instant.ofEpochMilli(100000).toString())
        .put("delivery",JSONObject().put("kind","direct").put("assets",JSONArray().put(JSONObject().put("role","muxed")
            .put("url","https://video.twimg.com/original.mp4").put("headers",JSONObject())))
            .put("expected",JSONObject().put("hasAudio",true).put("width",w).put("height",h).put("duration",18.947))
            .put("maxBytes",250L*1024*1024))
}
