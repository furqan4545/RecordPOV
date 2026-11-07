package studio.roast.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.PowerManager
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.File

/** One user-initiated import; notification and CPU ownership exist only while work is active. */
class MediaImportService:LifecycleService() {
    private var work:Job?=null
    private var activeId:String?=null
    private var latestStartId=0
    private var pendingStart:Pair<ImportJobRecord,Int>?=null
    private val coordinator by lazy{ImportCoordinator.get(this)}
    override fun onCreate(){super.onCreate();getSystemService(NotificationManager::class.java)
        .createNotificationChannel(NotificationChannel(CHANNEL,"Video imports",NotificationManager.IMPORTANCE_LOW))}
    override fun onStartCommand(intent:Intent?,flags:Int,startId:Int):Int {
        super.onStartCommand(intent,flags,startId)
        latestStartId=startId
        if(intent?.action==CANCEL) {
            val cancelId=intent.getStringExtra("id")
            if(cancelId==activeId)work?.cancel(CancellationException("Import cancelled."))
            pendingStart?.takeIf{it.first.id==cancelId}?.let{coordinator.cancelled(it.first);pendingStart=null}
            if(work==null)stopSelf(startId)
            return START_NOT_STICKY
        }
        val supplied=runCatching{intent?.getStringExtra("job")?.let{ImportJobRecord.parse(JSONObject(it))}}.getOrNull()
        val saved=coordinator.jobs.read()
        val input=listOfNotNull(coordinator.state.value,saved,supplied).maxByOrNull{it.created}
        if(work?.isActive==true) {
            if(input!=null&&input.id!=activeId&&input.active)pendingStart=input to startId
            return START_REDELIVER_INTENT
        }
        return begin(input,startId)
    }
    private fun begin(input:ImportJobRecord?,startId:Int):Int {
        if(input==null || input.status==ImportStatus.Cancelled || input.status==ImportStatus.Failed || input.attempts>=2 || System.currentTimeMillis()-input.created>IMPORT_JOB_MAX_AGE_MS) {
            if(input!=null&&input.active){coordinator.publishMemory(input);coordinator.failed(input,"This import was interrupted. Return to RecordPOV and retry.")}
            stopSelf(startId);return START_NOT_STICKY
        }
        if(input.status==ImportStatus.Ready) {coordinator.publishMemory(input);stopSelf(startId);return START_NOT_STICKY}
        val record=input.copy(status=ImportStatus.Downloading,message=null,attempts=input.attempts+1)
        activeId=record.id;coordinator.publishMemory(record)
        try {startForeground(NOTIFICATION,notification(record),ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)}
        catch(e:Exception){coordinator.failed(record,"Background importing could not start. Return to RecordPOV and try again.");stopSelf(startId);return START_NOT_STICKY}
        val wake=getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"RecordPOV:VideoImport")
        wake.acquire(180*60*1000L)
        work=lifecycleScope.launch {
            var current=record
            try {
                coordinator.update(current)
                val imported=withTimeout(180*60*1000L){withContext(Dispatchers.IO) {
                    val files=ImportedVideoFiles(File(filesDir,"imports"));files.cleanPending()
                    File(cacheDir,"import-transfer").deleteRecursively()
                    cacheDir.listFiles().orEmpty().filter{it.name.startsWith("local-import-")&&it.extension=="mp4"}.forEach{it.delete()}
                    if(current.local) {
                        val temporary=File(cacheDir,"local-import-${current.id}.mp4")
                        try {
                            val ctx=currentCoroutineContext()
                            copyImportedDocument(this@MediaImportService,Uri.parse(current.input),temporary)
                            current=current.copy(status=ImportStatus.Loading);coordinator.update(current);updateNotification(current)
                            val facts=NativeSourceMedia.inspect(temporary,strict=false)
                            files.store(temporary.inputStream(),current.title,facts.durationUs/1000,null,null,checkActive={ctx.ensureActive()})
                        }finally{temporary.delete()}
                    }else {
                        val resolver=MediaResolver(this@MediaImportService,current.server)
                        val source=resolver.resolve(current.input,onPhase={phase->
                            current=current.copy(status=if(phase==MediaLoadingPhase.Downloading)ImportStatus.Downloading else ImportStatus.Loading)
                            coordinator.update(current);updateNotification(current)
                        },foregroundManaged=true,primaryTried=current.fallbackUsed,onFallback={
                            current=current.copy(fallbackUsed=true);coordinator.update(current)
                        })
                        files.list().firstOrNull{it.file.absolutePath==source.uri.path} ?: error("The imported video could not be found.")
                    }
                }}
                current=current.copy(status=ImportStatus.Ready,importedId=imported.id,title=imported.title,message=null)
                coordinator.update(current)
            }catch(e:CancellationException) {
                withContext(NonCancellable){coordinator.update(current.copy(status=ImportStatus.Cancelled,message=
                    if(e is TimeoutCancellationException)"This import took too long. Please retry."else e.message?.takeIf{it.isNotBlank()}?:"Import cancelled."))}
            }catch(e:Exception) {
                coordinator.update(current.copy(status=ImportStatus.Failed,message=importFailureMessage(e)))
            }finally {
                if(wake.isHeld)wake.release()
                if(activeId==record.id){
                    val next=pendingStart;pendingStart=null;activeId=null;work=null
                    if(next!=null&&lifecycle.currentState!=androidx.lifecycle.Lifecycle.State.DESTROYED)begin(next.first,next.second)
                    else{stopForeground(STOP_FOREGROUND_REMOVE);stopSelf(latestStartId)}
                }
            }
        }
        return START_REDELIVER_INTENT
    }
    override fun onTimeout(startId:Int,fgsType:Int) {work?.cancel(CancellationException("Android paused this import. Return to RecordPOV and retry."));stopForeground(STOP_FOREGROUND_REMOVE);stopSelf()}
    override fun onDestroy(){work?.cancel(CancellationException("The import was interrupted. Return to RecordPOV and retry."));super.onDestroy()}
    private fun updateNotification(record:ImportJobRecord){getSystemService(NotificationManager::class.java).notify(NOTIFICATION,notification(record))}
    private fun notification(record:ImportJobRecord):Notification {
        val open=PendingIntent.getActivity(this,0,Intent(this,MainActivity::class.java),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val cancel=PendingIntent.getService(this,record.id.hashCode(),Intent(this,MediaImportService::class.java).setAction(CANCEL).putExtra("id",record.id),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this,CHANNEL).setSmallIcon(R.drawable.ic_roast).setContentTitle(if(record.status==ImportStatus.Loading)"Loading your video…"else"Downloading your video…")
            .setContentText("You can leave RecordPOV while this finishes.").setContentIntent(open).setOngoing(true)
            .setProgress(0,0,true).addAction(Notification.Action.Builder(null,"Cancel import",cancel).build()).build()
    }
    companion object {
        private const val CHANNEL="video_imports";private const val NOTIFICATION=41;private const val CANCEL="studio.roast.CANCEL_IMPORT"
        fun cancel(context:Context,id:String){context.startService(Intent(context,MediaImportService::class.java).setAction(CANCEL).putExtra("id",id))}
    }
}

