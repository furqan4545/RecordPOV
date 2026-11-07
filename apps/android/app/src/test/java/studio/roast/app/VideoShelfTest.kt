package studio.roast.app

import org.junit.Assert.*
import org.junit.Test
import java.io.File

class VideoShelfTest {
    @Test fun importedShelfShowsOnlyImportedSourceVideos() {
        assertTrue(VideoShelf.Imported.accepts(imported()))
        assertFalse(VideoShelf.Imported.accepts(saved()))
        assertFalse(VideoShelf.Imported.accepts(unfinished()))
    }
    @Test fun savedShelfShowsSavedVideosAndUnfinishedEditsButNoImports() {
        assertTrue(VideoShelf.Saved.accepts(saved()))
        assertTrue(VideoShelf.Saved.accepts(unfinished()))
        assertFalse(VideoShelf.Saved.accepts(imported()))
    }
    @Test fun everyVideoBelongsToExactlyOneShelf() {
        listOf(imported(),saved(),unfinished()).forEach{video->
            assertEquals(video.key,1,VideoShelf.entries.count{it.accepts(video)})
        }
    }
    private fun imported()=HomeRecentVideo("import:${"a".repeat(24)}",File("video.mp4"),"An imported video","Imported · 0:20",2,
        imported=ImportedVideo("a".repeat(24),File("video.mp4"),"An imported video",20000,2,"https://youtu.be/jNQXAC9IVRw"))
    private fun saved()=HomeRecentVideo("saved:Video.mp4",File("Video.mp4"),"A saved video","Saved video",3,saved=SavedTake(File("Video.mp4"),"A saved video",3))
    // A draft has no imported video; the shelf decides on that alone, so no ReactionDraft is needed here.
    private fun unfinished()=HomeRecentVideo("draft:one",File("capture.mp4"),"An unfinished edit","Draft · 0:10",1)
}
