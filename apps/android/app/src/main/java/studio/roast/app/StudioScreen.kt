package studio.roast.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.RectF
import android.os.SystemClock
import android.view.TextureView
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.OptIn
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import kotlinx.coroutines.delay
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.io.File
import kotlin.math.roundToInt

@OptIn(UnstableApi::class)
@kotlin.OptIn(ExperimentalMaterial3Api::class)
@Composable fun StudioScreen(initialSource:MediaSource,store:TakeStore,
    enableCamera:((()->Unit),(()->Unit))->Unit,onClose:()->Unit,onDraftReady:(ReactionDraft)->Unit) {
    val context=LocalContext.current
    val owner=LocalLifecycleOwner.current
    val scope=rememberCoroutineScope()
    var source by remember{mutableStateOf(initialSource)}
    var sources by remember{mutableStateOf(listOf(initialSource))}
    val sourcePositions=remember{mutableMapOf<String,Long>()}
    var picture by remember{mutableStateOf<Bitmap?>(null)}
    var preparingSource by remember{mutableStateOf(!initialSource.isImage)}
    var placement by remember{mutableStateOf(PipPlacement(style=PipStyle.Cutout))}
    var fullScreenCamera by remember{mutableStateOf(false)}
    var stageLayout by remember{mutableStateOf(StageLayout())}
    var layoutMenu by remember{mutableStateOf(false)}
    var camera by remember{mutableStateOf<CameraFeed?>(null)}
    val noLens=remember{MutableStateFlow(CameraLens.Front)}
    val lens by (camera?.lens?:noLens).collectAsState()
    val noSwitch=remember{MutableStateFlow(false)}
    val switchingCamera by (camera?.switching?:noSwitch).collectAsState()
    val screenActive by ScreenTakeService.running.collectAsState()
    var frame by remember{mutableStateOf<Bitmap?>(null)}
    val player=remember{ExoPlayer.Builder(context).build().apply{repeatMode=Player.REPEAT_MODE_OFF}}
    var texture by remember{mutableStateOf<SourceTextureView?>(null)}
    var sourceVideoAspect by remember{mutableFloatStateOf(9f/16f)}
    var videoFrame by remember{mutableStateOf<Bitmap?>(null)}
    var videoFrameRevision by remember{mutableIntStateOf(0)}
    var playing by remember{mutableStateOf(false)}
    var duration by remember{mutableLongStateOf(0)}
    var position by remember{mutableLongStateOf(0)}
    var recorder by remember{mutableStateOf<TakeRecorder?>(null)}
    val noVoiceProtection=remember{MutableStateFlow(VoiceProtectionStatus())}
    val voiceProtection by (recorder?.voiceProtection?:noVoiceProtection).collectAsState()
    var recording by remember{mutableStateOf(false)}
    var saving by remember{mutableStateOf(false)}
    var starting by remember{mutableStateOf(false)}
    var recordingDelay by remember{mutableStateOf(store.recordingDelay)}
    var countdownRemaining by remember{mutableStateOf<Int?>(null)}
    var startJob by remember{mutableStateOf<Job?>(null)}
    var elapsed by remember{mutableLongStateOf(0)}
    var startedAt by remember{mutableLongStateOf(0)}
    var pausedTotal by remember{mutableLongStateOf(0)}
    var pausedAt by remember{mutableLongStateOf(0)}
    var pickingMedia by remember{mutableStateOf(false)}
    var error by remember{mutableStateOf<String?>(null)}
    var studioOpen by remember{mutableStateOf(true)}
    var pendingRecordAfterPermission by remember{mutableStateOf(false)}
    val timeline=remember{SourceAudioTimeline()}
    val latestSource by rememberUpdatedState(source)
    val latestRecording by rememberUpdatedState(recording)
    val latestPicking by rememberUpdatedState(pickingMedia)
    var importingImage by remember{mutableStateOf(true)}
    fun takeClock():Long = SystemClock.elapsedRealtime()-startedAt-pausedTotal-
        (if(pausedAt>0)SystemClock.elapsedRealtime()-pausedAt else 0)
    val latestClock by rememberUpdatedState({takeClock()})
    fun startCamera() {
        if(!studioOpen||!owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))return
        if(screenActive){error="Finish your screen recording before starting another camera recording.";return}
        if(camera==null)camera=CameraFeed(context).also{it.removeBackground=placement.style==PipStyle.Cutout;it.start(owner){message->error=message}}
    }
    val defaultCameraPermission=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()){granted ->
        if(granted)startCamera()else error="Allow camera access to add yourself. You can change this in Android Settings."
    }
    LaunchedEffect(Unit) {
        if(!screenActive) {
            if(ContextCompat.checkSelfPermission(context,Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED)startCamera()
            else defaultCameraPermission.launch(Manifest.permission.CAMERA)
        }
    }
    fun selectSource(next:MediaSource) {
        if(recording)timeline.close(player.currentPosition,takeClock())
        if(!source.isImage)sourcePositions[source.uri.toString()]=player.currentPosition
        player.pause();source=next
    }
    val importer=rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()){uri ->
        uri?.let {
            runCatching{context.contentResolver.takePersistableUriPermission(it,Intent.FLAG_GRANT_READ_URI_PERMISSION)}
            val next=MediaSource(it,if(importingImage) "Photo ${sources.count{item->item.isImage}+1}" else "Your video",importingImage)
            sources=(sources+next).distinctBy{item->item.uri};selectSource(next)
        }
        if(recording&&pausedAt>0)scope.launch {
            try{recorder?.resume();pausedTotal+=SystemClock.elapsedRealtime()-pausedAt;pausedAt=0}
            catch(e:Exception){error="Recording could not resume. Finish the recording and try again."}
            finally{pickingMedia=false}
        } else pickingMedia=false
    }
    fun importPhoto() {
        importingImage=true
        scope.launch {
            if(recording) {
                timeline.close(player.currentPosition,takeClock());player.pause()
                try{recorder?.pause();pausedAt=SystemClock.elapsedRealtime()}
                catch(e:Exception){error="Finish your video before importing another photo.";return@launch}
            }
            pickingMedia=true;importer.launch(arrayOf("image/*"))
        }
    }

    fun finishTake() {
        if(!recording || saving)return
        val total=takeClock()
        timeline.close(player.currentPosition,total)
        recording=false;playing=false;player.pause();saving=true
        scope.launch {
            try {
                val file=recorder!!.stop()
                val draft=DraftStore(context).prepare(file,timeline.segments.map{SourceAudioSegment(android.net.Uri.parse(it.sourceId),it.timelineStartMs,it.sourceStartMs,it.durationMs)},total,initialSource.title,prepareStems=false)
                onDraftReady(draft)
            }catch(e:Exception){error="The recording could not be saved. ${e.localizedMessage ?: "Try recording for at least a second."}"}
            finally{recorder=null;saving=false}
        }
    }
    fun cancelCountdown(){startJob?.cancel();countdownRemaining=null}
    fun startTake() {
        if(!studioOpen||!owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)||starting||saving||recording)return
        if(ContextCompat.checkSelfPermission(context,Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED) {
            if(pendingRecordAfterPermission)return
            pendingRecordAfterPermission=true
            enableCamera({pendingRecordAfterPermission=false;startTake()},
                {pendingRecordAfterPermission=false;error="Allow microphone access to record your voice."})
            return
        }
        starting=true;error=null;player.pause()
        startJob=scope.launch {
            var target:TakeRecorder?=null
            try {
                awaitRecordingCountdown(recordingDelay,onTick={countdownRemaining=it})
                currentCoroutineContext().ensureActive()
                check(owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)){"Return to the studio to start a recording."}
                check(frame!=null&&!switchingCamera){"Wait for your camera, then try again."}
                val ready=TakeRecorder(context,DraftStore(context).newCapture())
                target=ready;ready.start()
                currentCoroutineContext().ensureActive()
                check(owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)){"Return to the studio to start a recording."}
                recorder=ready;timeline.clear();elapsed=0;pausedTotal=0;pausedAt=0
                startedAt=SystemClock.elapsedRealtime();recording=true
                if(!source.isImage) {
                    val start=recordingSourcePosition(player.currentPosition,player.duration,player.playbackState==Player.STATE_ENDED)
                    if(start!=player.currentPosition)player.seekTo(start)
                    player.play()
                    if(player.isPlaying)timeline.begin(source.uri.toString(),0,player.currentPosition)
                }
            }catch(e:CancellationException){target?.abort();throw e}
            catch(e:Exception){target?.abort();error="Recording could not start. ${e.localizedMessage ?: "Check camera and microphone permissions."}"}
            finally{countdownRemaining=null;starting=false;startJob=null}
        }
    }
    val latestFinish by rememberUpdatedState(::finishTake)
    val latestCancel by rememberUpdatedState(::cancelCountdown)
    val latestStarting by rememberUpdatedState(starting)
    BackHandler(recording || saving || starting){if(starting)cancelCountdown()else if(recording)finishTake()}
    LaunchedEffect(camera){camera?.frames?.collectLatest{frame=it} ?: run{frame=null}}
    LaunchedEffect(placement.style,camera,fullScreenCamera,stageLayout.template){camera?.removeBackground=placement.style==PipStyle.Cutout&&!fullScreenCamera&&stageLayout.template==StageTemplate.Pip}
    LaunchedEffect(source) {
        error=null;picture=null;videoFrame=null;preparingSource=!source.isImage
        player.stop();position=0;duration=0
        if(source.isImage) {
            try{picture=loadPicture(context,source.uri)}catch(e:Exception){error="This photo could not be opened."}
        } else {
            player.setMediaItem(MediaItem.fromUri(source.uri));player.prepare()
            player.seekTo(sourcePositions[source.uri.toString()]?:0)
        }
    }
    DisposableEffect(player) {
        val listener=object:Player.Listener {
            override fun onIsPlayingChanged(isPlaying:Boolean) {
                playing=isPlaying
                if(recording) {
                    val clock=latestClock()
                    if(isPlaying&&!latestSource.isImage)timeline.begin(latestSource.uri.toString(),clock,player.currentPosition)
                    else timeline.close(player.currentPosition,clock)
                }
            }
            override fun onPlaybackStateChanged(state:Int){
                duration=player.duration.coerceAtLeast(0)
                if(state==Player.STATE_READY||state==Player.STATE_ENDED)preparingSource=false
                // Keep the final decoded frame visible. Camera and narration continue until Finish.
                if(state==Player.STATE_ENDED&&recording)timeline.close(player.currentPosition,latestClock())
            }
            override fun onVideoSizeChanged(videoSize:VideoSize){
                if(videoSize.width<=0||videoSize.height<=0)return
                sourceVideoAspect=videoSize.width.toFloat()/videoSize.height.coerceAtLeast(1)
                texture?.videoAspect=sourceVideoAspect
            }
            override fun onPlayerError(exception:androidx.media3.common.PlaybackException){preparingSource=false;error="This video could not play. Try importing a local copy."}
        }
        player.addListener(listener)
        onDispose{player.removeListener(listener);player.release()}
    }
    DisposableEffect(owner) {
        val observer=LifecycleEventObserver{_,event -> if(event==Lifecycle.Event.ON_STOP){
            if(latestStarting)latestCancel()
            if(latestRecording&&!latestPicking)latestFinish()
        }}
        owner.lifecycle.addObserver(observer)
        onDispose{owner.lifecycle.removeObserver(observer)}
    }
    val latestCamera by rememberUpdatedState(camera)
    val latestRecorder by rememberUpdatedState(recorder)
    DisposableEffect(Unit){onDispose{studioOpen=false;latestCamera?.close();if(latestRecorder?.isRecording==true)latestRecorder?.abort()}}
    LaunchedEffect(player) {while(true){position=player.currentPosition.coerceAtLeast(0);duration=player.duration.coerceAtLeast(0);delay(200)}}
    LaunchedEffect(source,stageLayout.template) {while(true){
        // The sharp native video remains at its original cadence. A bounded
        // snapshot only supplies the soft Split background and capture encoder.
        if(!source.isImage&&(latestRecording||stageLayout.template==StageTemplate.Split)) {
            videoFrame=texture?.takeIf{it.isAvailable}?.snapshot();videoFrameRevision++
        }
        delay(if(latestRecording)42 else 250)
    }}
    LaunchedEffect(recording) {
        if(recording&&!source.isImage)videoFrame=texture?.takeIf{it.isAvailable}?.snapshot()
        while(recording) {
            if(pausedAt>0){delay(60);continue}
            elapsed=takeClock()
            val background=if(source.isImage)picture else videoFrame
            val composed=FrameComposer.compose(background,frame,placement,fullScreenCamera=fullScreenCamera,layout=stageLayout,
                sourceAspect=if(source.isImage)null else texture?.videoAspect)
            recorder?.submit(composed) ?: composed.recycle()
            delay(42)
        }
    }

    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(horizontal=18.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
        Row(Modifier.fillMaxWidth().height(48.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.SpaceBetween) {
            IconButton(onClick=onClose,enabled=!recording&&!saving&&!starting,modifier=Modifier.size(44.dp)){Icon(Icons.Rounded.Close,"Close studio")}
            Column(horizontalAlignment=Alignment.CenterHorizontally) {
                Text("Record a reaction",fontSize=16.sp,fontWeight=FontWeight.Bold)
                Text(if(recording)"●  ${formatTime(elapsed)}" else if(saving)"Preparing your edit…" else if(starting)"Get ready…" else "Ready to record",fontSize=11.sp,color=if(recording)Color(0xFFC94738) else Muted)
            }
            IconButton(onClick={placement=PipPlacement(style=placement.style,framingScale=placement.framingScale)},modifier=Modifier.size(44.dp)){Icon(Icons.Rounded.RestartAlt,"Reset camera position")}
        }
        Box(Modifier.weight(1f).fillMaxWidth(),contentAlignment=Alignment.Center) {
        BoxWithConstraints(Modifier.fillMaxHeight().aspectRatio(9f/16f,matchHeightConstraintsFirst=true).clip(RoundedCornerShape(20.dp)).background(Color(0xFF16181B))) {
            val previewWidth=maxWidth
            val previewHeight=maxHeight
            val density=androidx.compose.ui.platform.LocalDensity.current
            val widthPx=with(density){previewWidth.toPx()}
            val heightPx=with(density){previewHeight.toPx()}
            val sourceFrame=when(stageLayout.template) {
                StageTemplate.Pip->CameraFramingRect(0f,0f,widthPx,heightPx)
                StageTemplate.Split->StageGeometry.sourceTop(widthPx,heightPx,stageLayout)
                StageTemplate.CameraMain->StageGeometry.sourceOverlay(widthPx,heightPx,sourceVideoAspect,stageLayout.sourceOverlay)
            }
            if(!source.isImage&&stageLayout.template==StageTemplate.Split&&!fullScreenCamera)Canvas(Modifier.fillMaxSize()) {
                val top=StageGeometry.sourceTop(size.width,size.height,stageLayout)
                videoFrame?.let{bitmap->drawIntoCanvas{output->FrameComposer.drawSplitBackdrop(output.nativeCanvas,bitmap,
                    RectF(top.left,top.top,top.right,top.bottom),sourceVideoAspect,videoFrameRevision)}}
            }
            if(!source.isImage)AndroidView(factory={ctx->SourceTextureView(ctx).also{
                texture=it
                player.setVideoTextureView(it)
                val size=player.videoSize
                if(size.height>0)it.videoAspect=size.width.toFloat()/size.height
            }},modifier=Modifier.offset{IntOffset(sourceFrame.left.roundToInt(),sourceFrame.top.roundToInt())}
                .size(with(density){sourceFrame.width.toDp()},with(density){sourceFrame.height.toDp()})
                .clipToBounds()
                .zIndex(if(stageLayout.template==StageTemplate.CameraMain)1f else 0f)
                .graphicsLayer{alpha=if(fullScreenCamera&&frame!=null)0f else 1f})
            Canvas(Modifier.fillMaxSize()) {
                drawIntoCanvas {output ->
                    val canvas=output.nativeCanvas
                    if(source.isImage)FrameComposer.drawStage(canvas,picture,frame,placement,size.width,size.height,stageLayout,fullScreenCamera)
                    else frame?.let{cameraFrame->
                        if(fullScreenCamera)FrameComposer.drawCameraInBounds(canvas,cameraFrame,PipStyle.Square,1f,RectF(0f,0f,size.width,size.height))
                        else when(stageLayout.template) {
                            StageTemplate.Pip->FrameComposer.drawPip(canvas,cameraFrame,placement,size.width,size.height)
                            StageTemplate.Split->{val r=StageGeometry.cameraBottom(size.width,size.height,stageLayout)
                                FrameComposer.drawCameraInBounds(canvas,cameraFrame,PipStyle.Square,1f,RectF(r.left,r.top,r.right,r.bottom))}
                            StageTemplate.CameraMain->FrameComposer.drawCameraInBounds(canvas,cameraFrame,PipStyle.Square,1f,RectF(0f,0f,size.width,size.height))
                        }
                    }
                }
            }
            // Keep controls above the native source overlay in the Stage layout.
            Box(Modifier.matchParentSize().zIndex(2f)
                .pointerInput(widthPx,heightPx,stageLayout.template,camera!=null,fullScreenCamera) {
                    awaitEachGesture {
                        val down=awaitFirstDown(requireUnconsumed=true)
                        val cameraGesture=camera!=null&&!fullScreenCamera&&stageLayout.template==StageTemplate.Pip&&
                            PipGeometry.contains(down.position.x,down.position.y,widthPx,heightPx,placement)
                        val sourceAspect=if(source.isImage)picture?.let{it.width.toFloat()/it.height}?:9f/16f else sourceVideoAspect
                        val sourceRect=StageGeometry.sourceOverlay(widthPx,heightPx,sourceAspect,stageLayout.sourceOverlay)
                        val sourceGesture=!fullScreenCamera&&stageLayout.template==StageTemplate.CameraMain&&
                            down.position.x in sourceRect.left..sourceRect.right&&down.position.y in sourceRect.top..sourceRect.bottom
                        if(cameraGesture||sourceGesture) {
                            val tracker=OverlayGestureState()
                            tracker.update(listOf(OverlayTouch(down.id.value,down.position.x,down.position.y)),widthPx,heightPx)
                            down.consume()
                            do {
                                val event=awaitPointerEvent(PointerEventPass.Initial)
                                val points=event.changes.filter{it.pressed}.map{OverlayTouch(it.id.value,it.position.x,it.position.y)}
                                val delta=tracker.update(points,widthPx,heightPx)
                                if(cameraGesture)placement=PipGeometry.keepVisible(placement.transformed(delta.dx,delta.dy,delta.zoom,delta.rotation),widthPx,heightPx)
                                else stageLayout=stageLayout.copy(sourceOverlay=stageLayout.sourceOverlay.transformed(delta.dx,delta.dy,delta.zoom))
                                event.changes.forEach{it.consume()}
                            }while(event.changes.any{it.pressed})
                        }
                    }
                }) {
            if(camera!=null&&stageLayout.template==StageTemplate.Pip&&!fullScreenCamera) {
                val pipWidth=if(fullScreenCamera)previewWidth else previewWidth * .34f * placement.scale
                val pipHeight=if(fullScreenCamera)previewHeight else PipGeometry.heightForWidth(pipWidth.value,placement.style).dp
                val shape=if(fullScreenCamera)RectangleShape else when(placement.style){PipStyle.Circle->CircleShape;PipStyle.Rounded->RoundedCornerShape(pipWidth*.16f);else->RectangleShape}
                val cameraModifier=if(fullScreenCamera)Modifier.fillMaxSize()else Modifier.offset{IntOffset((widthPx*placement.x-with(density){pipWidth.toPx()}/2).roundToInt(),
                    (heightPx*placement.y-with(density){pipHeight.toPx()}/2).roundToInt())}
                    .size(pipWidth,pipHeight).graphicsLayer{rotationZ=placement.rotation}
                    .semantics{contentDescription="Small camera. One finger moves it. Two fingers resize and rotate it."}
                Box(cameraModifier.clip(shape)) {
                    if(frame==null)Box(Modifier.fillMaxSize().background(Color(0xFF34383B)),contentAlignment=Alignment.Center) {
                        if(switchingCamera)CircularProgressIndicator(Modifier.size(24.dp),color=Lime,strokeWidth=2.dp)
                        else Icon(Icons.Rounded.VideocamOff,"Camera unavailable",Modifier.size(26.dp),tint=Color.White)
                    }
                }
            } else if(camera==null) {
                Surface(modifier=Modifier.align(Alignment.BottomEnd).padding(14.dp).height(44.dp),enabled=!saving&&!starting,shape=RoundedCornerShape(12.dp),color=Color.White.copy(alpha=.92f),onClick={
                    if(screenActive)error="Finish your screen recording before starting another camera recording."
                    else if(ContextCompat.checkSelfPermission(context,Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED)startCamera()
                    else defaultCameraPermission.launch(Manifest.permission.CAMERA)
                }) {
                    Row(Modifier.padding(horizontal=12.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                        Icon(Icons.Rounded.Videocam,null,Modifier.size(20.dp));Text("Add yourself",fontSize=12.sp,fontWeight=FontWeight.Bold)
                    }
                }
            }
            if(!fullScreenCamera&&stageLayout.template==StageTemplate.Split) {
                Box(Modifier.fillMaxWidth().height(28.dp).offset{IntOffset(0,(heightPx*stageLayout.splitFraction-with(density){14.dp.toPx()}).roundToInt())}
                    .pointerInput(heightPx){detectVerticalDragGestures{change,dy->change.consume();stageLayout=stageLayout.splitAt(stageLayout.splitFraction+dy/heightPx)}}
                    .semantics{contentDescription="Split divider. Drag to resize source and camera."},contentAlignment=Alignment.Center) {
                    Box(Modifier.width(44.dp).height(4.dp).clip(RoundedCornerShape(2.dp)).background(Color.White.copy(alpha=.85f)))
                }
            }
            if(!fullScreenCamera&&stageLayout.template==StageTemplate.CameraMain) {
                val sourceAspect=if(source.isImage)picture?.let{it.width.toFloat()/it.height}?:9f/16f else sourceVideoAspect
                val overlay=StageGeometry.sourceOverlay(widthPx,heightPx,sourceAspect,stageLayout.sourceOverlay)
                Box(Modifier.offset{IntOffset(overlay.left.roundToInt(),overlay.top.roundToInt())}
                    .size(with(density){overlay.width.toDp()},with(density){overlay.height.toDp()})

                    .semantics{contentDescription="Original video overlay. Drag or pinch to position."})
            }
            Surface(modifier=Modifier.align(Alignment.TopStart).padding(12.dp),shape=RoundedCornerShape(8.dp),color=Color.Black.copy(alpha=.42f),contentColor=Color.White) {
                Text(if(recording)"REC  ${formatTime(elapsed)}" else if(source.isImage)"PHOTO" else "VIDEO",Modifier.padding(horizontal=12.dp,vertical=7.dp),fontSize=10.sp,fontWeight=FontWeight.SemiBold)
            }
            if(camera!=null)Surface(onClick={camera?.flip()},enabled=!switchingCamera&&!starting&&!saving,
                modifier=Modifier.align(Alignment.TopEnd).padding(12.dp).size(44.dp),shape=RoundedCornerShape(12.dp),color=Color.White.copy(alpha=.94f)) {
                Box(Modifier.fillMaxSize(),contentAlignment=Alignment.Center) {
                    if(switchingCamera)CircularProgressIndicator(Modifier.size(19.dp),strokeWidth=2.dp,color=Ink)
                    else Icon(Icons.Rounded.Cameraswitch,"Flip to ${if(lens==CameraLens.Front)"back"else "front"} camera",Modifier.size(23.dp),tint=Ink)
                }
            }
            if(camera!=null)Surface(onClick={fullScreenCamera=!fullScreenCamera},enabled=!starting&&!saving,
                modifier=Modifier.align(Alignment.TopEnd).padding(top=64.dp,end=12.dp).size(44.dp),shape=RoundedCornerShape(12.dp),color=Color.White.copy(alpha=.94f)) {
                Box(Modifier.fillMaxSize(),contentAlignment=Alignment.Center){Icon(if(fullScreenCamera)Icons.Rounded.FullscreenExit else Icons.Rounded.Fullscreen,
                    if(fullScreenCamera)"Return to small camera"else "Show camera full screen",Modifier.size(23.dp),tint=Ink)}
            }
            if(preparingSource&&!source.isImage)Box(Modifier.fillMaxSize(),contentAlignment=Alignment.Center) {
                Column(horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(9.dp),
                    modifier=Modifier.semantics{liveRegion=LiveRegionMode.Polite}) {
                    CircularProgressIndicator(Modifier.size(22.dp),strokeWidth=2.dp,color=Lime)
                    Text(MediaLoadingPhase.Loading.message,color=Color.White,fontSize=12.sp)
                }
            }
            countdownRemaining?.let{remaining ->
                Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha=.34f)),contentAlignment=Alignment.Center) {
                    Text(remaining.toString(),fontSize=88.sp,fontWeight=FontWeight.Bold,color=Color.White,
                        modifier=Modifier.semantics{contentDescription="Recording starts in $remaining";liveRegion=LiveRegionMode.Polite})
                    OutlinedButton(onClick={cancelCountdown()},modifier=Modifier.align(Alignment.BottomCenter).padding(bottom=18.dp).height(44.dp),
                        shape=RoundedCornerShape(12.dp),border=BorderStroke(1.dp,Color.White.copy(alpha=.6f)),
                        colors=ButtonDefaults.outlinedButtonColors(contentColor=Color.White)) {Text("Cancel countdown")}
                }
            }
            }
        }
        }
        if(sources.size>1)LazyRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            items(sources,key={it.uri.toString()}) { item ->
                FilterChip(selected=source.uri==item.uri,onClick={selectSource(item)},enabled=!starting&&!saving,label={Text(item.title,maxLines=1,overflow=TextOverflow.Ellipsis,modifier=Modifier.widthIn(max=110.dp),fontSize=11.sp)},
                    leadingIcon={Icon(if(item.isImage)Icons.Rounded.Image else Icons.Rounded.Movie,null,Modifier.size(15.dp))})
            }
        }
        if(!source.isImage) {
            Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                IconButton(onClick={if(player.isPlaying)player.pause()else {if(player.playbackState==Player.STATE_ENDED)player.seekTo(0);player.play()}},enabled=!starting&&!saving,modifier=Modifier.size(44.dp)){Icon(if(playing)Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                    if(playing)"Pause source video; keep recording reaction" else "Play source video")}
                Slider(value=position.toFloat().coerceIn(0f,duration.coerceAtLeast(1).toFloat()),onValueChange={newPosition->
                    if(recording)timeline.close(player.currentPosition,takeClock())
                    player.seekTo(newPosition.toLong())
                    if(recording&&player.isPlaying)timeline.begin(source.uri.toString(),takeClock(),newPosition.toLong())
                    position=newPosition.toLong()
                },valueRange=0f..duration.coerceAtLeast(1).toFloat(),modifier=Modifier.weight(1f),enabled=duration>0&&!starting&&!saving,
                    colors=SliderDefaults.colors(thumbColor=Ink,activeTrackColor=Ink,inactiveTrackColor=Rule))
                Text(formatTime(position),fontSize=11.sp,color=Muted,modifier=Modifier.width(39.dp))
            }
        }
        if(recording&&!source.isImage&&player.playbackState==Player.STATE_ENDED)
            Text("Video finished. Keep talking, then finish your video.",fontSize=11.sp,color=Muted)
        StylePicker(if(camera!=null&&stageLayout.template==StageTemplate.Pip&&!fullScreenCamera)placement.style else null,
            enabled=camera!=null&&!starting&&!saving&&!fullScreenCamera&&stageLayout.template==StageTemplate.Pip){placement=placement.copy(style=it)}
        if(camera!=null&&stageLayout.template==StageTemplate.Pip&&!fullScreenCamera)Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            Text("Wider",fontSize=11.sp,color=Muted)
            Slider(value=PipGeometry.effectiveFraming(placement.style,placement.framingScale),onValueChange={placement=placement.copy(framingScale=it)},
                valueRange=PipGeometry.minimumFraming(placement.style)..PipGeometry.MAX_FRAMING,enabled=!saving&&!starting,
                modifier=Modifier.weight(1f).semantics{contentDescription="Camera framing"},
                colors=SliderDefaults.colors(thumbColor=Ink,activeTrackColor=Ink,inactiveTrackColor=Rule))
            Text("Closer",fontSize=11.sp,color=Muted)
            TextButton(onClick={placement=placement.copy(framingScale=1f)},enabled=!saving&&!starting,
                modifier=Modifier.height(40.dp).semantics{contentDescription="Reset camera framing"},shape=RoundedCornerShape(12.dp),
                contentPadding=PaddingValues(horizontal=10.dp,vertical=4.dp)) {Text("Reset",fontSize=12.sp,fontWeight=FontWeight.SemiBold)}
        }
        Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(4.dp)) {
            Box {
                OutlinedButton(onClick={layoutMenu=true},enabled=!starting&&!saving,modifier=Modifier.widthIn(min=68.dp).height(40.dp),shape=RoundedCornerShape(10.dp),contentPadding=PaddingValues(5.dp)) {
                    Text(stageLayout.template.shortLabel,fontSize=11.sp);Icon(Icons.Rounded.ExpandMore,"Change recording layout",Modifier.size(15.dp))
                }
                DropdownMenu(expanded=layoutMenu,onDismissRequest={layoutMenu=false}) {
                    StageTemplate.entries.forEach{template ->DropdownMenuItem(text={Text(template.label)},onClick={
                        if(stageLayout.template!=template){stageLayout=stageLayout.copy(template=template);placement=placement.forLayoutChange()}
                        layoutMenu=false},
                        trailingIcon={if(stageLayout.template==template)Icon(Icons.Rounded.Check,null,Modifier.size(18.dp))})}
                }
            }
            Text("Timer",fontSize=11.sp,color=Muted,modifier=Modifier.weight(1f))
            RecordingDelay.entries.forEach{choice ->
                Surface(onClick={recordingDelay=choice;store.recordingDelay=choice},enabled=!recording&&!starting&&!saving,
                    modifier=Modifier.width(40.dp).height(40.dp).semantics{contentDescription="Recording timer ${if(choice==RecordingDelay.Off)"off"else "${choice.seconds} seconds"}"},
                    shape=RoundedCornerShape(10.dp),color=if(recordingDelay==choice)Ink else Color.White,
                    contentColor=if(recordingDelay==choice)Color.White else Muted,border=BorderStroke(1.dp,if(recordingDelay==choice)Ink else Rule)) {
                    Box(Modifier.fillMaxSize(),contentAlignment=Alignment.Center){Text(choice.label,fontSize=12.sp,fontWeight=FontWeight.SemiBold)}
                }
            }
        }
        if(recording)Text(voiceProtection.description,fontSize=10.sp,lineHeight=14.sp,color=if(voiceProtection.silenced)MaterialTheme.colorScheme.error else Muted)
        if(!source.isImage)Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(7.dp)) {
            Icon(Icons.Rounded.Headphones,null,Modifier.size(15.dp),tint=Muted)
            Text("Headphones keep video sound out of your microphone.",fontSize=11.sp,color=Muted,lineHeight=15.sp)
        }
        error?.let{Text(it,color=MaterialTheme.colorScheme.error,fontSize=12.sp,lineHeight=17.sp,maxLines=3)}
        Row(Modifier.fillMaxWidth().padding(bottom=8.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.SpaceBetween) {
            OutlinedIconButton(onClick={importPhoto()},enabled=!saving&&!starting,
                shape=RoundedCornerShape(12.dp),modifier=Modifier.size(44.dp),border=BorderStroke(1.dp,Rule)) {
                Icon(Icons.Rounded.AddPhotoAlternate,"Add a photo to this recording",Modifier.size(21.dp))
            }
            Column(horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(5.dp)) {
                val label=if(recording)"Finish recording"else if(countdownRemaining!=null)"Cancel countdown"else "Record"
                Button(onClick={if(starting)cancelCountdown()else if(recording)finishTake()else startTake()},
                    enabled=!saving&&(countdownRemaining!=null||(!starting&&(recording||(!switchingCamera&&frame!=null)))),
                    modifier=Modifier.size(64.dp).semantics{contentDescription=label},shape=CircleShape,contentPadding=PaddingValues(0.dp),
                    colors=ButtonDefaults.buttonColors(containerColor=if(recording)Color(0xFFC94738) else Ink,contentColor=if(recording)Color.White else Lime)) {
                    if(saving||(starting&&countdownRemaining==null))CircularProgressIndicator(Modifier.size(24.dp),strokeWidth=2.dp,color=Lime)
                    else Icon(if(recording)Icons.Rounded.Stop else if(countdownRemaining!=null)Icons.Rounded.Close else Icons.Rounded.FiberManualRecord,null,Modifier.size(28.dp))
                }
                Text(if(saving)"Saving…"else label,fontSize=11.sp,fontWeight=FontWeight.SemiBold,color=Muted)
            }
            if(camera!=null)OutlinedIconButton(onClick={if(!recording){camera?.close();camera=null;frame=null;fullScreenCamera=false}},enabled=!recording&&!saving&&!starting,
                shape=RoundedCornerShape(12.dp),modifier=Modifier.size(44.dp),border=BorderStroke(1.dp,Rule)) {
                Icon(Icons.Rounded.VideocamOff,"Turn off camera",Modifier.size(21.dp))
            } else Spacer(Modifier.size(44.dp))
        }
    }
}

