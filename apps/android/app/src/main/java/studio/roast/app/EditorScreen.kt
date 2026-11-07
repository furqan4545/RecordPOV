package studio.roast.app

import android.graphics.Matrix
import android.os.Handler
import android.os.Looper
import android.view.TextureView
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.OptIn
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.video.VideoFrameMetadataListener
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

private data class PreviewBuild(val draft:ReactionDraft,val sourcePositionMs:Long,val playAfter:Boolean,val generation:Long)

@OptIn(UnstableApi::class)
@kotlin.OptIn(ExperimentalMaterial3Api::class)
@Composable fun EditorScreen(initialDraft:ReactionDraft,store:TakeStore,onClose:()->Unit,onDone:(File)->Unit) {
    val context=LocalContext.current
    val scope=rememberCoroutineScope()
    val drafts=remember{DraftStore(context)}
    var draft by remember(initialDraft.id){mutableStateOf(initialDraft)}
    var error by remember{mutableStateOf<String?>(initialDraft.preparationError?.takeUnless{it=="Audio is being prepared."})}
    var working by remember{mutableStateOf<String?>(null)}
    var audioPreparing by remember{mutableStateOf(false)}
    var audioTask by remember{mutableStateOf<Job?>(null)}
    var progress by remember{mutableStateOf<Float?>(null)}
    var task by remember{mutableStateOf<Job?>(null)}
    var previewRevision by remember{mutableStateOf<Long?>(null)}
    var playing by remember{mutableStateOf(false)}
    var captionsOpen by remember{mutableStateOf(false)}
    var trimBounds by remember{mutableStateOf(visibleTrimBounds(initialDraft.durationMs,initialDraft.edits.trimStartMs,initialDraft.edits.trimEndMs))}
    var playhead by remember{mutableLongStateOf(trimBounds.startMs)}
    var dragging by remember{mutableStateOf(false)}
    var viewingOriginal by remember{mutableStateOf(true)}
    var previewWorking by remember{mutableStateOf(false)}
    var previewRanges by remember{mutableStateOf(initialDraft.ranges)}
    var buildGeneration by remember{mutableLongStateOf(0)}
    val previewRequests=remember{MutableStateFlow<PreviewBuild?>(null)}
    val previewMutex=remember{Mutex()}
    var language by remember{mutableStateOf("en")}
    var languageMenu by remember{mutableStateOf(false)}
    var finalFile by remember{mutableStateOf<File?>(null)}
    val preview=remember(initialDraft.id){File(initialDraft.directory,"preview.mp4")}
    val player=remember{ExoPlayer.Builder(context).build()}
    val original=remember{ExoPlayer.Builder(context).build().apply{
        volume=0f;setSeekParameters(SeekParameters.EXACT)
        setMediaItem(MediaItem.fromUri(android.net.Uri.fromFile(initialDraft.capture)));prepare()
    }}
    val seekGate=remember{LatestFrameSeekGate()}
    val seekHandler=remember{Handler(Looper.getMainLooper())}
    val busy=working!=null
    val storedTrim=TrimBounds(draft.edits.trimStartMs,draft.edits.trimEndMs)
    val validTrim=storedTrim.validFor(draft.durationMs)&&draft.edits.cuts.isEmpty()
    fun issueSeek(request:FrameSeek?) {
        if(request==null)return
        original.seekTo(request.positionMs)
        seekHandler.postDelayed({issueSeek(seekGate.timeout(request.id))},100)
    }
    fun seekOriginal(positionMs:Long) {
        player.pause();viewingOriginal=true
        playhead=positionMs.coerceIn(0,draft.durationMs)
        issueSeek(seekGate.request(playhead.coerceAtMost((draft.durationMs-1).coerceAtLeast(0))))
    }
    fun requestPreview(playAfter:Boolean) {
        if(!draft.audioReady||!TrimBounds(draft.edits.trimStartMs,draft.edits.trimEndMs).validFor(draft.durationMs)||draft.edits.cuts.isNotEmpty())return
        if(previewRevision==draft.revision&&preview.length()>0) {
            if(playAfter){val position=editedPositionAtOriginal(playhead,draft.ranges);player.seekTo(if(position>=draft.outputDurationMs)0 else position);viewingOriginal=false;player.play()}
        }else previewRequests.value=PreviewBuild(draft,playhead,playAfter,++buildGeneration)
    }
    fun update(next:DraftEdits) {
        previewRequests.value=null;player.pause();viewingOriginal=true
        val changed=draft.copy(edits=next,revision=draft.revision+1)
        try{draft=drafts.saveEdits(changed);error=null;seekOriginal(playhead)}catch(e:Exception){error=e.localizedMessage}
    }
    fun commitTrim(bounds:TrimBounds) {
        dragging=false
        if(!bounds.validFor(draft.durationMs)){error="Keep at least a quarter of a second. Reset trim to recover this draft.";return}
        trimBounds=bounds
        if(draft.edits.trimStartMs!=bounds.startMs||draft.edits.trimEndMs!=bounds.endMs||draft.edits.cuts.isNotEmpty())
            update(contiguousTrimEdits(draft.edits,bounds,draft.durationMs))
        requestPreview(false)
    }
    fun work(label:String,block:suspend()->Unit) {
        if(working!=null)return
        previewRequests.value=null;player.pause();working=label;error=null;progress=null
        task=scope.launch {
            try{block()}catch(e:CancellationException){throw e}
            catch(e:Exception){error=e.localizedMessage?:"This change could not be prepared. Your draft is safe."}
            finally{working=null;progress=null;task=null}
        }
    }
    fun cancelWork(){task?.cancel();if(working?.startsWith("Transcribing")==true)working="Cancelling after this speech segment…"}
    fun prepareAudio() {
        if(audioPreparing||draft.audioReady)return
        audioPreparing=true
        if(error?.startsWith("Audio preparation")==true)error=null
        val input=draft
        audioTask=scope.launch {
            try {
                val ready=drafts.prepareAudio(input)
                // The user can trim, change levels and captions while this runs.
                // Only prepared-audio facts are merged back into the latest UI state.
                draft=mergePreparedAudio(draft,ready)
                if(ready.preparationError!=null)error=ready.preparationError
                else if(error?.startsWith("Audio preparation")==true)error=null
                if(draft.audioReady)requestPreview(false)
            }catch(e:CancellationException){throw e}
            catch(e:Exception){error="The sound could not be prepared. Your draft and edits are saved. ${e.localizedMessage.orEmpty()}"}
            finally{audioPreparing=false;audioTask=null}
        }
    }
    LaunchedEffect(initialDraft.id) {
        seekOriginal(trimBounds.startMs)
        if(draft.preparationError=="Audio is being prepared."||draft.preparationError?.startsWith("Audio preparation was cancelled.")==true)prepareAudio()
    }
    DisposableEffect(initialDraft.id){onDispose{audioTask?.cancel()}}
    LaunchedEffect(Unit) {
        previewRequests.collectLatest {request ->
            if(request==null)return@collectLatest
            delay(250)
            previewWorking=true
            try {
                previewMutex.withLock{renderDraft(context,request.draft,preview)}
                if(previewRequests.value?.generation==request.generation) {
                    previewRevision=request.draft.revision;previewRanges=request.draft.ranges
                    player.setMediaItem(MediaItem.fromUri(android.net.Uri.fromFile(preview)));player.prepare()
                    val position=editedPositionAtOriginal(request.sourcePositionMs,request.draft.ranges)
                    player.seekTo(if(request.playAfter&&position>=request.draft.outputDurationMs)0 else position)
                    if(request.playAfter){viewingOriginal=false;player.play()}
                }
            }catch(e:CancellationException){throw e}
            catch(e:Exception){error="Preview could not be prepared. Your trim and draft are saved. ${e.localizedMessage.orEmpty()}"}
            finally{previewWorking=false}
        }
    }
    LaunchedEffect(player) {while(true){
        if(!viewingOriginal&&player.isPlaying&&!dragging)playhead=originalPositionAtEdited(player.currentPosition,previewRanges)
        delay(40)
    }}
    DisposableEffect(original) {
        val listener=VideoFrameMetadataListener{timeUs,_,_,_->seekHandler.post{issueSeek(seekGate.rendered(timeUs/1_000))}}
        val errors=object:Player.Listener {override fun onPlayerError(errorValue:androidx.media3.common.PlaybackException){error="The original video could not be previewed. Your draft is safe. ${errorValue.localizedMessage.orEmpty()}"}}
        original.setVideoFrameMetadataListener(listener)
        original.addListener(errors)
        onDispose{seekGate.cancel();seekHandler.removeCallbacksAndMessages(null);original.clearVideoFrameMetadataListener(listener);original.removeListener(errors);original.release()}
    }
    val importer=rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()){uri ->
        if(uri!=null)work("Preparing music…") {draft=drafts.importMusic(draft,uri)}
    }
    DisposableEffect(player) {
        val listener=object:Player.Listener{override fun onIsPlayingChanged(isPlaying:Boolean){playing=isPlaying}}
        player.addListener(listener)
        onDispose{player.removeListener(listener);player.release()}
    }
    BackHandler{if(busy)cancelWork()else onClose()}
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal=12.dp).height(52.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.SpaceBetween) {
            IconButton(onClick=onClose,enabled=!busy,modifier=Modifier.size(44.dp)){Icon(Icons.Rounded.Close,"Close editor; keep draft")}
            Text("Edit video",fontWeight=FontWeight.Bold,fontSize=17.sp)
            Button(onClick={work("Finishing your video…") {
                val target=File(store.directory,"Video ${draft.id.take(8)}-v${draft.revision}.mp4")
                previewMutex.withLock {
                    if(previewRevision==draft.revision&&preview.length()>0)withContext(Dispatchers.IO){
                        val temporary=File(store.directory,".${target.name}.copy")
                        try{preview.copyTo(temporary,overwrite=true);check(temporary.renameTo(target)){"Your final app copy could not be saved. The draft is safe."}}
                        finally{temporary.delete()}
                    }
                    else renderDraft(context,draft,target)
                }
                finalFile=target
                try{store.saveToPhotos(target)}catch(e:Exception){throw IllegalStateException("Gallery save failed. Your final video and editable draft are safe in RecordPOV. Tap Save to retry. ${e.localizedMessage.orEmpty()}",e)}
                onDone(target)
            }},enabled=!busy&&!dragging&&draft.audioReady&&validTrim,modifier=Modifier.height(48.dp),shape=RoundedCornerShape(12.dp),contentPadding=PaddingValues(horizontal=18.dp)) {Text("Save")}
        }
        LazyColumn(Modifier.weight(1f),contentPadding=PaddingValues(horizontal=18.dp,vertical=12.dp),verticalArrangement=Arrangement.spacedBy(14.dp)) {
            item {
                Box(Modifier.fillMaxWidth().height(245.dp).clip(RoundedCornerShape(16.dp)).background(Ink),contentAlignment=Alignment.Center) {
                    EditorVideoSurface(original,Modifier.fillMaxSize())
                    if(!viewingOriginal&&previewRevision!=null)EditorVideoSurface(player,Modifier.fillMaxSize())
                    if(viewingOriginal)Text("Trim preview · ${formatTimelineTime(playhead)}",fontSize=10.sp,color=Color.White,
                        modifier=Modifier.align(Alignment.TopStart).padding(10.dp).background(Ink.copy(alpha=.72f),RoundedCornerShape(7.dp)).padding(horizontal=8.dp,vertical=5.dp))
                    IconButton(onClick={if(playing&&!viewingOriginal)player.pause()else requestPreview(true)},
                        enabled=!busy&&!dragging&&!previewWorking&&draft.audioReady&&validTrim,modifier=Modifier.align(Alignment.BottomStart).padding(8.dp).size(44.dp).background(Ink.copy(alpha=.7f),RoundedCornerShape(12.dp))) {
                        Icon(if(playing&&!viewingOriginal)Icons.Rounded.Pause else Icons.Rounded.PlayArrow,if(playing&&!viewingOriginal)"Pause edited preview"else "Play edited preview",tint=Color.White)
                    }
                }
            }
            item {
                Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.SpaceBetween) {
                    Text("${formatTimelineTime(trimBounds.durationMs)}  ·  Draft saved",fontSize=11.sp,color=Muted)
                    OutlinedButton(onClick={requestPreview(true)},enabled=!busy&&!dragging&&!previewWorking&&draft.audioReady&&validTrim,
                        modifier=Modifier.height(40.dp),shape=RoundedCornerShape(12.dp)) {
                        if(previewWorking)CircularProgressIndicator(Modifier.size(15.dp),strokeWidth=2.dp)
                        else Icon(Icons.Rounded.PlayArrow,null,Modifier.size(18.dp))
                        Spacer(Modifier.width(5.dp));Text(if(previewWorking)"Updating preview…"else "Preview mix",fontSize=11.sp)
                    }
                }
            }
            item {
                Column(verticalArrangement=Arrangement.spacedBy(2.dp)) {
                    Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.SpaceBetween) {
                        Text("Trim",fontSize=15.sp,fontWeight=FontWeight.Bold)
                        TextButton(onClick={
                            previewRequests.value=null;seekOriginal(0)
                            commitTrim(TrimBounds(0,draft.durationMs))
                        },enabled=!busy&&!dragging,modifier=Modifier.height(40.dp),shape=RoundedCornerShape(12.dp)){Text("Reset trim",fontSize=12.sp)}
                    }
                    ThumbnailTimeline(draft.capture,draft.durationMs,trimBounds,playhead,!busy,
                        onBegin={dragging=true;previewRequests.value=null;player.pause();viewingOriginal=true},
                        onTrim={bounds,edge->trimBounds=bounds;seekOriginal(if(edge==TrimEdge.Start)bounds.startMs else bounds.endMs)},
                        onScrub={seekOriginal(it)},onCommit={commitTrim(it)},
                        onScrubEnd={dragging=false;requestPreview(false)},
                        onCancel={dragging=false;trimBounds=visibleTrimBounds(draft.durationMs,draft.edits.trimStartMs,draft.edits.trimEndMs);requestPreview(false)})
                    if(!storedTrim.validFor(draft.durationMs)||draft.edits.cuts.isNotEmpty())Text(
                        if(draft.edits.cuts.isNotEmpty())"This draft has older cuts. Move a trim edge or Reset trim to save one continuous section."
                        else "This draft's trim needs resetting. Tap Reset trim before saving.",fontSize=12.sp,lineHeight=17.sp,color=MaterialTheme.colorScheme.error)
                }
            }
            if(busy)item {
                Column(verticalArrangement=Arrangement.spacedBy(6.dp)) {
                    Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(16.dp),strokeWidth=2.dp)
                        Text(working.orEmpty(),Modifier.weight(1f).padding(start=9.dp),fontSize=12.sp)
                        TextButton(onClick={cancelWork()},modifier=Modifier.height(40.dp)){Text("Cancel",fontSize=12.sp)}
                    }
                    progress?.let{LinearProgressIndicator(progress={it},modifier=Modifier.fillMaxWidth())}
                }
            }
            error?.let{message->item{Text(message,color=MaterialTheme.colorScheme.error,fontSize=12.sp,lineHeight=17.sp)}}
            if(audioPreparing)item {
                Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(9.dp)) {
                    CircularProgressIndicator(Modifier.size(16.dp),strokeWidth=2.dp)
                    Text("Getting the sound ready… You can keep editing.",fontSize=12.sp,color=Muted)
                }
            }
            if(!draft.audioReady&&!audioPreparing)item {
                OutlinedButton(onClick={prepareAudio()},enabled=!busy,
                    modifier=Modifier.height(44.dp),shape=RoundedCornerShape(12.dp)){Text("Retry audio preparation")}
            }
            item {
                Surface(color=Color.White,shape=RoundedCornerShape(16.dp)) {
                    Column(Modifier.padding(14.dp),verticalArrangement=Arrangement.spacedBy(4.dp)) {
                        Text("Audio",fontSize=15.sp,fontWeight=FontWeight.Bold)
                        GainControl("Source video",draft.edits.gains.source,!busy){update(draft.edits.copy(gains=draft.edits.gains.copy(source=it)))}
                        if(draft.audioReady&&!draft.sourceAvailable)Text("No original video audio in this recording.",fontSize=11.sp,color=Muted)
                        GainControl("Your microphone",draft.edits.gains.microphone,!busy){update(draft.edits.copy(gains=draft.edits.gains.copy(microphone=it)))}
                        Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
                            Column(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(3.dp)) {
                                Text("Clean voice",fontSize=12.sp,fontWeight=FontWeight.SemiBold)
                                Text("Gently reduces rumble and steady hiss. Your original voice is kept.",fontSize=11.sp,lineHeight=15.sp,color=Muted)
                            }
                            Switch(checked=draft.edits.voiceCleanupEnabled,onCheckedChange={update(draft.edits.copy(voiceCleanupEnabled=it))},enabled=!busy)
                        }
                        if(draft.audioReady&&draft.microphoneRms<.0001)Text("The microphone stem is silent. Check the preview before exporting.",fontSize=11.sp,color=MaterialTheme.colorScheme.error)
                        if(draft.sourceAvailable&&draft.sourceRms<.0001)Text("The source stem is silent in this recording.",fontSize=11.sp,color=Muted)
                        GainControl("Music",draft.edits.gains.music,!busy&&draft.music!=null){update(draft.edits.copy(gains=draft.edits.gains.copy(music=it)))}
                        Row(verticalAlignment=Alignment.CenterVertically) {
                            OutlinedButton(onClick={importer.launch(arrayOf("audio/*"))},enabled=!busy,modifier=Modifier.height(40.dp),shape=RoundedCornerShape(12.dp)) {
                                Icon(Icons.Rounded.AudioFile,null,Modifier.size(17.dp));Spacer(Modifier.width(6.dp));Text(if(draft.music==null)"Add music"else "Replace music",fontSize=12.sp)
                            }
                            if(draft.music!=null)TextButton(onClick={update(draft.edits.copy(musicName=null))},enabled=!busy,modifier=Modifier.height(40.dp)){Text("Remove",fontSize=12.sp)}
                        }
                        if(draft.music!=null)Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
                            Text("Loop music",fontSize=12.sp,modifier=Modifier.weight(1f))
                            Switch(checked=draft.edits.loopMusic,onCheckedChange={update(draft.edits.copy(loopMusic=it))},enabled=!busy)
                        }
                    }
                }
            }
            item {
                TextButton(onClick={captionsOpen=!captionsOpen},modifier=Modifier.fillMaxWidth().height(44.dp),shape=RoundedCornerShape(12.dp)) {
                    Icon(Icons.Rounded.ClosedCaption,null,Modifier.size(18.dp));Spacer(Modifier.width(8.dp));Text("Captions");Spacer(Modifier.weight(1f));Icon(if(captionsOpen)Icons.Rounded.ExpandLess else Icons.Rounded.ExpandMore,null)
                }
            }
            if(captionsOpen)item {
                Column(verticalArrangement=Arrangement.spacedBy(9.dp)) {
                    Text("Transcribe only your microphone, on this phone. The first use downloads a 104 MB speech model; your audio stays here. Captions use measured speech segments. Review the text and timing before finishing.",fontSize=12.sp,lineHeight=17.sp,color=Muted)
                    Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                        Box {
                            OutlinedButton(onClick={languageMenu=true},enabled=!busy,modifier=Modifier.height(40.dp),shape=RoundedCornerShape(12.dp)) {Text(if(language.isBlank())"Auto language"else mapOf("en" to "English","ur" to "Urdu","hi" to "Hindi","ko" to "Korean")[language].orEmpty(),fontSize=12.sp)}
                            DropdownMenu(expanded=languageMenu,onDismissRequest={languageMenu=false}) {
                                listOf("" to "Auto","en" to "English","ur" to "Urdu","hi" to "Hindi","ko" to "Korean").forEach{(code,label)->DropdownMenuItem(text={Text(label)},onClick={language=code;languageMenu=false})}
                            }
                        }
                        Button(onClick={work("Preparing on-device captions…") {
                            val cues=OfflineCaptions(context).generate(draft,language){label,value->working=label;progress=value}
                            update(draft.edits.copy(captions=cues,showCaptions=true))
                            if(cues.isEmpty())error="No speech was found in your microphone stem."
                        }},enabled=!busy&&draft.audioReady,modifier=Modifier.height(40.dp),shape=RoundedCornerShape(12.dp)) {Text(if(draft.edits.captions.isEmpty())"Generate captions"else "Regenerate",fontSize=12.sp)}
                    }
                    if(draft.edits.captions.isNotEmpty())Row(verticalAlignment=Alignment.CenterVertically) {
                        Text("Show captions in video",Modifier.weight(1f),fontSize=12.sp)
                        Switch(draft.edits.showCaptions,{update(draft.edits.copy(showCaptions=it))},enabled=!busy)
                    }
                    draft.edits.captions.forEachIndexed{index,cue ->
                        OutlinedTextField(cue.text,{text->update(draft.edits.copy(captions=draft.edits.captions.toMutableList().apply{this[index]=cue.copy(text=text)}))},
                            label={Text(formatTime(cue.startMs),fontSize=11.sp)},enabled=!busy,modifier=Modifier.fillMaxWidth(),shape=RoundedCornerShape(12.dp))
                    }
                }
            }
            finalFile?.let{file->item{OutlinedButton(onClick={store.share(file)},enabled=!busy,modifier=Modifier.height(44.dp),shape=RoundedCornerShape(12.dp)){Text("Share final app copy")}}}
            item {Text("Your original video, isolated audio, and edits stay saved as a draft. Save exports the selected start-to-end section to Gallery.",fontSize=11.sp,lineHeight=16.sp,color=Muted)}
        }
    }
}

