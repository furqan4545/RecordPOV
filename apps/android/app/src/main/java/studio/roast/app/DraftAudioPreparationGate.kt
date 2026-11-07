package studio.roast.app

import java.io.File
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Close/reopen can overlap jobs, but only one job may write a draft's stems. */
internal object DraftAudioPreparationGate {
    private val locks=Array(32){Mutex()}
    suspend fun <T> run(directory:File,block:suspend()->T):T {
        val index=(directory.absoluteFile.normalize().path.hashCode() and Int.MAX_VALUE)%locks.size
        return locks[index].withLock{block()}
    }
}
