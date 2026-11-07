package studio.roast.app

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

internal data class RelayPacket(val id: Long, val bytes: ByteArray)

/** Application framing only. OkHttp owns TLS and the RFC6455 transport. */
internal object YouTubeRelayWire {
    fun packet(bytes:ByteArray):RelayPacket {
        require(bytes.size in 6..(YouTubeTransportPolicy.PAYLOAD+5) && bytes[0].toInt()==1) { "Invalid YouTube payload." }
        var id=0L;for(i in 1..4)id=(id shl 8) or (bytes[i].toLong() and 255)
        require(id in 1..0xffffffffL) { "Invalid YouTube stream." }
        return RelayPacket(id,bytes.copyOfRange(5,bytes.size))
    }
    fun packet(id:Long,bytes:ByteArray):ByteArray {
        require(id in 1..0xffffffffL && bytes.size in 1..YouTubeTransportPolicy.PAYLOAD)
        return ByteArray(bytes.size+5).also { result ->
            result[0]=1;repeat(4){result[it+1]=(id ushr (24-it*8)).toByte()};bytes.copyInto(result,5)
        }
    }
    fun text(bytes:ByteArray):String=Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()

}
