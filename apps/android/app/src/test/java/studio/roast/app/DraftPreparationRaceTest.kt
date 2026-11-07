package studio.roast.app

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.*
import org.junit.Test

class DraftPreparationRaceTest {
    private suspend fun fixture(block:suspend(File,ReactionDraft,DraftProjectFiles)->Unit) {
        val root=Files.createTempDirectory("recordpov-preparation-race-").toFile()
        try {
            val directory=File(root,"test-draft").apply{mkdirs()}
            val draft=ReactionDraft("test-draft","Synthetic",3_000,directory,DraftEdits(trimEndMs=3_000),preparationError="Audio is being prepared.")
            draft.microphone.writeBytes(byteArrayOf(1));draft.source.writeBytes(byteArrayOf(1))
            val projects=DraftProjectFiles(root);projects.save(draft)
            block(root,draft,projects)
        }finally{root.deleteRecursively()}
    }
    private fun edited(draft:ReactionDraft)=draft.copy(revision=4,edits=draft.edits.copy(gains=MixGains(.4f,.25f,.1f),
        trimStartMs=500,trimEndMs=2_500,captions=listOf(CaptionCue(600,1_200,"New words")),voiceCleanupEnabled=false))
    private fun ready(draft:ReactionDraft)=draft.copy(sourceAvailable=true,microphoneRms=.05,sourceRms=.1,preparationError=null)

    @Test fun userEditsPersistWhilePendingAudioCompletesFromAnOlderSnapshot()=runBlocking {
        fixture {root,snapshot,projects ->
            val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
            val worker=async {
                DraftAudioPreparationGate.run(snapshot.directory) {
                    entered.complete(Unit);release.await()
                    projects.completeAudio(ready(snapshot))
                }
            }
            entered.await()
            val userChoice=edited(snapshot)
            // A second store instance represents an independent UI persistence path.
            DraftProjectFiles(root).saveEdits(userChoice)
            release.complete(Unit)
            val completed=worker.await()!!
            val stored=projects.load(snapshot.id)!!
            assertEquals(userChoice.edits,completed.edits);assertEquals(userChoice.edits,stored.edits)
            assertEquals(4L,stored.revision);assertTrue(stored.audioReady)
            assertEquals(.05,stored.microphoneRms,0.0);assertEquals(.1,stored.sourceRms,0.0)
        }
    }

    @Test fun anEditSavedAfterAudioCommitKeepsTheNewPreparedMetadata()=runBlocking {
        fixture {_,snapshot,projects ->
            projects.completeAudio(ready(snapshot))
            val latest=projects.saveEdits(edited(snapshot))
            assertTrue(latest.audioReady);assertNull(latest.preparationError)
            assertEquals(edited(snapshot).edits,projects.load(snapshot.id)!!.edits)
            assertTrue(projects.load(snapshot.id)!!.sourceAvailable)
        }
    }

    @Test fun closeAndReopenSerializeStemWritersAndKeepTheLatestChoices()=runBlocking {
        fixture {_,snapshot,projects ->
            val entered=CompletableDeferred<Unit>();val events=mutableListOf<String>()
            val old=launch {
                DraftAudioPreparationGate.run(snapshot.directory) {
                    events+="old-start";entered.complete(Unit)
                    try{awaitCancellation()}
                    catch(error:CancellationException){
                        events+="old-cancel"
                        projects.completeAudio(snapshot.copy(preparationError="Audio preparation was cancelled."))
                        throw error
                    }
                }
            }
            entered.await();projects.saveEdits(edited(snapshot))
            val reopened=async {
                DraftAudioPreparationGate.run(snapshot.directory) {
                    events+="new-start"
                    projects.completeAudio(ready(snapshot)).also{events+="new-ready"}
                }
            }
            yield();assertEquals(listOf("old-start"),events)
            old.cancelAndJoin();reopened.await()
            assertEquals(listOf("old-start","old-cancel","new-start","new-ready"),events)
            val latest=projects.load(snapshot.id)!!
            assertEquals(edited(snapshot).edits,latest.edits);assertTrue(latest.audioReady)
        }
    }

    @Test fun completionCannotRecreateAnExplicitlyRemovedDraft()=runBlocking {
        fixture {_,snapshot,projects ->
            snapshot.directory.deleteRecursively()
            assertNull(projects.completeAudio(ready(snapshot)))
            assertFalse(snapshot.directory.exists())
        }
    }
}
