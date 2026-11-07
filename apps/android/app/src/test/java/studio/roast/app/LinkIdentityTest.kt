package studio.roast.app

import org.junit.Assert.*
import org.junit.Test
import java.io.File

class LinkIdentityTest {
    @Test fun youtubeWatchShortsLiveEmbedAndShortLinkIdentifyTheSameVideo() {
        val urls=listOf("https://www.youtube.com/watch?v=jNQXAC9IVRw&si=tracking&t=30",
            "https://youtu.be/jNQXAC9IVRw?feature=shared","https://m.youtube.com/shorts/jNQXAC9IVRw/",
            "https://youtube.com/live/jNQXAC9IVRw","https://www.youtube.com/embed/jNQXAC9IVRw#start=20")
        assertEquals(setOf("youtube:jNQXAC9IVRw"),urls.map(LinkIdentity::key).toSet())
        assertFalse(LinkIdentity.same(urls.first(),"https://www.youtube.com/watch?v=bkPwFqa89gE"))
    }
    @Test fun instagramAliasesAndTrackingDoNotCreateANewVideo() {
        assertTrue(LinkIdentity.same("https://www.instagram.com/reel/Datls4XT4Hy/?igsh=one","https://instagram.com/reels/Datls4XT4Hy/?utm_source=two"))
        assertTrue(LinkIdentity.same("https://www.instagram.com/p/Datls4XT4Hy/","https://www.instagram.com/reel/Datls4XT4Hy/"))
        assertFalse(LinkIdentity.same("https://instagram.com/reel/Datls4XT4Hy/","https://instagram.com/reel/DIFFERENT12/"))
    }
    @Test fun xUsernameAndTwitterHostChangesKeepTheSameStatusIdentity() {
        assertTrue(LinkIdentity.same("https://twitter.com/first/status/123456789?s=20","https://x.com/second/status/123456789?ref_src=tracking"))
        assertTrue(LinkIdentity.same("https://x.com/i/web/status/123456789","https://x.com/second/status/123456789"))
        assertFalse(LinkIdentity.same("https://x.com/first/status/123456789","https://x.com/first/status/123456790"))
    }
    @Test fun tiktokVideoIdsAndStoredShortAliasesAreStable() {
        assertTrue(LinkIdentity.same("https://www.tiktok.com/@first/video/123456789?is_from_webapp=1","https://m.tiktok.com/@second/video/123456789?tracking=2"))
        assertTrue(LinkIdentity.same("https://vm.tiktok.com/ZShort123/?share=1","https://vt.tiktok.com/ZShort123/?share=2"))
        assertFalse(LinkIdentity.same("https://www.tiktok.com/@first/video/123456789","https://www.tiktok.com/@first/video/123456790"))
        assertFalse(LinkIdentity.same("https://vm.tiktok.com/ZShort123/","https://vm.tiktok.com/ZOther123/"))
        assertEquals("tiktok-t:ZTghi789",LinkIdentity.key("https://www.tiktok.com/t/ZTghi789/"))
    }
    @Test fun malformedUnsupportedAndAmbiguousLinksCannotRevealANewDownloadAction() {
        listOf(""," ","not a url","https://youtube.com/","https://youtube.com.evil.test/watch?v=jNQXAC9IVRw",
            "https://user@youtube.com/watch?v=jNQXAC9IVRw","https://youtube.com/watch?v=jNQXAC9IVRw&v=bkPwFqa89gE",
            "https://instagram.com/profile/","https://127.0.0.1/reel/hello/","https://example.com/video.mp4")
            .forEach{assertNull(it,LinkIdentity.key(it))}
    }
    @Test fun savedPrimaryStaysAvailableWhileTheDistinctNewVideoDownloads() {
        val existing=video("https://www.youtube.com/watch?v=jNQXAC9IVRw")
        val input="https://youtu.be/bkPwFqa89gE?si=new"
        val actions=HomeVideoPolicy.actions(existing,input,true,"https://youtube.com/watch?v=bkPwFqa89gE",false)
        assertTrue(actions.savedPrimary);assertTrue(actions.primaryEnabled);assertTrue(actions.showNewButton);assertTrue(actions.newButtonBusy)
        val same=HomeVideoPolicy.actions(existing,"https://youtu.be/jNQXAC9IVRw?si=other",false,null,false)
        assertTrue(same.primaryEnabled);assertFalse(same.showNewButton)
        assertFalse(HomeVideoPolicy.actions(existing,"",false,null,false).showNewButton)
    }
    @Test fun noSavedVideoHasOnlyOnePrimaryDownloadAction() {
        val input="https://www.instagram.com/reel/Datls4XT4Hy/"
        val idle=HomeVideoPolicy.actions(null,input,false,null,false)
        assertFalse(idle.savedPrimary);assertTrue(idle.primaryEnabled);assertFalse(idle.showNewButton)
        val active=HomeVideoPolicy.actions(null,input,true,input,false)
        assertFalse(active.primaryEnabled);assertFalse(active.showNewButton)
        assertFalse(HomeVideoPolicy.actions(null,"",false,null,false).primaryEnabled)
    }
    @Test fun storedShortLinkAliasDoesNotOfferADuplicateDownload() {
        val existing=video("https://www.tiktok.com/@person/video/123456789","https://vm.tiktok.com/ZShort123/")
        assertFalse(HomeVideoPolicy.actions(existing,"https://vt.tiktok.com/ZShort123/?share=changed",false,null,false).showNewButton)
        assertTrue(HomeVideoPolicy.actions(existing,"https://www.tiktok.com/@person/video/987654321",false,null,false).showNewButton)
    }
    @Test fun localSavedVideoAndUnicodeShortNamesRemainUsable() {
        assertTrue(HomeVideoPolicy.actions(video(null),"https://youtu.be/jNQXAC9IVRw",false,null,false).showNewButton)
        assertEquals("My clip",HomeVideoPolicy.shortName("My   clip.mp4"))
        val shortened=HomeVideoPolicy.shortName("😀".repeat(40))
        assertTrue(shortened.endsWith("…"));assertEquals(28,shortened.codePointCount(0,shortened.length))
    }
    private fun video(source:String?,requested:String?=null)=ImportedVideo("a".repeat(24),File("unused.mp4"),"A saved video",20000,1,source,requested)
}
