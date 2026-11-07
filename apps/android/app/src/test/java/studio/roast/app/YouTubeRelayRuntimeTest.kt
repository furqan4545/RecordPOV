package studio.roast.app

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import okhttp3.Request
import okhttp3.WebSocket
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.Socket
import java.net.SocketAddress
import java.net.URI
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** All network objects are fakes. These tests do not open sockets or activate hardware. */
class YouTubeRelayRuntimeTest {
    @Test fun ackAndHalfCloseFollowTheCompletedTcpWrite()=runBlocking {
        val tcp=FakeTcp(blockWrites=true);val h=Harness(this,tcp)
        try {
            h.attach();h.open(1);h.awaitType("opened")
            h.binary(1,byteArrayOf(1,2,3));h.control("end",1)
            assertTrue(withContext(Dispatchers.IO){tcp.writeStarted.await(2,TimeUnit.SECONDS)})
            assertFalse(h.hasType("ack"));assertFalse(tcp.outputEnded.get())
            tcp.allowWrite.countDown();h.awaitType("ack")
            eventually{tcp.outputEnded.get()}
            assertEquals(listOf("write:3","end"),tcp.events.toList())
            assertEquals(3,h.ws.controls.first{it.optString("type")=="ack"}.getInt("bytes"))
        } finally {h.close()}
    }
    @Test fun outgoingTcpReadsPauseAtCreditWindowAndResumeOnAck()=runBlocking {
        val size=YouTubeTransportPolicy.WINDOW+YouTubeTransportPolicy.PAYLOAD
        val tcp=FakeTcp(input=ByteArray(size){7});val h=Harness(this,tcp)
        try {
            h.attach();h.open(1)
            eventually{h.ws.binary.size==8}
            assertEquals(YouTubeTransportPolicy.WINDOW,tcp.bytesRead.get())
            h.raw("{\"type\":\"ack\",\"id\":1,\"bytes\":32768}")
            eventually{h.ws.binary.size==9}
            assertEquals(size,tcp.bytesRead.get())
            assertEquals(size,h.ws.binary.sumOf{YouTubeRelayWire.packet(it).bytes.size})
        } finally {h.close()}
    }
    @Test fun mixedPublicAndPrivateDnsAnswersNeverOpenASocket()=runBlocking {
        val h=Harness(this,FakeTcp(),listOf("8.8.8.8","127.0.0.1"))
        try {
            h.attach();h.open(1);h.awaitType("error")
            assertEquals(0,h.created.get());assertFalse(h.hasType("opened"))
        } finally {h.close()}
    }
    @Test fun closingSessionCancelsWebSocketAndAllTcpStreams()=runBlocking {
        val tcp=FakeTcp();val h=Harness(this,tcp)
        h.attach();h.open(1);h.awaitType("opened");h.close()
        assertTrue(h.ws.cancelled.get());assertTrue(tcp.closed.get())
    }
    @Test fun malformedAckFailsTheWholeSession()=runBlocking {
        val h=Harness(this,FakeTcp())
        try {
            h.attach();h.open(1);h.awaitType("opened")
            h.raw("{\"type\":\"ack\",\"id\":1,\"bytes\":1}")
            assertTrue(h.relay.failure.isCompleted);assertTrue(h.ws.cancelled.get())
        } finally {h.close()}
    }
    @Test fun streamIdsCannotBeReusedAfterClosing()=runBlocking {
        val h=Harness(this,FakeTcp())
        try {
            h.attach();h.open(1);h.awaitType("opened");h.control("close",1);h.open(1)
            assertTrue(h.relay.failure.isCompleted)
        } finally {h.close()}
    }
    @Test fun tinyFrameFloodCannotCreateAnUnboundedWriteQueue()=runBlocking {
        val tcp=FakeTcp(blockWrites=true);val h=Harness(this,tcp)
        try {
            h.attach();h.open(1);h.awaitType("opened")
            h.binary(1,byteArrayOf(1))
            assertTrue(withContext(Dispatchers.IO){tcp.writeStarted.await(2,TimeUnit.SECONDS)})
            repeat(66){h.binary(1,byteArrayOf(1))}
            assertTrue(h.relay.failure.isCompleted);assertTrue(tcp.closed.get())
        } finally {h.close()}
    }
    @Test fun unsupportedDestinationAndUnknownControlFailClosed()=runBlocking {
        val h=Harness(this,FakeTcp())
        try {
            h.attach();h.raw("{\"type\":\"open\",\"id\":1,\"host\":\"metadata.google.internal\",\"port\":443}")
            assertTrue(h.relay.failure.isCompleted);assertEquals(0,h.created.get())
        } finally {h.close()}
        val second=Harness(this,FakeTcp())
        try {second.attach();second.raw("{\"type\":\"unknown\"}");assertTrue(second.relay.failure.isCompleted)}finally{second.close()}
    }

