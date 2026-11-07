package studio.roast.app

import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/** Two attempts of up to three hours each, plus margin; an in-progress long import must not be expired. */
internal const val IMPORT_JOB_MAX_AGE_MS=25_200_000L
internal enum class ImportStatus { Downloading,Loading,Ready,Failed,Cancelled,Interrupted }
internal data class ImportJobRecord(val id:String,val input:String,val local:Boolean,val server:String,val title:String,
    val created:Long,val status:ImportStatus=ImportStatus.Downloading,val importedId:String?=null,val message:String?=null,
    val attempts:Int=0,val fallbackUsed:Boolean=false) {
    val active get()=status==ImportStatus.Downloading||status==ImportStatus.Loading
    fun json()=JSONObject().put("version",1).put("id",id).put("input",input).put("local",local).put("server",server)
        .put("title",title).put("created",created).put("status",status.name).put("importedId",importedId).put("message",message)
        .put("attempts",attempts).put("fallbackUsed",fallbackUsed)
    override fun toString()="ImportJobRecord(id=$id, status=$status, input=[redacted])"
    companion object {
        fun create(input:String,local:Boolean,server:String,title:String)=ImportJobRecord(UUID.randomUUID().toString(),input,local,server,title,System.currentTimeMillis())
        fun parse(json:JSONObject):ImportJobRecord {
            require(json.getInt("version")==1)
            val id=json.getString("id");require(runCatching{UUID.fromString(id)}.isSuccess)
            val input=json.getString("input");require(input.length in 1..4096)
            val record=ImportJobRecord(id,input,json.getBoolean("local"),json.getString("server"),json.getString("title").take(512),json.getLong("created"),
                ImportStatus.valueOf(json.getString("status")),json.optString("importedId").takeIf{it.matches(Regex("[a-f0-9]{24}"))},
                json.optString("message").takeIf{it.isNotBlank()&&it!="null"}?.take(512),json.optInt("attempts"),json.optBoolean("fallbackUsed"))
            require(record.attempts in 0..2)
            return record
        }
    }
}
internal class ImportJobFiles(private val directory:File) {
    private val file=File(directory,"job.json")
    @Synchronized fun read(now:Long=System.currentTimeMillis()):ImportJobRecord?=runCatching {
        if(!file.exists())return null
        require(file.length()<=16384)
        ImportJobRecord.parse(JSONObject(file.readText())).also{require(now-it.created in 0..IMPORT_JOB_MAX_AGE_MS)}
    }.getOrElse{file.delete();null}
    @Synchronized fun save(record:ImportJobRecord) {
        check(directory.mkdirs()||directory.isDirectory)
        val temporary=File(directory,"job.pending")
        try {
            temporary.outputStream().use{it.write(record.json().toString().toByteArray());it.fd.sync()}
            Files.move(temporary.toPath(),file.toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)
        }finally{temporary.delete()}
    }
    @Synchronized fun clear(id:String){if(read()?.id==id)file.delete()}
}

internal fun importFailureMessage(error:Exception):String {
    val message=error.localizedMessage.orEmpty()
    return if(message.isBlank()||message.contains(Regex("https?://|/(?:data|storage|sdcard|Users|private)/",RegexOption.IGNORE_CASE)))
        "The video could not be imported. Check your connection and available storage, then try again."
    else message.take(300)
}
