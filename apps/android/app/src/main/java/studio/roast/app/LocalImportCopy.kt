package studio.roast.app

import android.content.Context
import android.content.res.AssetFileDescriptor
import android.net.Uri
import android.os.CancellationSignal
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal suspend fun copyImportedDocument(context:Context,uri:Uri,file:File) {
    val finished=withTimeoutOrNull(1_800_000) {suspendCancellableCoroutine<Boolean> {continuation->
        val cancellation=CancellationSignal();val descriptor=AtomicReference<AssetFileDescriptor?>(null)
        continuation.invokeOnCancellation {
            Dispatchers.IO.dispatch(EmptyCoroutineContext,Runnable{cancellation.cancel();runCatching{descriptor.getAndSet(null)?.close()};file.delete()})
        }
        Dispatchers.IO.dispatch(EmptyCoroutineContext,Runnable {
            try {
                val opened=context.contentResolver.openAssetFileDescriptor(uri,"r",cancellation) ?: error("The selected video could not be opened.")
                descriptor.set(opened)
                check(continuation.isActive){"Import cancelled."}
                opened.use{it.createInputStream().use{input->file.outputStream().use{output->
                    val buffer=ByteArray(65536);var total=0L
                    while(true){check(continuation.isActive){"Import cancelled."};val count=input.read(buffer);if(count<0)break;total+=count;check(total<=DirectImportPolicy.MAX_FILE_BYTES){"This video is too large."};output.write(buffer,0,count)}
                }}}
                descriptor.set(null)
                check(file.length()>0){"The selected video is empty."}
                if(continuation.isActive)continuation.resume(true)else file.delete()
            }catch(e:Exception){file.delete();runCatching{descriptor.getAndSet(null)?.close()};if(continuation.isActive)continuation.resumeWithException(e)}
        })
    }}
    check(finished==true){"The selected video took too long to copy. Please try again."}
}
