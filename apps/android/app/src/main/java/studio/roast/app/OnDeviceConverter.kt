package studio.roast.app

import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Codec
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Decoders this phone offers (MediaCodecList.REGULAR_CODECS), checked for the frame size and rate in both orientations. */
internal object DeviceVideoDecoders {
    fun mime(codec:VideoCodec):String?=when(codec) {
        VideoCodec.H264->MediaFormat.MIMETYPE_VIDEO_AVC
        VideoCodec.HEVC->MediaFormat.MIMETYPE_VIDEO_HEVC
        VideoCodec.VP9->MediaFormat.MIMETYPE_VIDEO_VP9
        VideoCodec.AV1->MediaFormat.MIMETYPE_VIDEO_AV1
        VideoCodec.Unknown->null
    }
    fun canDecode(codec:VideoCodec,width:Int?,height:Int?,fps:Double?):Boolean=mime(codec)?.let{canDecode(it,width,height,fps)}?:false
    fun canDecode(mime:String,width:Int?,height:Int?,fps:Double?):Boolean=runCatching {
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any {info->
            if(info.isEncoder)return@any false
            val type=info.supportedTypes.firstOrNull{it.equals(mime,ignoreCase=true)} ?: return@any false
            runCatching {
                val video=info.getCapabilitiesForType(type).videoCapabilities ?: return@runCatching false
                when {
                    width==null||height==null->true
                    fps!=null&&fps.isFinite()&&fps>0->video.areSizeAndRateSupported(width,height,fps)||video.areSizeAndRateSupported(height,width,fps)
                    else->video.isSizeSupported(width,height)||video.isSizeSupported(height,width)
                }
            }.getOrDefault(false)
        }
    }.getOrDefault(false)
}

/** Converts a downloaded original (muxed, or separate video + audio) to H.264 + AAC with Media3 Transformer. */
@OptIn(UnstableApi::class)
internal object OnDeviceConverter {
    private fun avcLevelConstant(level:Int):Int?=when(level) {
        31->MediaCodecInfo.CodecProfileLevel.AVCLevel31
        32->MediaCodecInfo.CodecProfileLevel.AVCLevel32
        40->MediaCodecInfo.CodecProfileLevel.AVCLevel4
        42->MediaCodecInfo.CodecProfileLevel.AVCLevel42
        50->MediaCodecInfo.CodecProfileLevel.AVCLevel5
        51->MediaCodecInfo.CodecProfileLevel.AVCLevel51
        52->MediaCodecInfo.CodecProfileLevel.AVCLevel52
        else->null
    }

    suspend fun convert(context:Context,video:File,audio:File?,output:File,source:MediaProbe) {
        val bitrate=ConversionPolicy.videoBitrate(source.videoBitsPerSecond?:0L,VideoCodec.fromMime(source.videoMime),source.width,source.height)
        val settings=VideoEncoderSettings.Builder().setBitrate(bitrate).setiFrameIntervalSeconds(2f).apply {
            val level=source.fps?.let{ConversionPolicy.avcLevel(source.width,source.height,it)}?.let{avcLevelConstant(it)}
            if(level!=null)setEncodingProfileLevel(MediaCodecInfo.CodecProfileLevel.AVCProfileHigh,level)
        }.build()
        // Always re-encode the video: an H.264 source reaches this point only when it fails the direct rules
        // (bit depth, chroma, rotation), and Transformer would otherwise copy same-codec samples unchanged.
        val encoders=DefaultEncoderFactory.Builder(context).setRequestedVideoEncoderSettings(settings).build()
        val encoderFactory=object:Codec.EncoderFactory by encoders {
            override fun videoNeedsEncoding():Boolean=true
        }
        output.delete()
        try {
            withContext(Dispatchers.Main) {
                suspendCancellableCoroutine<Unit> {continuation->
                    val transformer=Transformer.Builder(context)
                        .setVideoMimeType(MimeTypes.VIDEO_H264).setAudioMimeType(MimeTypes.AUDIO_AAC)
                        // Keep portrait sources portrait: no landscape encode + 90-degree rotation hint, which the strict inspect rejects.
                        .setPortraitEncodingEnabled(true)
                        .setEncoderFactory(encoderFactory)
                        .setUsePlatformDiagnostics(false).addListener(object:Transformer.Listener {
                            override fun onCompleted(composition:Composition,exportResult:ExportResult) {
                                if(continuation.isActive)continuation.resume(Unit)
                            }
                            override fun onError(composition:Composition,exportResult:ExportResult,exportException:ExportException) {
                                output.delete()
                                if(continuation.isActive)continuation.resumeWithException(IllegalStateException(DirectImportPolicy.UNSUPPORTED_FORMAT,exportException))
                            }
                        }).build()
                    continuation.invokeOnCancellation {
                        val stop={transformer.cancel();output.delete();Unit}
                        if(Looper.myLooper()==Looper.getMainLooper())stop()else Handler(Looper.getMainLooper()).post{stop()}
                    }
                    try {
                        if(audio==null)transformer.start(EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(video))).build(),output.absolutePath)
                        else {
                            val picture=EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_VIDEO))
                                .addItem(EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(video))).setRemoveAudio(true).build()).build()
                            val sound=EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_AUDIO))
                                .addItem(EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(audio))).setRemoveVideo(true).build()).build()
                            transformer.start(Composition.Builder(picture,sound).build(),output.absolutePath)
                        }
                    }catch(e:Exception){output.delete();if(continuation.isActive)continuation.resumeWithException(e)}
                }
            }
        }catch(e:Throwable){output.delete();throw e}
    }
}
