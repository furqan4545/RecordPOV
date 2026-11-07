package studio.roast.app

import kotlinx.coroutines.CancellationException
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class ImportedVideoPersistenceTest {
    @Test fun completedImportSurvivesStoreRecreationWithExactVideoBytes()=temporary {root->
        val bytes=ByteArray(100000){(it%251).toByte()};val files=ImportedVideoFiles(File(root,"imports"))
        val video=files.store(bytes.inputStream(),"My source",20000,"https://x.com/name/status/12345","shared-link")
        val reopened=ImportedVideoFiles(File(root,"imports")).list().single()
        assertEquals(video.id,reopened.id);assertEquals("My source",reopened.title);assertEquals(20000L,reopened.durationMs)
        assertArrayEquals(bytes,reopened.file.readBytes());assertEquals(video.id,files.find("shared-link")?.id)
    }
    @Test fun repeatedLinkAndLocalContentImportsAreIdempotent()=temporary {root->
        val files=ImportedVideoFiles(root);val bytes=byteArrayOf(1,2,3)
        val linked=files.store(bytes.inputStream(),"First",1000,"https://source.test/video",null)
        val again=files.store(bytes.inputStream(),"Again",1000,"https://source.test/video",null)
        assertEquals(linked.id,again.id)
        val local=files.store(bytes.inputStream(),"Local",1000,null,null)
        assertEquals(local.id,files.store(bytes.inputStream(),"Renamed",1000,null,null).id)
        assertEquals(2,files.list().size)
    }
    @Test fun cancelledCopyNeverPublishesAPartialImport()=temporary {root->
        val files=ImportedVideoFiles(root);var checks=0
        assertThrows(CancellationException::class.java){files.store(ByteArray(200000).inputStream(),"Partial",1000,null,null,
            checkActive={if(++checks>=2)throw CancellationException()})}
        assertTrue(files.list().isEmpty());assertTrue(root.listFiles().orEmpty().isEmpty())
    }
    @Test fun oversizedOrEmptyCopyCannotEnterTheIndex()=temporary {root->
        val files=ImportedVideoFiles(root)
        assertThrows(IllegalStateException::class.java){files.store(ByteArray(20).inputStream(),"Big",1000,null,null,maxBytes=10)}
        assertThrows(IllegalStateException::class.java){files.store(ByteArray(0).inputStream(),"Empty",1000,null,null)}
        assertTrue(files.list().isEmpty())
    }
    @Test fun deletingAnImportNeverDeletesPinnedDraftOrExternalOriginal()=temporary {root->
        val files=ImportedVideoFiles(File(root,"imports"));val bytes=byteArrayOf(4,5,6)
        val source=File(root,"external.mp4").apply{writeBytes(bytes)}
        val video=files.store(source.inputStream(),"Source",1000,null,null)
        val pinned=File(root,"draft/original.mp4").apply{parentFile.mkdirs();writeBytes(video.file.readBytes())}
        files.delete(video.id)
        assertArrayEquals(bytes,source.readBytes());assertArrayEquals(bytes,pinned.readBytes());assertTrue(files.list().isEmpty())
        assertThrows(IllegalArgumentException::class.java){files.delete("../draft")}
    }
    @Test fun corruptOrMissingFilesAreNotReturnedAsPlayableImports()=temporary {root->
        val files=ImportedVideoFiles(root);val video=files.store(byteArrayOf(1,2).inputStream(),"Good",1000,null,null)
        video.file.writeBytes(byteArrayOf(1));assertNull(files.get(video.id));assertTrue(files.list().isEmpty())
    }
    @Test fun interruptedPrivateStagesCanBeRemovedWithoutTouchingCompletedVideos()=temporary {root->
        val files=ImportedVideoFiles(root);val complete=files.store(byteArrayOf(1,2).inputStream(),"Done",1000,null,null)
        File(root,".pending-crashed/video.mp4").apply{parentFile.mkdirs();writeBytes(ByteArray(50))}
        files.cleanPending();assertNotNull(files.get(complete.id));assertFalse(File(root,".pending-crashed").exists())
    }
    @Test fun backgroundDescriptorRetainsRequestFallbackAndBoundedRestartState()=temporary {root->
        val files=ImportJobFiles(root)
        val job=ImportJobRecord.create("https://x.com/person/status/12345",false,"https://api.recordpov.app","Video")
            .copy(attempts=1,fallbackUsed=true,status=ImportStatus.Loading)
        files.save(job)
        assertEquals(job,ImportJobFiles(root).read())
        assertFalse(File(root,"job.json").readText().contains("googlevideo.com"))
        assertThrows(IllegalArgumentException::class.java){ImportJobRecord.parse(job.copy(attempts=3).json())}
    }
    @Test fun expiredDescriptorsAndStaleClearCannotEraseANewerJob()=temporary {root->
        val files=ImportJobFiles(root);val first=ImportJobRecord.create("one",false,"https://api.recordpov.app","One")
        val second=ImportJobRecord.create("two",false,"https://api.recordpov.app","Two")
        files.save(first);files.save(second);files.clear(first.id);assertEquals(second.id,files.read()?.id)
        assertEquals(second.id,files.read(second.created+3*60*60*1000L)?.id) // a long import still running is kept
        assertNull(files.read(second.created+IMPORT_JOB_MAX_AGE_MS+1));assertFalse(File(root,"job.json").exists())
    }
    @Test fun readyDescriptorPreservesDurableImportIdentityAcrossRestart()=temporary {root->
        val files=ImportJobFiles(root);val ready=ImportJobRecord.create("link",false,"https://api.recordpov.app","Source")
            .copy(status=ImportStatus.Ready,importedId="a".repeat(24))
        files.save(ready);assertEquals(ready,ImportJobFiles(root).read());assertFalse(ready.active)
        files.clear(ready.id);assertNull(files.read())
    }
    @Test fun failureMessagesDoNotExposeSignedUrlsOrPrivatePaths() {
        assertFalse(importFailureMessage(Exception("Failed https://video.twimg.com/x?signature=secret")).contains("secret"))
        assertFalse(importFailureMessage(Exception("/data/user/0/studio.roast.app/cache/video.mp4: failed")).contains("/data/"))
        assertEquals("This video is private.",importFailureMessage(Exception("This video is private.")))
    }
    @Test fun homeReopensTheLastChosenImportAcrossRestartAndNewDownloads()=temporary {root->
        val files=ImportedVideoFiles(root)
        val first=files.store(byteArrayOf(1,2,3).inputStream(),"First",1000,"https://www.youtube.com/watch?v=jNQXAC9IVRw",null)
        files.markOpened(first.id)
        val second=files.store(byteArrayOf(4,5,6).inputStream(),"Second",1000,"https://www.youtube.com/watch?v=bkPwFqa89gE",null)
        assertEquals(first.id,ImportedVideoFiles(root).homeVideo()?.id)
        files.markOpened(second.id)
        assertEquals(second.id,ImportedVideoFiles(root).homeVideo()?.id)
        assertEquals(first.id,files.find("https://youtu.be/jNQXAC9IVRw?si=tracking")?.id)
    }
    @Test fun deletedLastOpenedImportFallsBackToAnotherValidVideo()=temporary {root->
        val files=ImportedVideoFiles(root)
        val kept=files.store(byteArrayOf(1,2).inputStream(),"Kept",1000,null,null)
        val removed=files.store(byteArrayOf(3,4).inputStream(),"Removed",1000,null,null)
        files.markOpened(removed.id);files.delete(removed.id)
        assertEquals(kept.id,ImportedVideoFiles(root).homeVideo()?.id)
        assertThrows(IllegalArgumentException::class.java){files.markOpened(removed.id)}
    }
    private fun temporary(block:(File)->Unit){val directory=Files.createTempDirectory("recordpov-import-test").toFile();try{block(directory)}finally{directory.deleteRecursively()}}
}
