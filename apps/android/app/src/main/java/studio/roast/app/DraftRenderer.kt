package studio.roast.app

import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.text.SpannableString
import android.text.Spanned
import android.text.style.AbsoluteSizeSpan
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.effect.TextOverlay
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

fun editedCaptionCues(captions:List<CaptionCue>,ranges:List<EditRange>):List<CaptionCue> {
    var output=0L
    return ranges.flatMap{range ->
        val result=captions.mapNotNull{cue ->
            val a=maxOf(cue.startMs,range.startMs);val b=minOf(cue.endMs,range.endMs)
            if(b>a)CaptionCue(output+a-range.startMs,output+b-range.startMs,cue.text)else null
        }
        output+=range.durationMs;result
    }
}

@OptIn(UnstableApi::class)
suspend fun renderDraft(context:Context,draft:ReactionDraft,destination:File) {
    check(draft.outputDurationMs>=250){"Keep at least a quarter of a second in your video."}
    val mixed=File(draft.directory,"mix-${draft.revision}.wav")
    val pending=File(destination.parentFile,".${destination.name}.${java.util.UUID.randomUUID()}.render.mp4")
    try {
      mixDraftAudio(draft,mixed)
      withContext(Dispatchers.Main) {
        suspendCancellableCoroutine<Unit>{continuation ->
            pending.delete()
            val video=EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_VIDEO))
            draft.ranges.forEach{range ->
                val item=MediaItem.Builder().setUri(Uri.fromFile(draft.capture)).setClippingConfiguration(
                    MediaItem.ClippingConfiguration.Builder().setStartPositionMs(range.startMs).setEndPositionMs(range.endMs).build()).build()
                video.addItem(EditedMediaItem.Builder(item).setRemoveAudio(true).build())
            }
            val audio=EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO))
                .addItem(EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(mixed))).setRemoveVideo(true).build()).build()
            val composition=Composition.Builder(video.build(),audio)
            if(draft.edits.showCaptions&&draft.edits.captions.isNotEmpty()) {
                val cues=editedCaptionCues(draft.edits.captions,draft.ranges)
                val overlay=object:TextOverlay() {
                    override fun getText(presentationTimeUs:Long):SpannableString {
                        val ms=presentationTimeUs/1_000
                        val text=cues.firstOrNull{ms>=it.startMs&&ms<it.endMs}?.text.orEmpty()
                        val wrapped=text.split(' ').fold(""){acc,word ->
                            if(acc.substringAfterLast('\n').length+word.length>29)"$acc\n$word"else if(acc.isEmpty())word else "$acc $word"
                        }
                        // Media3 allocates its overlay bitmap from measured text width; keep
                        // a non-zero surface during silent gaps and make that surface transparent.
                        return SpannableString(wrapped.ifBlank{" "}).apply {
                            setSpan(ForegroundColorSpan(Color.WHITE),0,length,Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                            setSpan(BackgroundColorSpan(0xB3202326.toInt()),0,length,Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                            setSpan(AbsoluteSizeSpan(34),0,length,Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                            setSpan(StyleSpan(android.graphics.Typeface.BOLD),0,length,Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                        }
                    }
                    override fun getOverlaySettings(presentationTimeUs:Long)=StaticOverlaySettings.Builder()
                        .setAlphaScale(if(cues.any{presentationTimeUs/1_000>=it.startMs&&presentationTimeUs/1_000<it.endMs&&it.text.isNotBlank()})1f else 0f)
                        .setBackgroundFrameAnchor(0f,-.76f).setOverlayFrameAnchor(0f,-1f).build()
                }
                composition.setEffects(Effects(emptyList(),listOf(OverlayEffect(listOf(overlay)))))
            }
            val transformer=Transformer.Builder(context).setAudioMimeType(MimeTypes.AUDIO_AAC).setVideoMimeType(MimeTypes.VIDEO_H264)
                .setUsePlatformDiagnostics(false).addListener(object:Transformer.Listener {
                    override fun onCompleted(composition:Composition,exportResult:ExportResult){
                        mixed.delete()
                        if(continuation.isActive)continuation.resume(Unit)
                    }
                    override fun onError(composition:Composition,exportResult:ExportResult,exportException:ExportException){
                        pending.delete();mixed.delete()
                        if(continuation.isActive)continuation.resumeWithException(exportException)
                    }
                }).build()
            continuation.invokeOnCancellation {
                val stop={transformer.cancel();pending.delete();mixed.delete();Unit}
                if(android.os.Looper.myLooper()==context.mainLooper)stop()else android.os.Handler(context.mainLooper).post{stop()}
            }
            try{transformer.start(composition.build(),pending.absolutePath)}catch(e:Exception){pending.delete();mixed.delete();if(continuation.isActive)continuation.resumeWithException(e)}
        }
      }
      withContext(Dispatchers.IO){
          check(pending.length()>0){"The edited video contains no data. Your draft is safe."}
          check(pending.renameTo(destination)){"The edited video could not be saved. Your original recording is safe."}
      }
    }finally {
        mixed.delete()
        pending.delete()
    }
}
