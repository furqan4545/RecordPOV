package studio.roast.app

import java.io.File

internal object OwnedMediaDeletion {
    fun draft(root:File,id:String) {
        require(id.matches(Regex("[a-zA-Z0-9-]+")))
        val expected=File(root.canonicalFile,id)
        require(expected.canonicalFile==expected){"This draft cannot be deleted safely."}
        check(!expected.exists()||expected.isDirectory&&expected.deleteRecursively()) {"The draft could not be deleted."}
    }
    fun saved(root:File,file:File) {
        val owner=root.canonicalFile;val expected=File(owner,file.name)
        require(file.parentFile?.canonicalFile==owner&&file.canonicalFile==expected&&expected.canonicalFile==expected&&file.extension=="mp4") {"This video cannot be deleted safely."}
        check(!expected.exists()||expected.isFile&&expected.delete()) {"The video could not be deleted."}
    }
}
