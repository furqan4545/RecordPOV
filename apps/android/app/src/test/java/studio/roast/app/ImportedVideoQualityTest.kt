package studio.roast.app

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class ImportedVideoQualityTest {
    @Test fun legacyRecordWithoutQualityMarkerRemainsOfflineButCannotSatisfyNewImport()=temporary {root->
        val store=ImportedVideoFiles(root);val url="https://www.youtube.com/watch?v=jNQXAC9IVRw"
        val old=store.store(byteArrayOf(1,2,3).inputStream(),"Old video",1000,url,null)
        val manifest=File(old.file.parentFile,"manifest.json")
        manifest.writeText(JSONObject(manifest.readText()).apply{remove("qualityVersion")}.toString())
        val restored=ImportedVideoFiles(root)
        assertEquals(0,restored.get(old.id)?.qualityVersion)
        assertEquals(old.id,restored.list().single().id)
        assertNull(restored.find("https://youtu.be/jNQXAC9IVRw?si=tracking",minimumQualityVersion=2))
        assertArrayEquals(byteArrayOf(1,2,3),restored.get(old.id)!!.file.readBytes())
    }
    @Test fun upgradedSourceCoexistsWithOldSourceAndOnlyNewQualityIsReusedAcrossUrlAliases()=temporary {root->
        val store=ImportedVideoFiles(root);val url="https://www.youtube.com/watch?v=jNQXAC9IVRw"
        val old=store.store(byteArrayOf(1,2,3).inputStream(),"Old",1000,url,null)
        val fresh=store.store(byteArrayOf(9,8,7,6).inputStream(),"Original quality",1000,url,"https://youtu.be/jNQXAC9IVRw",qualityVersion=2)
        assertNotEquals(old.id,fresh.id);assertEquals(2,store.list().size)
        assertArrayEquals(byteArrayOf(1,2,3),store.get(old.id)!!.file.readBytes())
        assertArrayEquals(byteArrayOf(9,8,7,6),store.get(fresh.id)!!.file.readBytes())
        val restored=ImportedVideoFiles(root)
        assertEquals(fresh.id,restored.find("https://m.youtube.com/shorts/jNQXAC9IVRw",minimumQualityVersion=2)?.id)
        val again=restored.store(byteArrayOf(4,4).inputStream(),"Duplicate",1000,url,null,qualityVersion=2)
        assertEquals(fresh.id,again.id);assertEquals(2,restored.list().size)
    }
    private fun temporary(block:(File)->Unit){val root=Files.createTempDirectory("recordpov-quality").toFile();try{block(root)}finally{root.deleteRecursively()}}
}