    private class Harness(scope:CoroutineScope,tcp:FakeTcp,addresses:List<String> = listOf("8.8.8.8")) {
        val ws=FakeWs();val created=AtomicInteger();val client=YouTubePhoneRelay.client()
        val relay=YouTubePhoneRelay(scope,client,lookup={addresses.map{InetAddress.getByName(it)}},newSocket={created.incrementAndGet();tcp},
            openWebSocket={_,listener->ws.also{listener.onMessage(it,"{\"type\":\"ready\",\"version\":1}")}})
        suspend fun attach()=relay.attach(URI("wss://api.recordpov.app/v1/media/youtube/sessions/id/socket"),"a".repeat(43))
        fun raw(text:String)=relay.listener.onMessage(ws,text)
        fun open(id:Long)=raw("{\"type\":\"open\",\"id\":$id,\"host\":\"www.youtube.com\",\"port\":443}")
        fun control(type:String,id:Long)=raw("{\"type\":\"$type\",\"id\":$id}")
        fun binary(id:Long,bytes:ByteArray)=relay.listener.onMessage(ws,YouTubeRelayWire.packet(id,bytes).toByteString())
        fun hasType(type:String)=ws.controls.any{it.optString("type")==type}
        suspend fun awaitType(type:String)=eventually{hasType(type)}
        fun close(){relay.close();client.connectionPool.evictAll();client.dispatcher.executorService.shutdown()}
    }
    private class FakeWs:WebSocket {
        val controls=CopyOnWriteArrayList<JSONObject>();val binary=CopyOnWriteArrayList<ByteArray>();val cancelled=AtomicBoolean()
        override fun request()=Request.Builder().url("https://api.recordpov.app").build()
        override fun queueSize()=0L
        override fun send(text:String):Boolean {controls.add(JSONObject(text));return !cancelled.get()}
        override fun send(bytes:ByteString):Boolean {binary.add(bytes.toByteArray());return !cancelled.get()}
        override fun close(code:Int,reason:String?)=true
        override fun cancel(){cancelled.set(true)}
    }
    private class FakeTcp(input:ByteArray?=null,blockWrites:Boolean=false):Socket() {
        val closed=AtomicBoolean();val outputEnded=AtomicBoolean();val bytesRead=AtomicInteger()
        val writeStarted=CountDownLatch(1);val allowWrite=CountDownLatch(if(blockWrites)1 else 0)
        val events=CopyOnWriteArrayList<String>();private val allowEof=CountDownLatch(1)
        private val source=input?.let(::ByteArrayInputStream)
        override fun connect(endpoint:SocketAddress?,timeout:Int){}
        override fun setTcpNoDelay(value:Boolean){}
        override fun getInputStream()=object:InputStream() {
            override fun read():Int {val bytes=ByteArray(1);return if(read(bytes,0,1)<0)-1 else bytes[0].toInt() and 255}
            override fun read(bytes:ByteArray,offset:Int,length:Int):Int {
                if(source==null){allowEof.await();return -1}
                return source.read(bytes,offset,length).also{if(it>0)bytesRead.addAndGet(it)}
            }
        }
        override fun getOutputStream()=object:OutputStream() {
            override fun write(value:Int)=write(byteArrayOf(value.toByte()))
            override fun write(bytes:ByteArray,offset:Int,length:Int) {writeStarted.countDown();allowWrite.await();events.add("write:$length")}
        }
        override fun shutdownOutput(){outputEnded.set(true);events.add("end")}
        override fun close(){closed.set(true);allowEof.countDown();allowWrite.countDown()}
    }
    companion object {
        private suspend fun eventually(block:()->Boolean)=withTimeout(3000){while(!block())delay(5)}
    }
}
