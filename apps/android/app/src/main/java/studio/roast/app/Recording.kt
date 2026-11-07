package studio.roast.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.media.MediaRecorder
import android.net.Uri
import android.opengl.EGL14
import android.opengl.EGLExt
import android.opengl.GLES20
import android.opengl.GLUtils
import android.os.Handler
import android.os.HandlerThread
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.max
import kotlin.math.min

object FrameComposer {
    private val splitBackdrop=SplitVideoBackdrop()
    fun drawSplitBackdrop(canvas:Canvas,bitmap:Bitmap,rect:RectF,sourceAspect:Float?=null,revision:Int=bitmap.generationId) {
        val content=SplitVideoBackdrop.contentRect(bitmap,sourceAspect)
        if(kotlin.math.abs(content.width().toFloat()/content.height()-rect.width()/rect.height())>.01f)
            splitBackdrop.draw(canvas,bitmap,rect,sourceAspect,revision)
    }
    fun drawFit(canvas: Canvas, bitmap: Bitmap, rect: RectF,sourceAspect:Float?=null) {
        // TextureView snapshots already contain the player's fit transform; crop those bars once.
        val source=if(sourceAspect!=null&&sourceAspect>0) {
            val fittedWidth=min(bitmap.width.toFloat(),bitmap.height*sourceAspect)
            val fittedHeight=min(bitmap.height.toFloat(),bitmap.width/sourceAspect)
            Rect(((bitmap.width-fittedWidth)/2).toInt(),((bitmap.height-fittedHeight)/2).toInt(),((bitmap.width+fittedWidth)/2).toInt(),((bitmap.height+fittedHeight)/2).toInt())
        }else Rect(0,0,bitmap.width,bitmap.height)
        val fitted=StageGeometry.sourceFit(source.width().toFloat(),source.height().toFloat(),
            CameraFramingRect(rect.left,rect.top,rect.width(),rect.height()))
        canvas.drawBitmap(bitmap,source,RectF(fitted.left,fitted.top,fitted.right,fitted.bottom),Paint(Paint.FILTER_BITMAP_FLAG))
    }

    fun drawPip(canvas: Canvas, bitmap: Bitmap, placement: PipPlacement, width: Float, height: Float) {
        val w = width * .34f * placement.scale
        val h = PipGeometry.heightForWidth(w,placement.style)
        val bounds = RectF(-w/2, -h/2, w/2, h/2)
        canvas.save()
        canvas.translate(placement.x * width, placement.y * height)
        canvas.rotate(placement.rotation)
        drawCameraInBounds(canvas,bitmap,placement.style,placement.framingScale,bounds)
        canvas.restore()
    }

    /** Regular shapes fill edge to edge in preview and export. Cutout fits with transparent margins. */
    fun drawCameraInBounds(canvas:Canvas,bitmap:Bitmap,style:PipStyle,framingScale:Float,bounds:RectF) {
        if(bounds.width()<=0f||bounds.height()<=0f)return
        canvas.save()
        if (style != PipStyle.Cutout) {
            val radius = when(style) { PipStyle.Circle -> min(bounds.width(),bounds.height()) / 2; PipStyle.Square -> 0f; else -> bounds.width() * .16f }
            val clip = Path().apply { addRoundRect(bounds, radius, radius, Path.Direction.CW) }
            canvas.clipPath(clip)
        } else canvas.clipRect(bounds)
        val fitted=PipGeometry.cameraRect(bitmap.width.toFloat(),bitmap.height.toFloat(),bounds.width(),bounds.height(),style,framingScale)
        canvas.drawBitmap(bitmap,null,RectF(bounds.left+fitted.left,bounds.top+fitted.top,
            bounds.left+fitted.right,bounds.top+fitted.bottom),Paint(Paint.FILTER_BITMAP_FLAG))
        canvas.restore()
    }

    fun drawStage(canvas:Canvas,background:Bitmap?,camera:Bitmap?,pip:PipPlacement,width:Float,height:Float,
                  layout:StageLayout=StageLayout(),fullScreenCamera:Boolean=false,sourceAspect:Float?=null) {
        canvas.drawColor(Color.rgb(22,24,27))
        val full=RectF(0f,0f,width,height)
        fun source(rect:RectF){background?.let{drawFit(canvas,it,rect,sourceAspect)}}
        fun camera(rect:RectF){camera?.let{drawCameraInBounds(canvas,it,PipStyle.Square,1f,rect)}}
        if(fullScreenCamera&&camera!=null){camera(full);return}
        when(layout.template) {
            StageTemplate.Pip->{source(full);camera?.let{drawPip(canvas,it,pip,width,height)}}
            StageTemplate.Split->{
                val top=StageGeometry.sourceTop(width,height,layout);val bottom=StageGeometry.cameraBottom(width,height,layout)
                val pane=RectF(top.left,top.top,top.right,top.bottom)
                background?.let{drawSplitBackdrop(canvas,it,pane,sourceAspect)}
                source(pane);camera(RectF(bottom.left,bottom.top,bottom.right,bottom.bottom))
            }
            StageTemplate.CameraMain->{
                camera(full)
                val aspect=sourceAspect?:background?.let{it.width.toFloat()/it.height}?:9f/16f
                val overlay=StageGeometry.sourceOverlay(width,height,aspect,layout.sourceOverlay)
                val rect=RectF(overlay.left,overlay.top,overlay.right,overlay.bottom)
                canvas.save();canvas.clipRect(rect);canvas.drawColor(Color.rgb(22,24,27));source(rect);canvas.restore()
            }
        }
    }
    fun compose(background: Bitmap?, camera: Bitmap?, pip: PipPlacement,
                width: Int = 720, height: Int = 1280,fullScreenCamera:Boolean=false,layout:StageLayout=StageLayout(),sourceAspect:Float?=null): Bitmap {
        val result = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(result)
        drawStage(canvas,background,camera,pip,width.toFloat(),height.toFloat(),layout,fullScreenCamera,sourceAspect)
        return result
    }
}

