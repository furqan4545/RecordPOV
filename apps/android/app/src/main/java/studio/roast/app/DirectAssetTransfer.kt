package studio.roast.app

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.net.InetAddress
import java.net.Proxy
import java.net.URI
import java.net.UnknownHostException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal class ImportByteBudget(private val maximum:Long) {
    private var bytes=0L
    @Synchronized fun add(count:Int){require(count>0&&count.toLong()<=maximum-bytes){"This video is too large."};bytes+=count}
    /** A piece download counts its whole known size once, so a retried piece is never counted twice. */
    @Synchronized fun reserve(count:Long){require(count>0&&count<=maximum-bytes){"This video is too large."};bytes+=count}
    /** A whole-file restart from zero gives back the bytes of the attempt it throws away. */
    @Synchronized fun release(count:Long){bytes=(bytes-count).coerceAtLeast(0)}
}

/** Pure piece and stall rules, the same as iOS BackgroundMediaDownloads. */
internal object PieceDownload {
    /** YouTube throttles whole-file requests; byte ranges of this size download at full speed. */
    const val PIECE_SIZE=10L*1024*1024
    const val PARALLEL_PIECES=4
    /** A running download that receives no bytes for this long is cancelled and requested again. */
    const val STALL_WINDOW_MS=30_000L
    const val STALL_CHECK_MS=5_000L
    /** Attempts per piece or whole-file transfer, the first one included. */
    const val MAX_ATTEMPTS=5
    enum class StallDecision { Keep,Retry,Fail }
    fun stallDecision(lastBytesAt:Long,now:Long,attempts:Int):StallDecision=when {
        now-lastBytesAt<STALL_WINDOW_MS->StallDecision.Keep
        attempts>=MAX_ATTEMPTS->StallDecision.Fail
        else->StallDecision.Retry
    }
    /** Inclusive byte ranges covering [total]; the last piece is shorter. */
    fun pieceRanges(total:Long,pieceSize:Long=PIECE_SIZE):List<LongRange> {
        if(total<=0||pieceSize<=0)return emptyList()
        val count=(total+pieceSize-1)/pieceSize
        return (0 until count).map{index->index*pieceSize..minOf((index+1)*pieceSize,total)-1}
    }
    /** googlevideo URLs carry the file's total size as `clen`. */
    fun declaredLength(url:String):Long?=runCatching {
        URI(url).rawQuery.orEmpty().split('&').map{it.split('=',limit=2)}.firstOrNull{it[0]=="clen"}?.getOrNull(1)?.toLongOrNull()?.takeIf{it>0}
    }.getOrNull()
    /** The total from "bytes <start>-<end>/<total>". */
    fun contentRangeTotal(header:String?):Long? {
        if(header==null||!header.startsWith("bytes "))return null
        val slash=header.lastIndexOf('/')
        if(slash<0)return null
        return header.substring(slash+1).toLongOrNull()?.takeIf{it>0}
    }
    /** Bytes received across pieces over the total, never above 100%. */
    fun progress(received:Long,total:Long):Double=if(total<=0)0.0 else (received.toDouble()/total).coerceIn(0.0,1.0)
}

private fun monotonicMillis()=System.nanoTime()/1_000_000

/** One attempt's current call and when its last bytes arrived; a stall cancels that call. */
private class StallWatch(val attempts:Int) {
    @Volatile var lastBytesAt=monotonicMillis()
        private set
    @Volatile var decision=PieceDownload.StallDecision.Keep
        private set
    @Volatile private var call:Call?=null
    fun touch(){lastBytesAt=monotonicMillis()}
    @Synchronized fun attach(next:Call){call=next;if(decision!=PieceDownload.StallDecision.Keep)next.cancel()}
    @Synchronized fun stall(value:PieceDownload.StallDecision){decision=value;call?.cancel()}
    fun ensureOpen(){if(call?.isCanceled()==true)throw IOException("The video download was interrupted.")}
}

