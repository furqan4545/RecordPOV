package studio.roast.app

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordingFlowTest {
    @Test fun defaultAndPersistedTimerChoicesAreStable() {
        assertEquals(RecordingDelay.Three,RecordingDelay.fromStoredSeconds(-1))
        assertEquals(RecordingDelay.Three,RecordingDelay.fromStoredSeconds(3))
        assertEquals(RecordingDelay.Off,RecordingDelay.fromStoredSeconds(0))
        assertEquals(RecordingDelay.Five,RecordingDelay.fromStoredSeconds(5))
        assertEquals(RecordingDelay.Ten,RecordingDelay.fromStoredSeconds(10))
    }

    @Test fun countdownShowsEverySecondBeforeAllowingRecording()=runBlocking {
        val ticks=mutableListOf<Int?>()
        var secondsWaited=0
        awaitRecordingCountdown(RecordingDelay.Three,{ticks+=it}){secondsWaited++}
        assertEquals(listOf(3,2,1,null),ticks)
        assertEquals(3,secondsWaited)
    }

    @Test fun timerOffStartsWithoutWaiting()=runBlocking {
        val ticks=mutableListOf<Int?>()
        awaitRecordingCountdown(RecordingDelay.Off,{ticks+=it}){error("Off must not wait")}
        assertEquals(listOf<Int?>(null),ticks)
    }

    @Test fun cancellingCountdownClearsItAndNeverStartsTheRecorder()=runBlocking {
        val firstTick=CompletableDeferred<Unit>()
        val wait=CompletableDeferred<Unit>()
        var tick:Int?=null
        var recorderStarted=false
        val job=launch {
            awaitRecordingCountdown(RecordingDelay.Ten,{tick=it;firstTick.complete(Unit)}){wait.await()}
            recorderStarted=true
        }
        firstTick.await()
        assertEquals(10,tick)
        job.cancelAndJoin()
        assertEquals(null,tick)
        assertFalse(recorderStarted)
    }

    @Test fun recordingRetainsTheChosenPositionAndRewindsOnlyAtTheEnd() {
        assertEquals(12_345L,recordingSourcePosition(12_345,60_000,false))
        assertEquals(0L,recordingSourcePosition(60_000,60_000,false))
        assertEquals(0L,recordingSourcePosition(59_999,60_000,true))
        assertEquals(3_000L,recordingSourcePosition(3_000,0,false))
    }

    @Test fun simultaneousAutomaticAndManualSavePublishOneCopy()=runBlocking {
        val copies=mutableMapOf<String,String>()
        var published=0
        val ledger=GalleryExportLedger(copies::get,remember={key,uri->copies[key]=uri})
        val results=(1..20).map{async {
            ledger.save("take.mp4",{true},{null}){yield();published++;"gallery://one"}
        }}.awaitAll()
        assertEquals(1,published)
        assertTrue(results.all{it=="gallery://one"})
        assertEquals("gallery://one",copies["take.mp4"])
    }

    @Test fun failedGallerySaveCanRetryWithoutMarkingTheAppCopyAsExported()=runBlocking {
        val copies=mutableMapOf<String,String>()
        val ledger=GalleryExportLedger(copies::get,remember={key,uri->copies[key]=uri})
        val failure=runCatching{ledger.save("take.mp4",{false},{null}){error("Storage full")}}
        assertTrue(failure.isFailure)
        assertFalse(copies.containsKey("take.mp4"))
        assertEquals("gallery://retry",ledger.save("take.mp4",{false},{null}){"gallery://retry"})
    }

    @Test fun previouslyPublishedCopyIsRecoveredWithoutDuplicatingAfterRestart()=runBlocking {
        val copies=mutableMapOf<String,String>()
        val ledger=GalleryExportLedger(copies::get,remember={key,uri->copies[key]=uri})
        val result=ledger.save("take.mp4",{false},{"gallery://existing"}){error("Must not duplicate")}
        assertEquals("gallery://existing",result)
        assertEquals(result,copies["take.mp4"])
        val restarted=GalleryExportLedger(copies::get,remember={key,uri->copies[key]=uri})
        assertEquals(result,restarted.save("take.mp4",{it==result},{null}){error("Must not duplicate")})
    }

    @Test fun explicitlyRetryingADeletedGalleryCopyCanPublishAgain()=runBlocking {
        val copies=mutableMapOf("take.mp4" to "gallery://deleted")
        val ledger=GalleryExportLedger(copies::get,remember={key,uri->copies[key]=uri})
        assertEquals("gallery://new",ledger.save("take.mp4",{false},{null}){"gallery://new"})
        assertEquals("gallery://new",copies["take.mp4"])
    }
}