/** Surface-backed H.264 + AAC encoder. Composed frames and microphone audio stay on device. */
class TakeRecorder(private val context: Context, val output: File) {
    private val thread = HandlerThread("RoastEncoder").apply { start() }
    private val handler = Handler(thread.looper)
    private val busy = AtomicBoolean(false)
    @Volatile var isRecording = false; private set
    @Volatile private var paused = false
    @Volatile private var failed: Throwable? = null
    private var recorder: MediaRecorder? = null
    @Volatile private var voiceEffects:VoiceCaptureEffects?=null
    private val emptyVoiceStatus=MutableStateFlow(VoiceProtectionStatus())
    val voiceProtection:kotlinx.coroutines.flow.StateFlow<VoiceProtectionStatus> get()=voiceEffects?.status?:emptyVoiceStatus
    private var gl: BitmapSurface? = null

    suspend fun start() = suspendCancellableCoroutine<Unit> { continuation ->
        handler.post {
            try {
                val media = if (android.os.Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else MediaRecorder()
                recorder = media
                media.setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
                media.setVideoSource(MediaRecorder.VideoSource.SURFACE)
                media.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                media.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
                media.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                media.setVideoSize(720, 1280)
                media.setVideoFrameRate(24)
                media.setVideoEncodingBitRate(4_000_000)
                media.setAudioEncodingBitRate(128_000)
                media.setAudioSamplingRate(44_100)
                media.setAudioChannels(1)
                media.setOutputFile(output.absolutePath)
                media.prepare()
                gl = BitmapSurface(media.surface, 720, 1280)
                voiceEffects=VoiceCaptureEffects(media,handler)
                media.start(); isRecording = true
                voiceEffects?.started()
                if (continuation.isActive) continuation.resume(Unit)
            } catch (e: Throwable) {
                failed = e
                runCatching { voiceEffects?.close() };voiceEffects=null
                runCatching { gl?.release() }; runCatching { recorder?.release() }
                thread.quitSafely(); output.delete()
                if (continuation.isActive) continuation.resumeWithException(e)
            }
        }
    }

    fun submit(frame: Bitmap) {
        if (!isRecording || paused || !busy.compareAndSet(false, true)) { frame.recycle(); return }
        handler.post {
            try { if (isRecording) gl?.render(frame) }
            catch (e: Throwable) { failed = e }
            finally { frame.recycle(); busy.set(false) }
        }
    }

    suspend fun pause() = suspendCancellableCoroutine<Unit> { continuation ->
        paused = true
        handler.post {
            try { recorder?.pause();voiceEffects?.paused(); if(continuation.isActive)continuation.resume(Unit) }
            catch(e:Throwable) { paused=false; if(continuation.isActive)continuation.resumeWithException(e) }
        }
    }

    suspend fun resume() = suspendCancellableCoroutine<Unit> { continuation ->
        handler.post {
            try { recorder?.resume();voiceEffects?.started(); paused=false; if(continuation.isActive)continuation.resume(Unit) }
            catch(e:Throwable) { if(continuation.isActive)continuation.resumeWithException(e) }
        }
    }

    suspend fun stop(): File = suspendCancellableCoroutine { continuation ->
        isRecording = false
        handler.post {
            try {
                gl?.release(); gl = null
                recorder?.stop();voiceEffects?.close();voiceEffects=null
                recorder?.release(); recorder = null
                failed?.let { throw it }
                check(output.length() > 0) { "The recording contains no video." }
                if (continuation.isActive) continuation.resume(output)
            } catch (e: Throwable) {
                runCatching { voiceEffects?.close() };voiceEffects=null;runCatching { recorder?.release() }; output.delete()
                if (continuation.isActive) continuation.resumeWithException(e)
            } finally { thread.quitSafely() }
        }
    }

    fun abort() {
        isRecording = false
        handler.post {
            runCatching { gl?.release() }
            runCatching { recorder?.stop() }
            runCatching { voiceEffects?.close() };voiceEffects=null
            runCatching { recorder?.release() }
            output.delete(); thread.quitSafely()
        }
    }
}

private class BitmapSurface(surface: android.view.Surface, private val width: Int, private val height: Int) {
    private val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
    private val eglContext: android.opengl.EGLContext
    private val window: android.opengl.EGLSurface
    private val program: Int
    private val texture: Int
    private val vertices = ByteBuffer.allocateDirect(8 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        .apply { put(floatArrayOf(-1f,-1f, 1f,-1f, -1f,1f, 1f,1f)); position(0) }
    private val coordinates = ByteBuffer.allocateDirect(8 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        .apply { put(floatArrayOf(0f,1f, 1f,1f, 0f,0f, 1f,0f)); position(0) }

    init {
        check(EGL14.eglInitialize(display, null, 0, null, 0)) { "Could not initialize the video encoder." }
        val configs = arrayOfNulls<android.opengl.EGLConfig>(1)
        val count = IntArray(1)
        EGL14.eglChooseConfig(display, intArrayOf(EGL14.EGL_RED_SIZE,8,EGL14.EGL_GREEN_SIZE,8,
            EGL14.EGL_BLUE_SIZE,8,EGL14.EGL_ALPHA_SIZE,8,EGL14.EGL_RENDERABLE_TYPE,EGL14.EGL_OPENGL_ES2_BIT,
            0x3142,1,EGL14.EGL_NONE),0,configs,0,1,count,0)
        check(count[0] > 0) { "This phone does not provide a compatible recording surface." }
        eglContext = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION,2,EGL14.EGL_NONE),0)
        window = EGL14.eglCreateWindowSurface(display,configs[0],surface,intArrayOf(EGL14.EGL_NONE),0)
        check(EGL14.eglMakeCurrent(display,window,window,eglContext))
        fun shader(type: Int, source: String): Int = GLES20.glCreateShader(type).also {
            GLES20.glShaderSource(it,source); GLES20.glCompileShader(it)
            val status=IntArray(1); GLES20.glGetShaderiv(it,GLES20.GL_COMPILE_STATUS,status,0)
            check(status[0] != 0) { GLES20.glGetShaderInfoLog(it) }
        }
        program=GLES20.glCreateProgram()
        GLES20.glAttachShader(program,shader(GLES20.GL_VERTEX_SHADER,
            "attribute vec2 position; attribute vec2 uv; varying vec2 coordinate; void main(){gl_Position=vec4(position,0.,1.);coordinate=uv;}"))
        GLES20.glAttachShader(program,shader(GLES20.GL_FRAGMENT_SHADER,
            "precision mediump float; uniform sampler2D image; varying vec2 coordinate; void main(){gl_FragColor=texture2D(image,coordinate);}"))
        GLES20.glLinkProgram(program)
        val textures=IntArray(1); GLES20.glGenTextures(1,textures,0); texture=textures[0]
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D,texture)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D,GLES20.GL_TEXTURE_MIN_FILTER,GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D,GLES20.GL_TEXTURE_MAG_FILTER,GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D,GLES20.GL_TEXTURE_WRAP_S,GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D,GLES20.GL_TEXTURE_WRAP_T,GLES20.GL_CLAMP_TO_EDGE)
    }
    fun render(bitmap: Bitmap) {
        GLES20.glViewport(0,0,width,height); GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0); GLES20.glBindTexture(GLES20.GL_TEXTURE_2D,texture)
        GLUtils.texImage2D(GLES20.GL_TEXTURE_2D,0,bitmap,0)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program,"image"),0)
        val position=GLES20.glGetAttribLocation(program,"position")
        val uv=GLES20.glGetAttribLocation(program,"uv")
        GLES20.glEnableVertexAttribArray(position); GLES20.glEnableVertexAttribArray(uv)
        GLES20.glVertexAttribPointer(position,2,GLES20.GL_FLOAT,false,0,vertices)
        GLES20.glVertexAttribPointer(uv,2,GLES20.GL_FLOAT,false,0,coordinates)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP,0,4)
        EGLExt.eglPresentationTimeANDROID(display,window,System.nanoTime())
        check(EGL14.eglSwapBuffers(display,window)) { "The video encoder stopped accepting frames." }
    }
    fun release() {
        GLES20.glDeleteTextures(1,intArrayOf(texture),0); GLES20.glDeleteProgram(program)
        EGL14.eglMakeCurrent(display,EGL14.EGL_NO_SURFACE,EGL14.EGL_NO_SURFACE,EGL14.EGL_NO_CONTEXT)
        EGL14.eglDestroySurface(display,window); EGL14.eglDestroyContext(display,eglContext); EGL14.eglTerminate(display)
    }
}

data class SourceAudioSegment(val uri: Uri, val timelineStartMs: Long, val sourceStartMs: Long, val durationMs: Long)