internal class ImportCoordinator private constructor(private val context:Context) {
    val jobs=ImportJobFiles(File(context.noBackupFilesDir,"video-import"))
    private val mutable=MutableStateFlow<ImportJobRecord?>(null)
    val state=mutable.asStateFlow()
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
    private val consuming=Mutex()
    // The job that opens in Studio by itself once it finishes, kept process-wide like iOS automaticJobID:
    // leaving the app or Create keeps it; only explicitly opening another video or photo clears it.
    private val autoOpen=MutableStateFlow<String?>(null)
    val autoOpenJobId=autoOpen.asStateFlow()
    init {scope.launch {val saved=withContext(Dispatchers.IO){jobs.read()};if(mutable.value==null){mutable.value=saved?.let{
        if(it.active)it.copy(status=ImportStatus.Interrupted,message=if(it.local)ImportGuidanceCopy.INTERRUPTED_UPLOAD else ImportGuidanceCopy.INTERRUPTED)else it
    }
        // A finished import restored after the app was closed opens once Create is on screen again, as on iOS.
        saved?.takeIf{it.status==ImportStatus.Ready&&autoOpen.value==null}?.let{autoOpen.value=it.id}
    }}}
    fun deferOpening(){autoOpen.value=null}
    fun start(input:String,local:Boolean,server:String,title:String="Your video") {
        if(mutable.value?.active==true)return
        val record=ImportJobRecord.create(input,local,server,title)
        mutable.value=record
        autoOpen.value=record.id
        try{ContextCompat.startForegroundService(context,Intent(context,MediaImportService::class.java).putExtra("job",record.json().toString()))}
        catch(e:Exception){failed(record,"Import could not start. Return to RecordPOV and try again.")}
    }
    fun publishMemory(record:ImportJobRecord){mutable.value=record}
    suspend fun update(record:ImportJobRecord) {
        withContext(Dispatchers.IO){synchronized(jobs){if(mutable.value?.id==record.id){
            // Another video was opened meanwhile: the finished import simply stays in Recent and is not saved as a
            // pending job, so a restart never opens it by itself (iOS consumeReady when automaticJobID != id).
            if(record.status==ImportStatus.Ready&&autoOpen.value!=record.id)jobs.clear(record.id)else jobs.save(record)
            mutable.value=record
        }}}
    }
    fun failed(record:ImportJobRecord,message:String){scope.launch{update(record.copy(status=ImportStatus.Failed,message=message))}}
    fun cancelled(record:ImportJobRecord){scope.launch{update(record.copy(status=ImportStatus.Cancelled,message="Import cancelled."))}}
    suspend fun consumeReady(expectedId:String?=null):ImportedVideo? = consuming.withLock {
        val record=mutable.value?.takeIf{it.status==ImportStatus.Ready} ?: return@withLock null
        if(expectedId!=null&&record.importedId!=expectedId)return@withLock null
        val item=withContext(Dispatchers.IO){ImportedVideoFiles(File(context.filesDir,"imports")).get(record.importedId.orEmpty())}
        if(item!=null&&mutable.value?.id==record.id){withContext(Dispatchers.IO){jobs.clear(record.id)};mutable.value=null}
        item
    }
    /** Drops a finished job whose import the user deleted; never touches an active or different job. */
    suspend fun forgetReady(importedId:String) {
        withContext(Dispatchers.IO){synchronized(jobs){
            val record=mutable.value
            if(record!=null&&record.status==ImportStatus.Ready&&record.importedId==importedId){jobs.clear(record.id);mutable.value=null}
            jobs.read()?.takeIf{it.status==ImportStatus.Ready&&it.importedId==importedId}?.let{jobs.clear(it.id)}
        }}
    }
    companion object {
        @Volatile private var instance:ImportCoordinator?=null
        fun get(context:Context)=instance?:synchronized(this){instance?:ImportCoordinator(context.applicationContext).also{instance=it}}
    }
}
