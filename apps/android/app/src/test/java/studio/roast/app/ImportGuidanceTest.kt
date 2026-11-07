package studio.roast.app

import org.junit.Assert.*
import org.junit.Test

class ImportGuidanceTest {
    @Test fun everyActiveStatusSaysLeavingIsSafe() {
        val expected=ImportGuidance(ImportGuidanceTone.Go,"You can leave RecordPOV. It keeps going in the background.")
        assertEquals(expected,ImportGuidanceCopy.guidance(ImportStatus.Downloading))
        assertEquals(expected,ImportGuidanceCopy.guidance(ImportStatus.Loading))
    }
    @Test fun finishedAndIdleStatusesShowNoGuidance() {
        listOf(ImportStatus.Ready,ImportStatus.Failed,ImportStatus.Cancelled,ImportStatus.Interrupted)
            .forEach{assertNull(it.name,ImportGuidanceCopy.guidance(it))}
        assertNull(ImportGuidanceCopy.guidance(null))
    }
    @Test fun guidanceExistsExactlyForActiveStatuses() {
        ImportStatus.entries.forEach{status->
            val active=status==ImportStatus.Downloading||status==ImportStatus.Loading
            assertEquals(status.name,active,ImportGuidanceCopy.guidance(status)!=null)
        }
    }
    @Test fun interruptedCopyMatchesTheButton() {
        assertEquals("Your import was interrupted. Tap Download & open video to try again.",ImportGuidanceCopy.INTERRUPTED)
        assertTrue(ImportGuidanceCopy.INTERRUPTED.contains("Download & open video"))
    }
    @Test fun interruptedUploadCopyMatchesTheUploadButton() {
        assertEquals("Your upload was interrupted. Tap Upload video or photo to try again.",ImportGuidanceCopy.INTERRUPTED_UPLOAD)
        assertTrue(ImportGuidanceCopy.INTERRUPTED_UPLOAD.contains("Upload video or photo"))
        assertNotEquals(ImportGuidanceCopy.INTERRUPTED,ImportGuidanceCopy.INTERRUPTED_UPLOAD)
    }
    @Test fun missingFileAdviceMatchesHowTheVideoWasAdded() {
        assertEquals("This video is no longer on this phone. Paste its link to download it again.",ImportGuidanceCopy.missingFile(upload=false))
        assertEquals("This video is no longer on this phone. Add it again with Upload video or photo.",ImportGuidanceCopy.missingFile(upload=true))
    }
}