internal object DirectAssetTransfer {
    private fun client(platform:String?)=OkHttpClient.Builder().proxy(Proxy.NO_PROXY)
        .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
        .connectTimeout(15,TimeUnit.SECONDS).readTimeout(60,TimeUnit.SECONDS).callTimeout(2,TimeUnit.HOURS)
        .apply{if(platform!=null)dns(object:Dns {
            override fun lookup(hostname:String):List<InetAddress> {
                val values=InetAddress.getAllByName(hostname).toList()
                if(values.isEmpty()||values.size>32||values.any{!YouTubeTransportPolicy.publicAddress(it.address)})
                    throw UnknownHostException("The video destination is not public.")
                // OkHttp connects only to these validated numeric addresses, including redirects.
                return values
            }
        })}.build()
    /** YouTube files download in 10 MiB pieces; every other asset as one whole file. [onProgress] reports piece progress. */
    suspend fun asset(asset:DirectAsset,platform:String,destination:File,budget:ImportByteBudget,onProgress:(Double)->Unit={}) {
        val client=client(platform)
        val allowed:(String)->Boolean={DirectImportPolicy.allowedUrl(it,platform)}
        try {
            if(platform=="youtube")pieces(client,asset.url,asset.headers,destination,budget,allowed,onProgress)
            else whole(client,asset.url,asset.headers,destination,budget,allowed)
        }finally{close(client)}
    }
    suspend fun prepared(base:String,url:String,destination:File) {
        val client=client(null)
        try{whole(client,url,emptyMap(),destination,ImportByteBudget(DirectImportPolicy.MAX_FILE_BYTES)){DirectImportPolicy.apiFile(base,it)}}
        finally{close(client)}
    }
    private fun close(client:OkHttpClient){client.dispatcher.cancelAll();client.connectionPool.evictAll();client.dispatcher.executorService.shutdown()}

    /** One whole file; 30 s without bytes restarts it from zero, at most [PieceDownload.MAX_ATTEMPTS] attempts. */
    private suspend fun whole(client:OkHttpClient,url:String,headers:Map<String,String>,file:File,budget:ImportByteBudget,allowed:(String)->Boolean) {
        var attempts=0
        while(true) {
            attempts++
            val watch=StallWatch(attempts)
            val written=AtomicLong()
            val finished=try {
                guarded(watch) {
                    request(client,url,headers,null,allowed,watch) {response->
                        check(response.isSuccessful){"The video download expired or was denied."}
                        check(response.body.contentLength()<=DirectImportPolicy.MAX_FILE_BYTES){"This video is too large."}
                        checkNotManifest(response)
                        response.body.byteStream().use{input->file.outputStream().use{output->
                            val bytes=ByteArray(65536)
                            while(true) {
                                watch.ensureOpen()
                                val count=input.read(bytes);if(count<0)break
                                budget.add(count);written.addAndGet(count.toLong());watch.touch()
                                output.write(bytes,0,count)
                            }
                        }}
                        // A stall-cancelled stream can end like a finished one; that attempt is retried, never kept.
                        watch.ensureOpen()
                        check(file.length()>0){"The video file is empty."}
                    }
                }
            }catch(e:Throwable){file.delete();budget.release(written.get());throw e}
            if(finished)return
            // The same request again from zero; out of attempts, the existing error or fallback path takes over.
            file.delete();budget.release(written.get())
            if(watch.decision==PieceDownload.StallDecision.Fail)throw IOException("The video download was interrupted.")
        }
    }

    /** YouTube: total from `clen` (or one ranged probe), 10 MiB ranges up to four at a time, each written at its offset. */
    private suspend fun pieces(client:OkHttpClient,url:String,headers:Map<String,String>,file:File,budget:ImportByteBudget,
        allowed:(String)->Boolean,onProgress:(Double)->Unit) {
        try {
            val total=PieceDownload.declaredLength(url) ?: probe(client,url,headers,allowed)
            check(total<=DirectImportPolicy.MAX_FILE_BYTES){"This video is too large."}
            budget.reserve(total)
            val received=AtomicLong()
            val gate=Semaphore(PieceDownload.PARALLEL_PIECES)
            RandomAccessFile(file,"rw").use{output->
                output.setLength(0)
                val channel=output.channel
                // One failed piece fails the transfer and cancels the others; a user cancel stops every piece at once.
                coroutineScope {
                    PieceDownload.pieceRanges(total).map{range->
                        async{gate.withPermit{piece(client,url,headers,allowed,range,total,channel,received,onProgress)}}
                    }.awaitAll()
                }
                check(channel.size()==total){"The video download was interrupted."}
            }
        }catch(e:Throwable){file.delete();throw e}
    }

