package studio.roast.app

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Audio completion changes prepared-media facts only, never a newer edit snapshot. */
internal fun mergePreparedAudio(current:ReactionDraft,prepared:ReactionDraft):ReactionDraft {
    require(current.id==prepared.id&&current.directory.absoluteFile.normalize()==prepared.directory.absoluteFile.normalize())
    return current.copy(sourceAvailable=prepared.sourceAvailable,microphoneRms=prepared.microphoneRms,
        sourceRms=prepared.sourceRms,preparationError=prepared.preparationError)
}

private object DraftProjectLocks {
    private val locks=Array(32){Any()}
    fun forDirectory(directory:File)=locks[(directory.absoluteFile.normalize().path.hashCode() and Int.MAX_VALUE)%locks.size]
}

/** Context-free durable project commits, shared by edits and asynchronous audio preparation. */
internal class DraftProjectFiles(private val directory:File) {
    fun load(id:String):ReactionDraft?=runCatching {
        require(id.matches(Regex("[a-zA-Z0-9-]+")))
        val root=File(directory,id);val json=JSONObject(File(root,"project.json").readText())
        val edit=json.getJSONObject("edits")
        ReactionDraft(id,json.getString("title"),json.getLong("durationMs"),root,
            DraftEdits(storedMixGains(edit),
                edit.optLong("trimStartMs",0),edit.optLong("trimEndMs",json.getLong("durationMs")),
                edit.optJSONArray("cuts").draftObjects().map{EditRange(it.getLong("startMs"),it.getLong("endMs"))},
                edit.optString("musicName").takeIf{it.isNotBlank()&&it!="null"},edit.optBoolean("loopMusic",false),
                edit.optJSONArray("captions").draftObjects().map{CaptionCue(it.getLong("startMs"),it.getLong("endMs"),it.getString("text"))},edit.optBoolean("showCaptions",true),
                edit.optBoolean("voiceCleanupEnabled",false)),
            json.optLong("revision",0),json.optBoolean("sourceAvailable",false),json.optDouble("microphoneRms",0.0),json.optDouble("sourceRms",0.0),
            json.optString("preparationError").takeIf{it.isNotBlank()&&it!="null"})
    }.getOrNull()
    fun save(draft:ReactionDraft)=synchronized(DraftProjectLocks.forDirectory(draft.directory)){write(draft)}

    fun saveEdits(draft:ReactionDraft):ReactionDraft=synchronized(DraftProjectLocks.forDirectory(draft.directory)) {
        val latest=load(draft.id)?:throw IllegalStateException("This draft is no longer available.")
        val merged=mergePreparedAudio(draft,latest)
        write(merged);merged
    }

    fun completeAudio(prepared:ReactionDraft):ReactionDraft?=synchronized(DraftProjectLocks.forDirectory(prepared.directory)) {
        val latest=load(prepared.id)?:return@synchronized null
        val merged=mergePreparedAudio(latest,prepared)
        write(merged);merged
    }

    private fun write(draft:ReactionDraft) {
        require(draft.directory.absoluteFile.normalize()==File(directory,draft.id).absoluteFile.normalize())
        check(draft.directory.isDirectory){"This draft is no longer available."}

        val e=draft.edits
        val edits=JSONObject().put("sourceGain",e.gains.source).put("microphoneGain",e.gains.microphone).put("musicGain",e.gains.music)
            .put("trimStartMs",e.trimStartMs).put("trimEndMs",e.trimEndMs).put("cuts",JSONArray(e.cuts.map{JSONObject().put("startMs",it.startMs).put("endMs",it.endMs)}))
            .put("musicName",e.musicName).put("loopMusic",e.loopMusic).put("showCaptions",e.showCaptions)
            .put("voiceCleanupEnabled",e.voiceCleanupEnabled)
            .put("captions",JSONArray(e.captions.map{JSONObject().put("startMs",it.startMs).put("endMs",it.endMs).put("text",it.text)}))
        val json=JSONObject().put("version",1).put("id",draft.id).put("title",draft.title).put("durationMs",draft.durationMs)
            .put("revision",draft.revision).put("sourceAvailable",draft.sourceAvailable).put("microphoneRms",draft.microphoneRms)
            .put("sourceRms",draft.sourceRms).put("preparationError",draft.preparationError).put("edits",edits)
        val temporary=File(draft.directory,"project.json.tmp")
        temporary.writeText(json.toString(2))
        check(temporary.renameTo(File(draft.directory,"project.json"))){"Your edit could not be saved. The original recording is safe."}
    }
}
private fun JSONArray?.draftObjects():List<JSONObject> = if(this==null)emptyList()else (0 until length()).map{getJSONObject(it)}
