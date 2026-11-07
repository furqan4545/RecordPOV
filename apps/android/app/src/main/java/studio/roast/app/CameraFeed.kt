package studio.roast.app

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.Handler
import android.os.Looper
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.Segmenter
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

enum class CameraLens(val label:String) { Front("front"), Back("back") }

/** Camera and bundled on-device segmentation. Lens changes never request unsupported sensor zoom. */
class CameraFeed(private val context: Context) {
    private val mutableFrames=MutableStateFlow<Bitmap?>(null)
    val frames=mutableFrames.asStateFlow()
    private val mutableLens=MutableStateFlow(CameraLens.Front)
    val lens=mutableLens.asStateFlow()
    private val mutableSwitching=MutableStateFlow(true)
    val switching=mutableSwitching.asStateFlow()
    private val main=Handler(Looper.getMainLooper())
    private val executor=Executors.newSingleThreadExecutor()
    // Detector state is owned by the analysis executor and reset at stream discontinuities.
    private var segmenter:Segmenter?=null
    private var detectorGeneration=-1
    private var detectorMaskEpoch=-1
    private var maskSampler:SoftMaskSampler?=null
    private val processing=AtomicBoolean(false)
    private val generation=AtomicInteger(0)
    private val maskEpoch=AtomicInteger(0)
    private var provider:ProcessCameraProvider?=null
    private var analysis:ImageAnalysis?=null
    private var owner:LifecycleOwner?=null
    private var observer:LifecycleEventObserver?=null
    private var errorListener:((String)->Unit)?=null
    private var firstFrameTimeout:Runnable?=null
    @Volatile var removeBackground=false
        set(value) {
            if(field!=value){field=value;maskEpoch.incrementAndGet()}
        }
    @Volatile private var closed=false

    fun start(owner:LifecycleOwner,onError:(String)->Unit) {
        this.owner=owner;errorListener=onError
        observer=LifecycleEventObserver{_,event ->
            when(event) {
                Lifecycle.Event.ON_STOP -> firstFrameTimeout?.let{main.removeCallbacks(it)}
                Lifecycle.Event.ON_START -> firstFrameTimeout?.let{main.removeCallbacks(it);main.postDelayed(it,5_000)}
                Lifecycle.Event.ON_DESTROY -> close()
                else -> Unit
            }
        }.also{owner.lifecycle.addObserver(it)}
        val future=ProcessCameraProvider.getInstance(context)
        future.addListener({
            if(closed)return@addListener
            try {
                provider=future.get()
                val initial=if(provider!!.hasCamera(selector(CameraLens.Front)))CameraLens.Front else CameraLens.Back
                bindCamera(initial,null)
            } catch(e:Exception) {
                mutableSwitching.value=false
                reportError("A camera is unavailable. Turn the camera off and try again.")
            }
        },ContextCompat.getMainExecutor(context))
    }

    /** Only one transition can run. The last confirmed frame remains visible until the new lens produces one. */
    fun flip() {
        if(closed||!mutableSwitching.compareAndSet(false,true))return
        main.post {
            if(closed)return@post
            val previous=mutableLens.value
            val target=if(previous==CameraLens.Front)CameraLens.Back else CameraLens.Front
            try {
                if(provider?.hasCamera(selector(target))!=true) {
                    mutableSwitching.value=false
                    reportError("The ${target.label} camera is unavailable on this phone.")
                    return@post
                }
                bindCamera(target,previous)
            } catch(e:Exception) { restore(previous,target) }
        }
    }

    private fun selector(lens:CameraLens)=if(lens==CameraLens.Front)CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA

