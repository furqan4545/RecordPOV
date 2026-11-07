package studio.roast.app

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.abs
import kotlin.math.roundToInt

fun formatTimelineTime(ms:Long):String {
    val value=ms.coerceAtLeast(0)
    return "%d:%02d.%03d".format(value/60_000,value/1_000%60,value%1_000)
}

@Composable fun ThumbnailTimeline(capture:File,durationMs:Long,bounds:TrimBounds,playheadMs:Long,enabled:Boolean,
    onBegin:()->Unit,onTrim:(TrimBounds,TrimEdge)->Unit,onScrub:(Long)->Unit,onCommit:(TrimBounds)->Unit,
    onScrubEnd:()->Unit,onCancel:()->Unit) {
    var thumbnails by remember(capture){mutableStateOf<List<Bitmap>>(emptyList())}
    val latestThumbnails by rememberUpdatedState(thumbnails)
    val currentBounds by rememberUpdatedState(bounds)
    val begin by rememberUpdatedState(onBegin)
    val trim by rememberUpdatedState(onTrim)
    val scrub by rememberUpdatedState(onScrub)
    val commit by rememberUpdatedState(onCommit)
    val finishScrub by rememberUpdatedState(onScrubEnd)
    val cancel by rememberUpdatedState(onCancel)
    LaunchedEffect(capture) {
        val loaded=mutableListOf<Bitmap>()
        try {
            withContext(Dispatchers.IO) {
                MediaMetadataRetriever().use {retriever ->
                    retriever.setDataSource(capture.absolutePath)
                    repeat(10){index ->
                        currentCoroutineContext().ensureActive()
                        val time=((index+.5)/10*durationMs*1_000).toLong()
                        retriever.getScaledFrameAtTime(time,MediaMetadataRetriever.OPTION_CLOSEST_SYNC,64,112)?.let(loaded::add)
                    }
                }
            }
            thumbnails=loaded
        }catch(e:CancellationException){loaded.forEach{it.recycle()};throw e}
        catch(_:Exception){loaded.forEach{it.recycle()}}
    }
    DisposableEffect(capture){onDispose{latestThumbnails.forEach{it.recycle()}}}
    val density=LocalDensity.current
    val inset=with(density){18.dp.toPx()}
    val radius=with(density){22.dp.toPx()}
    Column(verticalArrangement=Arrangement.spacedBy(2.dp)) {
        BoxWithConstraints(Modifier.fillMaxWidth().height(100.dp)) {
            val width=with(density){maxWidth.toPx()}
            val trackWidth=(width-2*inset).coerceAtLeast(1f)
            val startX=timelineXAt(bounds.startMs,inset,trackWidth,durationMs)
            val endX=timelineXAt(bounds.endMs,inset,trackWidth,durationMs)
            Box(Modifier.fillMaxSize().pointerInput(durationMs,enabled,inset,radius) {
                if(!enabled)return@pointerInput
                awaitEachGesture {
                    val down=awaitFirstDown(requireUnconsumed=false)
                    var local=currentBounds
                    val a=timelineXAt(local.startMs,inset,trackWidth,durationMs)
                    val b=timelineXAt(local.endMs,inset,trackWidth,durationMs)
                    val edge=when {
                        abs(down.position.x-a)<=radius&&abs(down.position.x-a)<=abs(down.position.x-b)->TrimEdge.Start
                        abs(down.position.x-b)<=radius->TrimEdge.End
                        else->null
                    }
                    val offset=if(edge==TrimEdge.Start)down.position.x-a else if(edge==TrimEdge.End)down.position.x-b else 0f
                    var released=false
                    begin();down.consume()
                    fun move(x:Float) {
                        val time=timelinePositionAt(x-offset,inset,trackWidth,durationMs)
                        if(edge!=null){local=moveTrimEdge(local,edge,time,durationMs);trim(local,edge)}else scrub(time)
                    }
                    move(down.position.x)
                    try {
                        while(true) {
                            val event=awaitPointerEvent()
                            val change=event.changes.firstOrNull{it.id==down.id}?:break
                            move(change.position.x);change.consume()
                            if(!change.pressed){released=true;break}
                        }
                    }finally {
                        if(released){if(edge!=null)commit(local)else finishScrub()}else cancel()
                    }
                }
            }.semantics {
                contentDescription="Video timeline. Drag to scrub the original capture."
                progressBarRangeInfo=ProgressBarRangeInfo(playheadMs.toFloat(),0f..durationMs.toFloat())
                if(enabled)setProgress{value->begin();scrub(value.toLong().coerceIn(0,durationMs));finishScrub();true}
            }) {
                Canvas(Modifier.fillMaxSize()) {
                    val top=16.dp.toPx();val height=58.dp.toPx();val bottom=top+height
                    drawRoundRect(Ink,Offset(inset,top),Size(trackWidth,height),CornerRadius(5.dp.toPx()))
                    if(thumbnails.isNotEmpty())clipRect(inset,top,inset+trackWidth,bottom) {
                        val cell=trackWidth/thumbnails.size
                        thumbnails.forEachIndexed{index,bitmap ->
                            val targetAspect=cell/height;val sourceAspect=bitmap.width.toFloat()/bitmap.height
                            val cropWidth=if(sourceAspect>targetAspect)(bitmap.height*targetAspect).toInt().coerceAtLeast(1)else bitmap.width
                            val cropHeight=if(sourceAspect<targetAspect)(bitmap.width/targetAspect).toInt().coerceAtLeast(1)else bitmap.height
                            drawImage(bitmap.asImageBitmap(),IntOffset((bitmap.width-cropWidth)/2,(bitmap.height-cropHeight)/2),IntSize(cropWidth,cropHeight),
                                IntOffset((inset+index*cell).toInt(),top.toInt()),IntSize(cell.roundToInt()+1,height.roundToInt()),filterQuality=FilterQuality.Low)
                        }
                    }
                    drawRect(Color.Black.copy(alpha=.65f),Offset(inset,top),Size((startX-inset).coerceAtLeast(0f),height))
                    drawRect(Color.Black.copy(alpha=.65f),Offset(endX,top),Size((inset+trackWidth-endX).coerceAtLeast(0f),height))
                    drawLine(Lime,Offset(startX,top),Offset(endX,top),3.dp.toPx())
                    drawLine(Lime,Offset(startX,bottom),Offset(endX,bottom),3.dp.toPx())
                    for(x in listOf(startX,endX)) {
                        drawRoundRect(Lime,Offset(x-7.dp.toPx(),top-3.dp.toPx()),Size(14.dp.toPx(),height+6.dp.toPx()),CornerRadius(4.dp.toPx()))
                        drawRoundRect(Ink,Offset(x-1.dp.toPx(),top+17.dp.toPx()),Size(2.dp.toPx(),24.dp.toPx()),CornerRadius(1.dp.toPx()))
                    }
                    val head=timelineXAt(playheadMs,inset,trackWidth,durationMs)
                    drawLine(Color.White,Offset(head,6.dp.toPx()),Offset(head,bottom+8.dp.toPx()),2.dp.toPx())
                    drawCircle(Color.White,4.dp.toPx(),Offset(head,6.dp.toPx()))
                }
                for(edge in TrimEdge.entries) {
                    val position=if(edge==TrimEdge.Start)bounds.startMs else bounds.endMs
                    val x=if(edge==TrimEdge.Start)startX else endX
                    Box(Modifier.offset{IntOffset((x-radius).roundToInt(),0)}.width(44.dp).fillMaxHeight().semantics {
                        contentDescription="Trim ${if(edge==TrimEdge.Start)"start"else "end"} ${formatTimelineTime(position)}"
                        val min=if(edge==TrimEdge.Start)0f else (bounds.startMs+MIN_TRIM_DURATION_MS).coerceAtMost(durationMs).toFloat()
                        val max=if(edge==TrimEdge.End)durationMs.toFloat()else (bounds.endMs-MIN_TRIM_DURATION_MS).coerceAtLeast(0).toFloat()
                        progressBarRangeInfo=ProgressBarRangeInfo(position.toFloat().coerceIn(min,max),min..max)
                        if(enabled)setProgress{value->begin();val next=moveTrimEdge(currentBounds,edge,value.toLong(),durationMs);trim(next,edge);commit(next);true}
                    })
                }
            }
        }
        Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween) {
            Text("Start  ${formatTimelineTime(bounds.startMs)}",fontSize=11.sp,color=Muted)
            Text("End  ${formatTimelineTime(bounds.endMs)}",fontSize=11.sp,color=Muted)
        }
    }
}