    /** One range: 206 with exactly its Content-Range and exactly its length; a stalled piece is requested again with the same range. */
    private suspend fun piece(client:OkHttpClient,url:String,headers:Map<String,String>,allowed:(String)->Boolean,range:LongRange,total:Long,
        channel:FileChannel,received:AtomicLong,onProgress:(Double)->Unit) {
        val length=range.last-range.first+1
        var attempts=0
        while(true) {
            attempts++
            val watch=StallWatch(attempts)
            val got=AtomicLong()
            val finished=try {
                guarded(watch) {
                    request(client,url,headers,"bytes=${range.first}-${range.last}",allowed,watch) {response->
                        check(response.code==206&&response.header("Content-Range")=="bytes ${range.first}-${range.last}/$total"){"The video download expired or was denied."}
                        checkNotManifest(response)
                        response.body.byteStream().use{input->
                            val bytes=ByteArray(65536)
                            while(true) {
                                watch.ensureOpen()
                                val count=input.read(bytes);if(count<0)break
                                // A response larger than the requested range is not that piece.
                                check(got.get()+count<=length){"The video download was interrupted."}
                                val buffer=ByteBuffer.wrap(bytes,0,count)
                                var position=range.first+got.get()
                                while(buffer.hasRemaining())position+=channel.write(buffer,position)
                                got.addAndGet(count.toLong());watch.touch()
                                onProgress(PieceDownload.progress(received.addAndGet(count.toLong()),total))
                            }
                        }
                        check(got.get()==length){"The video download was interrupted."}
                    }
                }
            }catch(e:Throwable){received.addAndGet(-got.get());throw e}
            if(finished)return
            received.addAndGet(-got.get())
            if(watch.decision==PieceDownload.StallDecision.Fail)throw IOException("The video download was interrupted.")
        }
    }

    /** One `bytes=0-0` request for a YouTube URL without `clen`: 206 from an allowed host, the total from Content-Range. */
    private suspend fun probe(client:OkHttpClient,url:String,headers:Map<String,String>,allowed:(String)->Boolean):Long =
        request(client,url,headers,"bytes=0-0",allowed,StallWatch(1)) {response->
            check(response.code==206){"The video download was interrupted."}
            PieceDownload.contentRangeTotal(response.header("Content-Range")) ?: throw IOException("The video download was interrupted.")
        }

    private fun checkNotManifest(response:Response) {
        check(!response.header("Content-Type").orEmpty().contains("mpegurl",true)&&!response.header("Content-Type").orEmpty().contains("dash+xml",true))
    }

    /** Runs one attempt while a watchdog looks every 5 s for 30 s without bytes; false when that attempt stalled. */
    private suspend fun guarded(watch:StallWatch,block:suspend()->Unit):Boolean=coroutineScope {
        val watchdog=launch {
            while(true) {
                delay(PieceDownload.STALL_CHECK_MS)
                val decision=PieceDownload.stallDecision(watch.lastBytesAt,monotonicMillis(),watch.attempts)
                if(decision!=PieceDownload.StallDecision.Keep){watch.stall(decision);break}
            }
        }
        try{block();true}
        catch(e:CancellationException){throw e}
        catch(e:Exception){if(watch.decision!=PieceDownload.StallDecision.Keep)false else throw e}
        finally{watchdog.cancel()}
    }

    private sealed interface Hop<out T> {
        data class Redirect(val location:String):Hop<Nothing>
        data class Done<T>(val value:T):Hop<T>
    }
    /** Sends the request and each redirect (every address checked first, at most three hops); [read] gets the final response. */
    private suspend fun <T> request(client:OkHttpClient,initial:String,headers:Map<String,String>,range:String?,allowed:(String)->Boolean,
        watch:StallWatch,read:(Response)->T):T {
        var current=initial
        repeat(4) {hop->
            require(allowed(current)){"Unsupported video download address."}
            val request=Request.Builder().url(current).apply{headers.forEach{(key,value)->header(key,value)};if(range!=null)header("Range",range)}.build()
            val call=client.newCall(request)
            watch.attach(call)
            val outcome=await<Hop<T>>(call) {response->
                if(response.code in listOf(301,302,303,307,308))Hop.Redirect(response.header("Location") ?: error("Invalid video redirect."))
                else Hop.Done(read(response))
            }
            when(outcome) {
                is Hop.Done->return outcome.value
                is Hop.Redirect->{
                    require(hop<3){"The video redirected too many times."}
                    current=current.toHttpUrl().resolve(outcome.location)?.toString() ?: error("Invalid video redirect.")
                }
            }
        }
        error("The video redirected too many times.")
    }
    /** Cancellation (the user's, or a stall) cancels the call; the response is read and closed on OkHttp's thread. */
    private suspend fun <T> await(call:Call,read:(Response)->T):T=suspendCancellableCoroutine {continuation->
        continuation.invokeOnCancellation{call.cancel()}
        call.enqueue(object:Callback {
            override fun onFailure(call:Call,e:IOException){if(continuation.isActive)continuation.resumeWithException(IOException("The video download was interrupted."))}
            override fun onResponse(call:Call,response:Response) {
                try {
                    val value=response.use{read(it)}
                    if(continuation.isActive)continuation.resume(value)
                }catch(e:Exception){if(continuation.isActive)continuation.resumeWithException(e)}
            }
        })
    }
}

internal suspend fun <T> importWithFallback(primary:suspend()->T,fallback:suspend()->T):T =
    try{primary()}catch(e:CancellationException){throw e}catch(e:Exception){fallback()}
