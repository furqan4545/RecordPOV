package studio.roast.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.io.File
import kotlin.math.atan2
import kotlin.math.roundToInt

/** Explicit user-consented full-display recording with a visible camera/microphone foreground service. */
class ScreenTakeService:LifecycleService() {
    private var projection:MediaProjection?=null
    private var display:VirtualDisplay?=null
    private var mediaRecorder:MediaRecorder?=null
    private var voiceEffects:VoiceCaptureEffects?=null
    private var camera:CameraFeed?=null
    private var overlay:FrameLayout?=null
    private var file:File?=null
    private var stopping=false
    private var started=false
    private val manager by lazy{getSystemService(WindowManager::class.java)}
    private val notifications by lazy{getSystemService(NotificationManager::class.java)}

    override fun onCreate(){
        super.onCreate()
        notifications.createNotificationChannel(NotificationChannel(CHANNEL,"Screen recording",NotificationManager.IMPORTANCE_LOW))
    }
    override fun onStartCommand(intent:Intent?,flags:Int,startId:Int):Int {
        super.onStartCommand(intent,flags,startId)
        if(intent?.action==STOP){finishCapture();return START_NOT_STICKY}
        if(started)return START_NOT_STICKY
        var type=ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        if(Build.VERSION.SDK_INT>=30)type=type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        startForeground(NOTIFICATION,ongoingNotification(),type)
        try {
            val result=intent?.getIntExtra(EXTRA_RESULT_CODE,0)?:0
            val data=if(Build.VERSION.SDK_INT>=33)intent?.getParcelableExtra(EXTRA_DATA,Intent::class.java)
                else @Suppress("DEPRECATION") intent?.getParcelableExtra<Intent>(EXTRA_DATA)
            require(result==android.app.Activity.RESULT_OK && data!=null){"Screen sharing permission is missing."}
            val style=runCatching{PipStyle.valueOf(intent?.getStringExtra(EXTRA_STYLE)?:"")}.getOrDefault(PipStyle.Circle)
            beginCapture(result,data,style)
        } catch(e:Exception){
            stopForeground(STOP_FOREGROUND_REMOVE)
            notifyFinished("Screen recording could not start",e.localizedMessage?:"Open RecordPOV and try again.")
            finishCapture();stopSelf()
        }
        return START_NOT_STICKY
    }
    private fun beginCapture(resultCode:Int,data:Intent,style:PipStyle){
        val metrics=resources.displayMetrics
        val width=720
        val height=((metrics.heightPixels.toDouble()/metrics.widthPixels*width).roundToInt()/2)*2
        file=DraftStore(this).newCapture()
        val recorder=if(Build.VERSION.SDK_INT>=31)MediaRecorder(this)else MediaRecorder()
        mediaRecorder=recorder
        recorder.setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
        recorder.setVideoSource(MediaRecorder.VideoSource.SURFACE)
        recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        recorder.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
        recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        recorder.setVideoSize(width,height)
        recorder.setVideoFrameRate(30)
        recorder.setVideoEncodingBitRate(5_000_000)
        recorder.setAudioEncodingBitRate(128_000)
        recorder.setAudioSamplingRate(44_100);recorder.setAudioChannels(1)
        recorder.setOutputFile(file!!.absolutePath)
        recorder.prepare()
        val permission=checkNotNull(getSystemService(MediaProjectionManager::class.java).getMediaProjection(resultCode,data)) {
            "Android did not provide screen-sharing access."
        }
        projection=permission
        permission.registerCallback(object:MediaProjection.Callback(){
            override fun onStop(){Handler(Looper.getMainLooper()).post{finishCapture()}}
        },Handler(Looper.getMainLooper()))
        display=permission.createVirtualDisplay("RecordPOV screen recording",width,height,metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,recorder.surface,null,null)
        voiceEffects=VoiceCaptureEffects(recorder,Handler(Looper.getMainLooper()))
        recorder.start();started=true;running.value=true;voiceEffects?.started()
        lifecycleScope.launch{voiceEffects?.status?.collectLatest{status->if(started&&!stopping)notifications.notify(NOTIFICATION,ongoingNotification(status.description))}}
        addCameraOverlay(style)
    }
    private fun addCameraOverlay(initialStyle:PipStyle){
        val density=resources.displayMetrics.density
        var width=(176*density).roundToInt()
        val layout=WindowManager.LayoutParams(width,(width*1.4f).roundToInt(),WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT).apply{gravity=Gravity.TOP or Gravity.START;x=resources.displayMetrics.widthPixels-width-24;y=220}
        val root=FrameLayout(this)
        val preview=OverlayCameraView(this,initialStyle)
        root.addView(preview,FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT,FrameLayout.LayoutParams.MATCH_PARENT).apply{bottomMargin=(46*density).roundToInt()})
        val controls=LinearLayout(this).apply{
            orientation=LinearLayout.HORIZONTAL
            gravity=Gravity.CENTER
            background=android.graphics.drawable.GradientDrawable().apply{setColor(0xE6202326.toInt());cornerRadius=12*density}
        }
        val styleButton=Button(this).apply{
            text="◉";contentDescription="Change camera shape";setTextColor(Color.WHITE);textSize=16f
            setBackgroundColor(Color.TRANSPARENT);minWidth=0;minimumWidth=0
            setOnClickListener{
                val next=PipStyle.entries[(preview.style.ordinal+1)%PipStyle.entries.size]
                preview.style=next;camera?.removeBackground=next==PipStyle.Cutout;preview.invalidate()
            }
        }
        val stop=Button(this).apply{
            text="■ Stop";contentDescription="Finish screen recording";setTextColor(0xFFDDFC67.toInt());textSize=12f
            setTypeface(typeface,Typeface.BOLD);setBackgroundColor(Color.TRANSPARENT);minWidth=0;minimumWidth=0
            setOnClickListener{finishCapture()}
        }
        val reset=Button(this).apply{
            text="↺";contentDescription="Reset camera position, size, and rotation";setTextColor(Color.WHITE);textSize=18f
            setBackgroundColor(Color.TRANSPARENT);minWidth=0;minimumWidth=0
            setOnClickListener{
                width=(176*density).roundToInt();layout.width=width;layout.height=(width*1.4f).roundToInt()
                layout.x=resources.displayMetrics.widthPixels-width-24;layout.y=220;preview.angle=0f
                manager.updateViewLayout(root,layout);preview.invalidate()
            }
        }
        controls.addView(styleButton,LinearLayout.LayoutParams(0,LinearLayout.LayoutParams.MATCH_PARENT,1f))
        controls.addView(reset,LinearLayout.LayoutParams(0,LinearLayout.LayoutParams.MATCH_PARENT,1f))
        controls.addView(stop,LinearLayout.LayoutParams(0,LinearLayout.LayoutParams.MATCH_PARENT,2f))
        root.addView(controls,FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT,(44*density).roundToInt(),Gravity.BOTTOM))
        var lastX=0f;var lastY=0f;var previousAngle=0f
        val scale=ScaleGestureDetector(this,object:ScaleGestureDetector.SimpleOnScaleGestureListener(){
            override fun onScale(detector:ScaleGestureDetector):Boolean{
                width=(width*detector.scaleFactor).roundToInt().coerceIn((100*density).roundToInt(),(340*density).roundToInt())
                layout.width=width;layout.height=(width*1.4f).roundToInt();manager.updateViewLayout(root,layout);return true
            }
        })
        preview.setOnTouchListener{_,event ->
            scale.onTouchEvent(event)
            when(event.actionMasked){
                MotionEvent.ACTION_DOWN->{lastX=event.rawX;lastY=event.rawY}
                MotionEvent.ACTION_POINTER_DOWN->{if(event.pointerCount>=2)previousAngle=angle(event)}
                MotionEvent.ACTION_MOVE->{
                    if(event.pointerCount>=2){val current=angle(event);preview.angle+=current-previousAngle;previousAngle=current;preview.invalidate()}
                    else if(!scale.isInProgress){
                        layout.x=(layout.x+event.rawX-lastX).roundToInt().coerceIn(-layout.width/3,resources.displayMetrics.widthPixels-layout.width*2/3)
                        layout.y=(layout.y+event.rawY-lastY).roundToInt().coerceIn(0,resources.displayMetrics.heightPixels-layout.height/2)
                        manager.updateViewLayout(root,layout)
                    }
                    lastX=event.rawX;lastY=event.rawY
                }
            }
            true
        }
        manager.addView(root,layout);overlay=root
        camera=CameraFeed(this).also{feed->
            feed.removeBackground=initialStyle==PipStyle.Cutout
            feed.start(this){message->notifyFinished("Camera unavailable",message);finishCapture()}
            lifecycleScope.launch{feed.frames.collectLatest{preview.frame=it;preview.invalidate()}}
        }
    }
    private fun angle(event:MotionEvent)=Math.toDegrees(atan2((event.getY(1)-event.getY(0)).toDouble(),(event.getX(1)-event.getX(0)).toDouble())).toFloat()

    private fun finishCapture(){
        if(stopping)return
        stopping=true
        running.value=false
        overlay?.let{runCatching{manager.removeView(it)}};overlay=null
        camera?.close();camera=null
        var saved=false
        if(started){saved=runCatching{mediaRecorder?.stop();file?.length()?.let{it>0}==true}.getOrDefault(false)}
        runCatching{voiceEffects?.close()};voiceEffects=null
        runCatching{mediaRecorder?.release()};mediaRecorder=null
        display?.release();display=null
        projection?.stop();projection=null
        if(!saved)file?.delete()
        if(saved) {
            notifications.notify(NOTIFICATION,Notification.Builder(this,CHANNEL).setSmallIcon(R.drawable.ic_roast)
                .setContentTitle("Preparing screen recording for editing…").setOngoing(true).build())
            lifecycleScope.launch {
                try {
                    val store=DraftStore(this@ScreenTakeService)
                    val draft=store.prepare(checkNotNull(file),emptyList(),1,"Screen recording",prepareStems=false)
                    store.markPending(draft);readyDraft.value=draft.id
                    notifyFinished("Your screen recording is ready to edit","Open RecordPOV to adjust the sound and finish your video.")
                }catch(e:Exception){notifyFinished("Draft preparation failed","Your original recording is safe in RecordPOV. ${e.localizedMessage.orEmpty()}")}
                finally{stopForeground(STOP_FOREGROUND_REMOVE);stopSelf()}
            }
        } else {
            stopForeground(STOP_FOREGROUND_REMOVE)
            if(started)notifyFinished("Screen recording was too short","Record for at least a second and try again.")
            stopSelf()
        }
    }
    private fun ongoingNotification(voiceStatus:String="Your screen, camera, and microphone are being recorded."):Notification {
        val stop=PendingIntent.getService(this,1,Intent(this,ScreenTakeService::class.java).setAction(STOP),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val open=PendingIntent.getActivity(this,2,Intent(this,MainActivity::class.java),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this,CHANNEL).setSmallIcon(R.drawable.ic_roast).setContentTitle("Recording your screen")
            .setContentText(voiceStatus)
            .setContentIntent(open).setOngoing(true).addAction(Notification.Action.Builder(null,"Stop recording",stop).build()).build()
    }
    private fun notifyFinished(title:String,message:String){
        val open=PendingIntent.getActivity(this,2,Intent(this,MainActivity::class.java),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        notifications.notify(NOTIFICATION+1,Notification.Builder(this,CHANNEL).setSmallIcon(R.drawable.ic_roast)
            .setContentTitle(title).setContentText(message).setContentIntent(open).setAutoCancel(true).build())
    }
    override fun onDestroy(){if(!stopping)finishCapture();super.onDestroy()}
    companion object {
        val running=MutableStateFlow(false)
        val readyDraft=MutableStateFlow<String?>(null)
        fun stop(context:Context){context.startService(Intent(context,ScreenTakeService::class.java).setAction(STOP))}
        const val EXTRA_RESULT_CODE="resultCode";const val EXTRA_DATA="projectionData";const val EXTRA_STYLE="pipStyle"
        private const val CHANNEL="screen_take";private const val NOTIFICATION=17;private const val STOP="studio.roast.STOP"
    }
}

private class OverlayCameraView(context:Context,var style:PipStyle):View(context) {
    var frame:android.graphics.Bitmap?=null
    var angle=0f
    override fun onDraw(canvas:Canvas){
        super.onDraw(canvas)
        frame?.let{FrameComposer.drawPip(canvas,it,PipPlacement(.5f,.5f,2.6f,angle,style),width.toFloat(),height.toFloat())}
    }
}