@Composable private fun GainControl(label:String,value:Float,enabled:Boolean,onChange:(Float)->Unit) {
    Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(9.dp)) {
        Text(label,fontSize=12.sp,modifier=Modifier.width(104.dp),color=if(enabled)Ink else Muted)
        Slider(value=value.coerceIn(0f,2f),onValueChange=onChange,valueRange=0f..2f,enabled=enabled,modifier=Modifier.weight(1f).semantics{contentDescription="$label volume"})
        Text(if(value==0f)"Mute"else "${(value*100).toInt()}%",fontSize=11.sp,color=Muted,modifier=Modifier.width(37.dp))
    }
}

@OptIn(UnstableApi::class)
@Composable private fun EditorVideoSurface(player:ExoPlayer,modifier:Modifier) {
    var surface by remember(player){mutableStateOf<EditorPreviewTexture?>(null)}
    DisposableEffect(player) {
        val listener=object:Player.Listener {override fun onVideoSizeChanged(videoSize:VideoSize){
            if(videoSize.height>0)surface?.videoAspect=videoSize.width*videoSize.pixelWidthHeightRatio/videoSize.height
        }}
        player.addListener(listener)
        onDispose{player.removeListener(listener)}
    }
    AndroidView(factory={ctx->EditorPreviewTexture(ctx).also{view ->
        surface=view
        player.setVideoTextureView(view)
        val size=player.videoSize
        if(size.height>0)view.videoAspect=size.width*size.pixelWidthHeightRatio/size.height
    }},modifier=modifier)
}

private class EditorPreviewTexture(context:android.content.Context):TextureView(context) {
    var videoAspect=9f/16f
        set(value){field=value;fitFrame()}
    override fun onSizeChanged(w:Int,h:Int,oldw:Int,oldh:Int){super.onSizeChanged(w,h,oldw,oldh);fitFrame()}
    private fun fitFrame(){
        if(width<=0||height<=0)return
        val aspect=width.toFloat()/height
        setTransform(Matrix().apply{setScale(if(videoAspect<aspect)videoAspect/aspect else 1f,if(videoAspect>aspect)aspect/videoAspect else 1f,width/2f,height/2f)})
    }
}