@OptIn(UnstableApi::class)
private class SourceTextureView(context:android.content.Context):TextureView(context) {
    private var snapshotBuffer:Bitmap?=null
    init {isOpaque=false}
    var videoAspect=9f/16f
        set(value){if(value.isFinite()&&value>0){field=value;updateTransform()}}
    override fun onSizeChanged(w:Int,h:Int,oldw:Int,oldh:Int){super.onSizeChanged(w,h,oldw,oldh);updateTransform()}
    private fun updateTransform(){
        if(width==0||height==0)return
        val fit=StageGeometry.sourceFit(videoAspect,1f,CameraFramingRect(0f,0f,width.toFloat(),height.toFloat()))
        setTransform(Matrix().apply{setScale(fit.width/width,fit.height/height,width/2f,height/2f)})
    }
    fun snapshot():Bitmap? {
        if(!isAvailable)return null
        // Capture readback retains this source pane's aspect. The native on-screen
        // player does not use this bounded bitmap; reaction output keeps its existing size.
        val scale=minOf(1f,720f/width.coerceAtLeast(1),1280f/height.coerceAtLeast(1))
        val w=(width*scale).roundToInt().coerceAtLeast(1);val h=(height*scale).roundToInt().coerceAtLeast(1)
        val buffer=snapshotBuffer?.takeUnless{it.isRecycled||it.width!=w||it.height!=h}
            ?:Bitmap.createBitmap(w,h,Bitmap.Config.ARGB_8888).also{snapshotBuffer?.recycle();snapshotBuffer=it}
        return getBitmap(buffer)
    }
    override fun onDetachedFromWindow(){super.onDetachedFromWindow();snapshotBuffer?.recycle();snapshotBuffer=null}
}

fun formatTime(ms:Long):String {val seconds=ms.coerceAtLeast(0)/1000;return "%d:%02d".format(seconds/60,seconds%60)}
