package studio.roast.app

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class OwnedMediaDeletionTest {
    @Test fun deletingOneLocalVideoOrDraftKeepsOtherProjectsAndPhotosCopy()=temporary{root->
        val takes=File(root,"takes").apply{mkdir()};val drafts=File(root,"drafts").apply{mkdir()}
        val clip=File(takes,"Video.mp4").apply{writeText("app copy")}
        val other=File(takes,"Other.mp4").apply{writeText("other")}
        val gallery=File(root,"Gallery.mp4").apply{writeText("gallery copy")}
        val draft=File(drafts,"draft-one").apply{mkdir()};File(draft,"capture.mp4").writeText("owned capture")
        val otherDraft=File(drafts,"draft-two").apply{mkdir()};File(otherDraft,"capture.mp4").writeText("other capture")
        OwnedMediaDeletion.saved(takes,clip);OwnedMediaDeletion.draft(drafts,"draft-one")
        assertFalse(clip.exists());assertFalse(draft.exists());assertTrue(other.exists());assertTrue(gallery.exists());assertTrue(otherDraft.exists())
    }
    @Test fun externalPathsTraversalAndSymlinkAliasesCannotDeleteAnotherRecord()=temporary{root->
        val takes=File(root,"takes").apply{mkdir()};val drafts=File(root,"drafts").apply{mkdir()}
        val external=File(root,"source.mp4").apply{writeText("source")}
        assertThrows(IllegalArgumentException::class.java){OwnedMediaDeletion.saved(takes,external)}
        assertThrows(IllegalArgumentException::class.java){OwnedMediaDeletion.draft(drafts,"../takes")}
        val alias=File(takes,"alias.mp4");Files.createSymbolicLink(alias.toPath(),external.toPath())
        assertThrows(IllegalArgumentException::class.java){OwnedMediaDeletion.saved(takes,alias)}
        assertTrue(external.exists())
    }
    private fun temporary(block:(File)->Unit){val root=Files.createTempDirectory("recordpov-deletion").toFile();try{block(root)}finally{root.deleteRecursively()}}
}
