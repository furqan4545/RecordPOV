package studio.roast.app

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

data class CaptionCue(val startMs:Long,val endMs:Long,val text:String)
data class DraftEdits(val gains:MixGains=MixGains(),val trimStartMs:Long=0,val trimEndMs:Long,
                      val cuts:List<EditRange> = emptyList(),val musicName:String?=null,val loopMusic:Boolean=false,
                      val captions:List<CaptionCue> = emptyList(),val showCaptions:Boolean=true,val voiceCleanupEnabled:Boolean=true)
data class ReactionDraft(val id:String,val title:String,val durationMs:Long,val directory:File,
                         val edits:DraftEdits,val revision:Long=0,val sourceAvailable:Boolean=false,
                         val microphoneRms:Double=0.0,val sourceRms:Double=0.0,val preparationError:String?=null) {
    val capture:File get()=File(directory,"capture.mp4")
    val microphone:File get()=File(directory,"microphone.wav")
    val source:File get()=File(directory,"source.wav")
    val music:File? get()=edits.musicName?.let{File(directory,it)}
    val ranges:List<EditRange> get()=retainedRanges(durationMs,edits.trimStartMs,edits.trimEndMs,edits.cuts)
    val outputDurationMs:Long get()=ranges.sumOf{it.durationMs}
    val audioReady:Boolean get()=preparationError==null&&microphone.isFile&&source.isFile
}

internal fun storedMixGains(edit:JSONObject)=MixGains(edit.optDouble("sourceGain",1.0).toFloat(),
    edit.optDouble("microphoneGain",.6).toFloat(),edit.optDouble("musicGain",.25).toFloat()).clamped()

