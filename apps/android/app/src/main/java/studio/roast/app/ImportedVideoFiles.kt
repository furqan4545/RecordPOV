package studio.roast.app

import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID
import java.nio.file.Files
import java.nio.file.StandardCopyOption

internal data class ImportedVideo(val id:String,val file:File,val title:String,val durationMs:Long,val createdAt:Long,val sourceUrl:String?,val requestedUrl:String?=null,val qualityVersion:Int=0)
/** Durable per-import manifests. Deleting an import can never address a draft or external document. */
internal class ImportedVideoFiles(private val root:File) {
    init {check(root.mkdirs()||root.isDirectory)}
    fun list():List<ImportedVideo> = root.listFiles().orEmpty().filter{it.isDirectory&&it.name.matches(Regex("[a-f0-9]{24}"))}
        .mapNotNull{read(it)}.sortedByDescending{it.createdAt}
    fun get(id:String):ImportedVideo?=if(id.matches(Regex("[a-f0-9]{24}")))read(File(root,id))else null
    fun find(url:String,minimumQualityVersion:Int=0)=list().firstOrNull {video ->
        video.qualityVersion>=minimumQualityVersion&&(LinkIdentity.same(video.sourceUrl,url)||LinkIdentity.same(video.requestedUrl,url))
    }
    fun homeVideo():ImportedVideo? {
        val id=runCatching{val marker=File(root,"last-opened.json");require(marker.length() in 1..256);JSONObject(marker.readText()).getString("id")}.getOrNull()
        return id?.let(::get)?:list().firstOrNull()
    }
    @Synchronized fun markOpened(id:String) {
        require(get(id)!=null){"This imported video is no longer available."}
        val temporary=File(root,"last-opened.pending")
        try {
            temporary.outputStream().use{it.write(JSONObject().put("version",1).put("id",id).toString().toByteArray());it.fd.sync()}
            Files.move(temporary.toPath(),File(root,"last-opened.json").toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)
        }finally{temporary.delete()}
    }
    @Synchronized fun store(input:InputStream,title:String,durationMs:Long,sourceUrl:String?,requestedUrl:String?,maxBytes:Long=DirectImportPolicy.MAX_FILE_BYTES,qualityVersion:Int=0,checkActive:()->Unit={}):ImportedVideo {
        require(qualityVersion>=0)
        val temporary=File(root,".pending-${UUID.randomUUID()}").apply{check(mkdir())}
        try {
            val file=File(temporary,"video.mp4");val digest=MessageDigest.getInstance("SHA-256");var count=0L
            input.use{source->file.outputStream().use{out->
                val bytes=ByteArray(65536)
                while(true){checkActive();val size=source.read(bytes);if(size<0)break;count+=size;check(count<=maxBytes){"This video is too large."};digest.update(bytes,0,size);out.write(bytes,0,size)}
                out.fd.sync()
            }}
            checkActive();check(count>0){"The video file is empty."}
            val hash=digest.digest().joinToString(""){"%02x".format(it)}
            // New-quality URL imports coexist with old offline clips; never replace a file
            // that may already be referenced by a draft or selected from Recent.
            val identity=sourceUrl?.let{if(qualityVersion>0)"link:q$qualityVersion:$it"else"link:$it"}?:"local:$hash"
            val id=MessageDigest.getInstance("SHA-256").digest(identity.toByteArray()).joinToString(""){"%02x".format(it)}.take(24)
            get(id)?.let{return it}
            val created=System.currentTimeMillis()
            val json=JSONObject().put("version",1).put("id",id).put("title",title.take(512)).put("durationMs",durationMs)
                .put("createdAt",created).put("sourceUrl",sourceUrl).put("requestedUrl",requestedUrl).put("bytes",count).put("qualityVersion",qualityVersion)
            File(temporary,"manifest.json").outputStream().use{it.write(json.toString().toByteArray());it.fd.sync()}
            checkActive()
            val destination=File(root,id)
            if(destination.exists())check(destination.deleteRecursively())
            check(temporary.renameTo(destination)){"The imported video could not be saved."}
            return checkNotNull(get(id))
        }finally{temporary.deleteRecursively()}
    }
    @Synchronized fun delete(id:String) {
        require(id.matches(Regex("[a-f0-9]{24}")))
        val directory=File(root,id).canonicalFile
        require(directory.parentFile==root.canonicalFile)
        check(!directory.exists()||directory.deleteRecursively()){ "This import could not be deleted." }
    }
    fun cleanPending(){root.listFiles().orEmpty().filter{it.isDirectory&&it.name.startsWith(".pending-")}.forEach{it.deleteRecursively()}}
    private fun read(directory:File):ImportedVideo?=runCatching {
        val json=JSONObject(File(directory,"manifest.json").readText());val id=json.getString("id")
        require(id==directory.name&&json.getInt("version")==1)
        val file=File(directory,"video.mp4");require(file.isFile&&file.length()==json.getLong("bytes")&&file.length()>0)
        ImportedVideo(id,file,json.getString("title"),json.getLong("durationMs"),json.getLong("createdAt"),json.optString("sourceUrl").takeIf{it.isNotBlank()&&it!="null"},
            json.optString("requestedUrl").takeIf{it.isNotBlank()&&it!="null"},json.optInt("qualityVersion",0).coerceAtLeast(0))
    }.getOrNull()
}
