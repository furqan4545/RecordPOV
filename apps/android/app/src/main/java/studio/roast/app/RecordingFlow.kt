package studio.roast.app

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

enum class RecordingDelay(val seconds:Int,val label:String) {
    Off(0,"Off"), Three(3,"3s"), Five(5,"5s"), Ten(10,"10s");
    companion object {
        fun fromStoredSeconds(seconds:Int):RecordingDelay = entries.firstOrNull{it.seconds==seconds}?:Three
    }
}

/** A cancelled countdown never reaches the caller's recorder-start step. */
suspend fun awaitRecordingCountdown(choice:RecordingDelay,onTick:(Int?)->Unit,
                                   waitOneSecond:suspend()->Unit={delay(1_000)}) {
    try {
        for(remaining in choice.seconds downTo 1) {
            currentCoroutineContext().ensureActive()
            onTick(remaining)
            waitOneSecond()
        }
        currentCoroutineContext().ensureActive()
    } finally {onTick(null)}
}

fun recordingSourcePosition(currentMs:Long,durationMs:Long,ended:Boolean):Long =
    if(ended||(durationMs>0&&currentMs>=durationMs))0 else currentMs.coerceAtLeast(0)

/** Serializes automatic/manual exports and remembers only successfully published Gallery copies. */
class GalleryExportLedger(private val read:(String)->String?,private val remember:(String,String)->Unit,
                          private val mutex:Mutex=Mutex()) {
    suspend fun save(fileKey:String,exists:suspend(String)->Boolean,findPublished:suspend()->String?,
                     publish:suspend()->String):String = mutex.withLock {
        val known=read(fileKey)?.takeIf{exists(it)} ?: findPublished()
        if(known!=null) {
            remember(fileKey,known)
            return@withLock known
        }
        val result=publish()
        remember(fileKey,result)
        result
    }
}