class DraftStore(private val context:Context) {
    val directory=File(context.filesDir,"drafts").apply{mkdirs()}
    private val preferences=context.getSharedPreferences("roast",Context.MODE_PRIVATE)
    private val projects=DraftProjectFiles(directory)
    fun newCapture():File=File(directory,"capture-${UUID.randomUUID()}.mp4")
    fun list():List<ReactionDraft> = directory.listFiles().orEmpty().filter{it.isDirectory}.mapNotNull{load(it.name)}
        .sortedByDescending{File(it.directory,"project.json").lastModified()}
    fun delete(id:String) {
        OwnedMediaDeletion.draft(directory,id)
        if(preferences.getString("pendingDraft",null)==id)preferences.edit().remove("pendingDraft").apply()
    }
    fun load(id:String):ReactionDraft?=projects.load(id)
    fun save(draft:ReactionDraft)=projects.save(draft)
    fun saveEdits(draft:ReactionDraft):ReactionDraft=projects.saveEdits(draft)
    fun markPending(draft:ReactionDraft){preferences.edit().putString("pendingDraft",draft.id).apply()}
    fun consumePending():ReactionDraft? {
        val id=preferences.getString("pendingDraft",null)?:return null
        preferences.edit().remove("pendingDraft").apply()
        return load(id)
    }
    suspend fun prepare(capture:File,segments:List<SourceAudioSegment>,fallbackDurationMs:Long,title:String="Your video",prepareStems:Boolean=true):ReactionDraft=withContext(Dispatchers.IO) {
        val root=File(directory,UUID.randomUUID().toString()).apply{mkdirs()}
        val original=File(root,"capture.mp4")
        check(capture.renameTo(original)){"The original recording could not be moved into its draft."}
        val duration=runCatching{MediaMetadataRetriever().use{it.setDataSource(original.absolutePath);it.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()}}
            .getOrNull()?.takeIf{it>0}?:fallbackDurationMs.coerceAtLeast(1)
        var draft=ReactionDraft(root.name,title,duration,root,DraftEdits(trimEndMs=duration),preparationError="Audio is being prepared.")
        File(root,"source-timeline.json").writeText(JSONArray(segments.map{JSONObject().put("uri",it.uri.toString()).put("timelineStartMs",it.timelineStartMs)
            .put("sourceStartMs",it.sourceStartMs).put("durationMs",it.durationMs)}).toString())
        save(draft)
        try {
            // A draft must not depend on expiring resolver cache or an external document
            // after the editor is closed, even if audio preparation is interrupted.
            val retained=mutableMapOf<String,Uri>()
            segments.map{it.uri}.distinct().forEachIndexed{index,uri ->
                val asset=File(root,"source-asset-$index.mp4")
                val temporary=File(root,"source-asset-$index.copy")
                try {
                    checkNotNull(context.contentResolver.openInputStream(uri)){"The original source video could not be opened."}.use{input->
                        temporary.outputStream().use{output->
                            val buffer=ByteArray(256*1024)
                            while(true){currentCoroutineContext().ensureActive();val count=input.read(buffer);if(count<0)break;output.write(buffer,0,count)}
                        }
                    }
                    check(temporary.length()>0&&temporary.renameTo(asset)){"The source video could not be retained in your draft."}
                    retained[uri.toString()]=Uri.fromFile(asset)
                }finally{temporary.delete()}
            }
            val savedTimeline=JSONArray(segments.map{JSONObject().put("uri",retained.getValue(it.uri.toString()).toString()).put("timelineStartMs",it.timelineStartMs)
                .put("sourceStartMs",it.sourceStartMs).put("durationMs",it.durationMs)})
            val temporary=File(root,"source-timeline.json.tmp")
            temporary.writeText(savedTimeline.toString())
            check(temporary.renameTo(File(root,"source-timeline.json"))){"The source timeline could not be retained in your draft."}
        }catch(e:CancellationException){save(draft.copy(preparationError="Draft preparation was cancelled. Your original capture is safe."));throw e}
        catch(e:Exception){return@withContext draft.copy(preparationError="Source retention failed. Your original capture is safe. ${e.localizedMessage.orEmpty()}").also{save(it)}}
        if(prepareStems)draft=prepareAudio(draft)
        draft
    }
    suspend fun prepareAudio(draft:ReactionDraft):ReactionDraft=withContext(Dispatchers.IO) {
        DraftAudioPreparationGate.run(draft.directory) {
            val latest=projects.load(draft.id)?:return@run draft.copy(preparationError="This draft is no longer available.")
            if(latest.audioReady)return@run latest
            var prepared=draft
            try {
                StemDecoder.decode(context,Uri.fromFile(draft.capture),draft.microphone)
                createSilentWave(draft.source,frameAtMs(draft.durationMs))
                val segments=JSONArray(File(draft.directory,"source-timeline.json").readText()).objects()
                var available=false
                for(group in segments.groupBy{it.getString("uri")}.entries) {
                    currentCoroutineContext().ensureActive()
                    val decoded=File(draft.directory,"source-decoding.wav")
                    try {
                        StemDecoder.decode(context,Uri.parse(group.key),decoded);available=true
                        group.value.forEach {segment ->
                            sourceStemSpan(segment.getLong("timelineStartMs"),segment.getLong("sourceStartMs"),segment.getLong("durationMs"),frameAtMs(draft.durationMs))
                                ?.let{copyWaveSpan(decoded,draft.source,it)}
                        }
                    }catch(_:NoAudioTrack){/* A silent original clip is a valid source. */}
                    finally{decoded.delete()}
                }
                val micRms=WaveReader(draft.microphone).use{it.rms()}
                val sourceRms=WaveReader(draft.source).use{it.rms()}
                prepared=draft.copy(sourceAvailable=available,microphoneRms=micRms,sourceRms=sourceRms,preparationError=null)
            }catch(e:CancellationException){projects.completeAudio(draft.copy(preparationError="Audio preparation was cancelled. Your original recording is safe; retry when ready."));throw e}
            catch(e:Exception){prepared=draft.copy(preparationError="Audio preparation failed. ${e.localizedMessage.orEmpty()} Your original recording is safe.")}
            projects.completeAudio(prepared)?:prepared.copy(preparationError="This draft is no longer available.")
        }
    }
    suspend fun importMusic(draft:ReactionDraft,uri:Uri):ReactionDraft {
        val name="music-${UUID.randomUUID()}.wav"
        StemDecoder.decode(context,uri,File(draft.directory,name))
        return saveEdits(draft.copy(edits=draft.edits.copy(musicName=name),revision=draft.revision+1))
    }
}
private fun JSONArray?.objects():List<JSONObject> = if(this==null)emptyList()else (0 until length()).map{getJSONObject(it)}

suspend fun mixDraftAudio(draft:ReactionDraft,destination:File)=withContext(Dispatchers.IO) {
    check(draft.audioReady){draft.preparationError?:"Prepare your audio before previewing."}
    val mic=WaveReader(microphoneForMix(draft));val source=WaveReader(draft.source)
    val music=draft.music?.let{WaveReader(it)}
    try {
        WaveWriter(destination).use{writer ->
            var outputFrame=0L
            for(range in draft.ranges) {
                var cursor=frameAtMs(range.startMs);val end=frameAtMs(range.endMs)
                while(cursor<end) {
                    currentCoroutineContext().ensureActive()
                    val count=minOf(16_384L,end-cursor).toInt()
                    writer.write(StemMixer.mix(mic.read(cursor,count),source.read(cursor,count),music?.read(outputFrame,count,draft.edits.loopMusic)?:FloatArray(count),draft.edits.gains,count))
                    cursor+=count;outputFrame+=count
                }
            }
        }
    }finally{mic.close();source.close();music?.close()}
}
