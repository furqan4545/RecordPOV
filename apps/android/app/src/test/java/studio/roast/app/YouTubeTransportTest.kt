package studio.roast.app

import org.junit.Assert.*
import org.junit.Test
import java.net.InetAddress

class YouTubeTransportTest {
    @Test fun allowedHostsUseExactDnsLabelBoundaries() {
        listOf("youtube.com","www.youtube.com","rr1.sn-ab.googlevideo.com","i.ytimg.com","youtubei.googleapis.com","WWW.YouTube.com")
            .forEach{assertTrue(it,YouTubeTransportPolicy.destination(it,443))}
    }
    @Test fun malformedAndUnrelatedHostsNeverBecomeDestinations() {
        listOf("youtube.com.evil.test","evilyoutube.com","youtubei.googleapis.com.evil.test","x.youtubei.googleapis.com",
            "youtube.com.","youtube.com:443","user@youtube.com","youtube.com/path","localhost","127.0.0.1","[::1]",
            "youtube.com\n","you\u200btube.com","-x.youtube.com","x-.youtube.com","a..youtube.com","a_b.youtube.com")
            .forEach{assertFalse(it,YouTubeTransportPolicy.destination(it,443))}
        assertFalse(YouTubeTransportPolicy.destination("youtube.com",80))
    }
    @Test fun normalYoutubeShareHostsUseTheAssistedPath() {
        listOf("https://youtu.be/bkPwFqa89gE","https://www.youtube.com/watch?v=bkPwFqa89gE","https://m.youtube.com/shorts/bkPwFqa89gE")
            .forEach{assertTrue(YouTubeTransportPolicy.isYouTubeLink(it))}
        listOf("https://youtube.com.evil.test/watch?v=x","https://instagram.com/reel/x","https://user@youtube.com/watch?v=x")
            .forEach{assertFalse(YouTubeTransportPolicy.isYouTubeLink(it))}
    }
    @Test fun publicIpv4AddressesRemainUsable() {
        listOf("8.8.8.8","142.250.206.14","1.1.1.1","192.0.1.1","198.51.101.1")
            .forEach{assertTrue(it,public(it))}
    }
    @Test fun ipv4PrivateMetadataDocumentationAndReservedAreDenied() {
        listOf("0.1.2.3","10.1.1.1","100.64.0.1","100.127.255.254","127.0.0.1","169.254.169.254",
            "172.16.1.1","172.31.255.255","192.0.0.9","192.0.2.1","192.88.99.1","192.168.1.1",
            "198.18.0.1","198.19.255.255","198.51.100.1","203.0.113.1","224.0.0.1","240.0.0.1","255.255.255.255")
            .forEach{assertFalse(it,public(it))}
    }
    @Test fun publicNativeIpv6RemainsUsable() {
        listOf("2001:4860:4860::8888","2606:4700:4700::1111","2a00:1450:400e:810::200e")
            .forEach{assertTrue(it,public(it))}
    }
    @Test fun ipv6NonpublicAndTransitionRangesAreDenied() {
        listOf("::","::1","fe80::1","fc00::1","ff02::1","2001:db8::1","2001::1","2001:20::1",
            "2002:0808:0808::1","3fff::1","3fff:fff::1","64:ff9b:1::808:808","::ffff:192.168.1.1","::ffff:203.0.113.1")
            .forEach{assertFalse(it,public(it))}
    }
    @Test fun wellKnownDns64InspectsEmbeddedIpv4() {
        assertTrue(public("64:ff9b::808:808"))
        listOf("64:ff9b::a00:1","64:ff9b::7f00:1","64:ff9b::a9fe:a9fe","64:ff9b::c000:201")
            .forEach{assertFalse(it,public(it))}
    }
    @Test fun sessionCapabilityIsRestrictedToExactSecureOriginAndPath() {
        val base="https://api.recordpov.app";val id="session_id-123";val token="a".repeat(43)
        val socket="$base/v1/media/youtube/sessions/$id/socket".replace("https:","wss:")
        assertEquals("api.recordpov.app",YouTubeTransportPolicy.socketEndpoint(base,id,token,socket).host)
        listOf(socket.replace("wss:","ws:"),socket.replace("api.recordpov.app","api.recordpov.app.evil.test"),
            "$socket?token=secret","$socket#fragment",socket.replace("/socket","/%73ocket"),
            socket.replace("api.recordpov.app","user@api.recordpov.app"),socket.replace("api.recordpov.app","api.recordpov.app:8443"))
            .forEach{assertThrows(IllegalArgumentException::class.java){YouTubeTransportPolicy.socketEndpoint(base,id,token,it)}}
    }
    @Test fun unsafeSessionIdsTokensAndHttpApiAreRejected() {
        val base="https://api.recordpov.app";val token="a".repeat(43)
        listOf("../other","x/socket","x?token=secret","", "x".repeat(129)).forEach {
            assertThrows(IllegalArgumentException::class.java){YouTubeTransportPolicy.socketEndpoint(base,it,token,"wss://api.recordpov.app/v1/media/youtube/sessions/$it/socket")}
        }
        assertThrows(IllegalArgumentException::class.java){YouTubeTransportPolicy.apiEndpoint("http://api.recordpov.app")}
        assertThrows(IllegalArgumentException::class.java){YouTubeTransportPolicy.apiEndpoint("https://api.recordpov.app/other")}
        assertThrows(IllegalArgumentException::class.java){YouTubeTransportPolicy.socketEndpoint(base,"id","bad","wss://api.recordpov.app/v1/media/youtube/sessions/id/socket")}
    }
    @Test fun binaryPacketPreservesFullUnsignedIdAndPayload() {
        val payload=ByteArray(32768){(it%251).toByte()}
        val encoded=YouTubeRelayWire.packet(0xffffffffL,payload)
        assertArrayEquals(byteArrayOf(1,-1,-1,-1,-1),encoded.take(5).toByteArray())
        val decoded=YouTubeRelayWire.packet(encoded)
        assertEquals(0xffffffffL,decoded.id);assertArrayEquals(payload,decoded.bytes)
    }
    @Test fun malformedBinaryFramesAreRejected() {
        listOf(byteArrayOf(),byteArrayOf(1,0,0,0,1),byteArrayOf(2,0,0,0,1,42),byteArrayOf(1,0,0,0,0,42),ByteArray(32774){1})
            .forEach{assertThrows(IllegalArgumentException::class.java){YouTubeRelayWire.packet(it)}}
        assertThrows(IllegalArgumentException::class.java){YouTubeRelayWire.packet(0,byteArrayOf(1))}
        assertThrows(IllegalArgumentException::class.java){YouTubeRelayWire.packet(0x100000000L,byteArrayOf(1))}
    }
    @Test fun malformedUtf8CannotBecomeControlJson() {
        assertThrows(java.nio.charset.CharacterCodingException::class.java){YouTubeRelayWire.text(byteArrayOf(0xc0.toByte(),0xaf.toByte()))}
    }
    @Test fun creditExhaustionStopsFurtherPayloadUntilRealAcknowledgement() {
        val ledger=RelayCredit();repeat(8){ledger.consume(32768)}
        assertEquals(0,ledger.remaining())
        assertThrows(IllegalArgumentException::class.java){ledger.consume(1)}
        ledger.acknowledge(1234);assertEquals(1234,ledger.remaining())
        ledger.consume(1234);assertEquals(0,ledger.remaining())
    }
    @Test fun acknowledgementsCannotCreateCreditOrCrossDirections() {
        val sender=RelayCredit();val receiver=RelayCredit()
        assertThrows(IllegalArgumentException::class.java){sender.acknowledge(1)}
        sender.consume(123)
        listOf(-1,0,124,262145).forEach{assertThrows(IllegalArgumentException::class.java){sender.acknowledge(it)}}
        assertEquals(262144,receiver.remaining())
        sender.acknowledge(123)
        assertThrows(IllegalArgumentException::class.java){sender.acknowledge(123)}
    }
    @Test fun sessionByteBudgetCannotOverflowOrResumeAfterLimit() {
        val budget=RelayByteBudget(100);budget.accept(60);budget.accept(40)
        assertThrows(IllegalArgumentException::class.java){budget.accept(1)}
        assertThrows(IllegalArgumentException::class.java){budget.accept(Int.MAX_VALUE)}
        assertThrows(IllegalArgumentException::class.java){budget.accept(-1)}
    }
    private fun public(text:String)=YouTubeTransportPolicy.publicAddress(InetAddress.getByName(text).address)
}
