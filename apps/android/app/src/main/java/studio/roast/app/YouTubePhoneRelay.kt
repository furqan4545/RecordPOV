package studio.roast.app

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.io.Closeable
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Plain JVM transport: no camera, Android lifecycle, account cookies, or TLS interception. */
internal class YouTubePhoneRelay(
    private val scope:CoroutineScope,
    private val client:OkHttpClient,
    private val lookup:(String)->List<InetAddress> ={InetAddress.getAllByName(it).toList()},
    private val bindSocket:(Socket)->Unit={},
    private val newSocket:()->Socket={Socket()},
    private val openWebSocket:(Request,WebSocketListener)->WebSocket=client::newWebSocket
):Closeable {
    private val closed=AtomicBoolean(false)
    private val ready=CompletableDeferred<Unit>()
    val failure=CompletableDeferred<IOException>()
    private val lock=Any()
    private val sendLock=Any()
    private val streams=linkedMapOf<Long,Stream>() // closed ids stay reserved; queue storage is released
    private val jobs=ConcurrentHashMap.newKeySet<Job>()
    private val budget=RelayByteBudget()
    @Volatile private var socket:WebSocket?=null
    private var active=0

    suspend fun attach(endpoint:URI,token:String) {
        check(!closed.get())
        val created=openWebSocket(Request.Builder().url(endpoint.toString())
            .header("X-YouTube-Session-Token",token).build(),listener)
        socket=created
        if(closed.get())created.cancel()
        withTimeout(20_000) { select<Unit> { ready.onAwait{};failure.onAwait{throw it} } }
    }

    internal val listener=object:WebSocketListener() {
        override fun onOpen(webSocket:WebSocket,response:Response) {
            if(closed.get()){webSocket.cancel();return}
            socket=webSocket
            // No extensions are requested by our application; the client may advertise deflate,
            // so require the server to decline it, and disable outbound compression as well.
            if(response.header("Sec-WebSocket-Extensions")!=null)fail(IOException("Unexpected YouTube compression."))
        }
        override fun onMessage(webSocket:WebSocket,text:String)=guard {
            require(text.toByteArray(Charsets.UTF_8).size<=4096) { "YouTube control is too large." }
            val data=JSONObject(text)
            when(data.optString("type")) {
                "ready" -> { fields(data,"type","version");require(integer(data,"version",1)==1L && !ready.isCompleted);ready.complete(Unit) }
                "open" -> {
                    fields(data,"type","id","host","port");require(ready.isCompleted)
                    val id=integer(data,"id");val host=data.get("host") as? String ?: error("Invalid destination.")
                    val port=integer(data,"port",65535).toInt()
                    require(YouTubeTransportPolicy.destination(host,port)) { "YouTube requested an unsupported destination." }
                    val stream=synchronized(lock) {
                        require(id !in streams && active<YouTubeTransportPolicy.MAX_STREAMS && streams.size<4096) { "YouTube stream limit exceeded." }
                        Stream(id).also{streams[id]=it;active++}
                    }
                    work { open(stream,host) }
                }
                "ack" -> {
                    fields(data,"type","id","bytes")
                    val stream=stream(integer(data,"id"));stream.outgoing.acknowledge(integer(data,"bytes",YouTubeTransportPolicy.WINDOW.toLong()).toInt())
                    stream.creditChanged.trySend(Unit)
                }
                "end" -> {
                    fields(data,"type","id");val stream=stream(integer(data,"id"))
                    synchronized(stream) {
                        if(!stream.closed) {
                            require(stream.opened && !stream.endQueued);stream.endQueued=true
                            check(stream.writes.trySend(Write.End).isSuccess) { "YouTube write queue is full." }
                        }
                    }
                }
                "close" -> {fields(data,"type","id");closeStream(stream(integer(data,"id")))}
                else -> error("Unknown YouTube control.")
            }
        }
        override fun onMessage(webSocket:WebSocket,bytes:ByteString)=guard {
            require(ready.isCompleted && bytes.size<=YouTubeTransportPolicy.MAX_FRAME)
            val packet=YouTubeRelayWire.packet(bytes.toByteArray());budget.accept(packet.bytes.size)
            val stream=stream(packet.id)
            synchronized(stream) {
                // Frames already in flight can arrive after a local connection error/close.
                if(!stream.closed) {
                    require(stream.opened && !stream.endQueued)
                    stream.incoming.consume(packet.bytes.size)
                    check(stream.writes.trySend(Write.Data(packet.bytes)).isSuccess) { "YouTube write queue is full." }
                }
            }
        }
        override fun onClosing(webSocket:WebSocket,code:Int,reason:String) {
            webSocket.close(code,null)
            if(!closed.get())fail(IOException("The YouTube connection ended. Please try again."))
        }
        override fun onClosed(webSocket:WebSocket,code:Int,reason:String) {
            if(!closed.get())fail(IOException("The YouTube connection ended. Please try again."))
        }
        override fun onFailure(webSocket:WebSocket,t:Throwable,response:Response?) {
            response?.close()
            if(!closed.get())fail(IOException("Your phone’s connection was interrupted. Please try the video again."))
        }
    }

    private suspend fun open(stream:Stream,host:String) {
        try {
            withTimeout(15_000) {
                val addresses=withContext(Dispatchers.IO){lookup(host)}
                require(addresses.isNotEmpty() && addresses.size<=16 && addresses.all{YouTubeTransportPolicy.publicAddress(it.address)}) { "Non-public YouTube destination." }
                var connection:Socket?=null
                val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(12)
                for(address in addresses) {
                    if(!scope.isActive || stream.closed)throw CancellationException()
                    val remaining=TimeUnit.NANOSECONDS.toMillis(deadline-System.nanoTime()).toInt()
                    if(remaining<=0)break
                    val candidate=newSocket();stream.tcp.set(candidate)
                    try {
                        bindSocket(candidate)
                        candidate.tcpNoDelay=true
                        // Numeric InetAddress only: never resolve this name again during connect.
                        candidate.connect(InetSocketAddress(address,443),minOf(5000,remaining))
                        connection=candidate;break
                    } catch(e:Exception) {candidate.close();stream.tcp.compareAndSet(candidate,null)}
                }
                checkNotNull(connection) { "Connection failed" }
            }
            if(stream.closed || closed.get())return
            stream.opened=true
            sendControl(JSONObject().put("type","opened").put("id",stream.id))
            work { writeTcp(stream) };work { readTcp(stream) }
        } catch(e:CancellationException) {closeStream(stream);throw e}
        catch(e:Exception) {
            if(!stream.closed && !closed.get())sendControl(JSONObject().put("type","error").put("id",stream.id).put("message","Connection failed"))
            closeStream(stream)
        }
    }

    private suspend fun writeTcp(stream:Stream) {
        try {
            val tcp=checkNotNull(stream.tcp.get());val output=tcp.getOutputStream()
            for(item in stream.writes)when(item) {
                is Write.Data -> {
                    output.write(item.bytes);output.flush()
                    // Acknowledge only a completed target write, never a queued packet.
                    stream.incoming.acknowledge(item.bytes.size)
                    sendControl(JSONObject().put("type","ack").put("id",stream.id).put("bytes",item.bytes.size))
                }
                Write.End -> {
                    tcp.shutdownOutput();stream.remoteEnded=true;finishHalfClose(stream);return
                }
            }
        } catch(e:CancellationException){throw e}
        catch(e:IllegalArgumentException){fail(IOException(e.message ?: "YouTube transfer limit exceeded."))}
        catch(e:Exception){streamError(stream)}
    }

    private suspend fun readTcp(stream:Stream) {
        try {
            val input=checkNotNull(stream.tcp.get()).getInputStream();val buffer=ByteArray(YouTubeTransportPolicy.PAYLOAD)
            while(!stream.closed && !closed.get()) {
                while(stream.outgoing.remaining()==0)stream.creditChanged.receive()
                val size=input.read(buffer,0,minOf(buffer.size,stream.outgoing.remaining()))
                if(size<0) {
                    sendControl(JSONObject().put("type","end").put("id",stream.id))
                    stream.localEnded=true;finishHalfClose(stream);return
                }
                if(size==0)continue
                stream.outgoing.consume(size);budget.accept(size)
                sendBinary(YouTubeRelayWire.packet(stream.id,buffer.copyOf(size)))
            }
        } catch(e:CancellationException){throw e}
        catch(e:Exception){streamError(stream)}
    }

    private fun finishHalfClose(stream:Stream) {if(stream.localEnded && stream.remoteEnded)closeStream(stream)}
    private fun streamError(stream:Stream) {
        if(!stream.closed && !closed.get())sendControl(JSONObject().put("type","close").put("id",stream.id))
        closeStream(stream)
    }
    private fun stream(id:Long)=synchronized(lock){streams[id] ?: error("Unknown YouTube stream.")}
    private fun closeStream(stream:Stream) {
        synchronized(stream) {
            if(stream.closed)return
            stream.closed=true
            runCatching{stream.tcp.getAndSet(null)?.close()}
            stream.writes.cancel();stream.creditChanged.cancel()
            synchronized(lock){active--}
        }
    }
    private fun sendControl(data:JSONObject) {
        if(closed.get())return
        val text=data.toString()
        synchronized(sendLock) {
            val ws=checkNotNull(socket)
            check(ws.queueSize()+text.toByteArray().size<=MAX_BUFFER && ws.send(text)) { "YouTube connection is busy. Please try again." }
        }
    }
    private suspend fun sendBinary(bytes:ByteArray) {
        while(!closed.get()) {
            val sent=synchronized(sendLock) {
                val ws=checkNotNull(socket)
                if(ws.queueSize()+bytes.size>MAX_BUFFER-CONTROL_RESERVE)false
                else {check(ws.send(bytes.toByteString())) { "YouTube connection ended." };true}
            }
            if(sent)return
            delay(10) // actual socket backpressure, no UI timing delay
        }
        throw CancellationException()
    }
    private fun work(block:suspend()->Unit) {
        val job=scope.launch(Dispatchers.IO) {
            try{block()}
            catch(e:CancellationException){throw e}
            catch(e:Exception){fail(IOException(e.message ?: "The YouTube connection failed."))}
        }
        jobs.add(job);job.invokeOnCompletion{jobs.remove(job)}
    }
    private inline fun guard(block:()->Unit) {
        if(closed.get())return
        try{block()}catch(e:Exception){fail(IOException(e.message ?: "Invalid YouTube connection."))}
    }
    private fun fail(error:IOException) {if(!closed.get()){failure.complete(error);close()}}
    override fun close() {
        if(!closed.compareAndSet(false,true))return
        socket?.cancel();socket=null
        synchronized(lock){streams.values.toList()}.forEach(::closeStream)
        jobs.toList().forEach{it.cancel()};jobs.clear()
    }

    private sealed interface Write {data class Data(val bytes:ByteArray):Write;data object End:Write}
    private class Stream(val id:Long) {
        val tcp=AtomicReference<Socket?>(null)
        val outgoing=RelayCredit();val incoming=RelayCredit()
        // Credit bounds bytes to256KiB; a separate64-item bound limits tiny-frame overhead.
        val writes=Channel<Write>(64);val creditChanged=Channel<Unit>(Channel.CONFLATED)
        @Volatile var opened=false
        @Volatile var closed=false
        @Volatile var endQueued=false
        @Volatile var localEnded=false
        @Volatile var remoteEnded=false
    }
    companion object {
        private const val MAX_BUFFER=1024L*1024
        private const val CONTROL_RESERVE=64L*1024
        fun client()=OkHttpClient.Builder().connectTimeout(15,TimeUnit.SECONDS).readTimeout(0,TimeUnit.SECONDS)
            .writeTimeout(15,TimeUnit.SECONDS).pingInterval(10,TimeUnit.SECONDS)
            .minWebSocketMessageToCompress(Long.MAX_VALUE).followRedirects(false).followSslRedirects(false)
            .retryOnConnectionFailure(false).build()
        private fun integer(data:JSONObject,key:String,maximum:Long=0xffffffffL):Long {
            val value=data.get(key)
            require(value is Number && value.toString().matches(Regex("[1-9][0-9]{0,12}"))) { "Invalid YouTube number." }
            return value.toString().toLong().also{require(it in 1..maximum)}
        }
        private fun fields(data:JSONObject,vararg names:String) {
            require(data.keys().asSequence().toSet()==names.toSet()) { "Invalid YouTube control fields." }
        }
    }
}