    @SuppressLint("MissingPermission")
    private fun bindCamera(target:CameraLens,rollback:CameraLens?) {
        val cameraProvider=checkNotNull(provider)
        val lifecycle=checkNotNull(owner)
        check(cameraProvider.hasCamera(selector(target)))
        mutableSwitching.value=true
        val token=generation.incrementAndGet()
        firstFrameTimeout?.let{main.removeCallbacks(it)}
        analysis?.let{it.clearAnalyzer();cameraProvider.unbind(it)}
        analysis=null
        val firstFrame=AtomicBoolean(true)
        val stream=ImageAnalysis.Builder()
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
            .setTargetResolution(android.util.Size(480,640)).build()
        stream.setAnalyzer(executor){image ->
            try {
                if(closed||token!=generation.get())return@setAnalyzer
                val raw=image.toBitmap()
                val matrix=Matrix().apply {
                    postRotate(image.imageInfo.rotationDegrees.toFloat())
                    if(target==CameraLens.Front)postScale(-1f,1f)
                }
                val frame=Bitmap.createBitmap(raw,0,0,raw.width,raw.height,matrix,true)
                if(!removeBackground)publish(frame,target,token,firstFrame)
                else if(processing.compareAndSet(false,true)) {
                    val matteEpoch=maskEpoch.get()
                    try {
                    detectorFor(token,matteEpoch).process(InputImage.fromBitmap(frame,0))
                        .addOnSuccessListener(executor){mask ->
                            if(!closed&&token==generation.get()&&matteEpoch==maskEpoch.get()&&removeBackground) {
                                val confidence=FloatArray(mask.width*mask.height)
                                mask.buffer.rewind();mask.buffer.asFloatBuffer().get(confidence)
                                val pixels=IntArray(frame.width*frame.height)
                                frame.getPixels(pixels,0,frame.width,0,0,frame.width,frame.height)
                                // ML Kit receives this exact already-oriented bitmap with rotation=0.
                                // Its raw mask is resized over the same extent, without another mirror.
                                val sampler=maskSampler?.takeIf{it.matches(mask.width,mask.height,frame.width,frame.height)}
                                    ?:SoftMaskSampler(mask.width,mask.height,frame.width,frame.height).also{maskSampler=it}
                                sampler.applyTo(pixels,confidence)
                                publish(Bitmap.createBitmap(pixels,frame.width,frame.height,Bitmap.Config.ARGB_8888),target,token,firstFrame)
                            }
                        }.addOnFailureListener(executor){error ->
                            if(!closed&&token==generation.get()&&matteEpoch==maskEpoch.get())reportError("Background removal is unavailable: ${error.localizedMessage}")
                        }.addOnCompleteListener(executor){processing.set(false);releaseDetectorWhenClosed()}
                    } catch(e:Exception) {
                        processing.set(false);releaseDetectorWhenClosed();throw e
                    }
                }
            } catch(e:Exception) {
                if(!closed&&token==generation.get())reportError("Camera preview failed: ${e.localizedMessage}")
            } finally {image.close()}
        }
        try {
            cameraProvider.bindToLifecycle(lifecycle,selector(target),stream)
            analysis=stream
        } catch(e:Exception) {
            stream.clearAnalyzer();cameraProvider.unbind(stream);throw e
        }
        val timeout=Runnable {
            if(closed||token!=generation.get()||!mutableSwitching.value)return@Runnable
            if(rollback!=null)restore(rollback,target)
            else {
                mutableSwitching.value=false
                mutableFrames.value=null
                reportError("The ${target.label} camera did not start. Turn the camera off and try again.")
            }
        }
        firstFrameTimeout=timeout
        if(lifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))main.postDelayed(timeout,5_000)
    }

    private fun detectorFor(cameraGeneration:Int,matteEpoch:Int):Segmenter {
        if(segmenter==null||detectorGeneration!=cameraGeneration||detectorMaskEpoch!=matteEpoch) {
            segmenter?.close()
            segmenter=Segmentation.getClient(SelfieSegmenterOptions.Builder()
                .setDetectorMode(SelfieSegmenterOptions.STREAM_MODE).enableRawSizeMask().build())
            detectorGeneration=cameraGeneration;detectorMaskEpoch=matteEpoch
        }
        return checkNotNull(segmenter)
    }

    private fun releaseDetectorWhenClosed() {
        if(closed&&!processing.get()) {
            segmenter?.close();segmenter=null;maskSampler=null
            executor.shutdown()
        }
    }

    private fun publish(frame:Bitmap,target:CameraLens,token:Int,first:AtomicBoolean) {
        if(closed||token!=generation.get())return
        mutableFrames.value=frame
        if(first.compareAndSet(true,false))main.post {
            if(!closed&&token==generation.get()) {
                firstFrameTimeout?.let{main.removeCallbacks(it)};firstFrameTimeout=null
                mutableLens.value=target;mutableSwitching.value=false
            }
        }
    }

    private fun restore(previous:CameraLens,failedTarget:CameraLens) {
        if(closed)return
        try {
            bindCamera(previous,null)
            reportError("Could not switch to the ${failedTarget.label} camera. Returning to your ${previous.label} camera.")
        } catch(e:Exception) {
            mutableSwitching.value=false
            mutableFrames.value=null
            reportError("The camera could not be restarted. Turn it off and try again.")
        }
    }

    private fun reportError(message:String) {main.post{if(!closed)errorListener?.invoke(message)}}

    fun close() {
        if(closed)return
        closed=true;generation.incrementAndGet();mutableSwitching.value=false
        firstFrameTimeout?.let{main.removeCallbacks(it)};firstFrameTimeout=null
        observer?.let{owner?.lifecycle?.removeObserver(it)};observer=null
        analysis?.clearAnalyzer();analysis?.let{provider?.unbind(it)};analysis=null
        // Let an in-flight result finish before releasing the model/executor it uses.
        runCatching{executor.execute{releaseDetectorWhenClosed()}}
        mutableFrames.value=null
    }
}
