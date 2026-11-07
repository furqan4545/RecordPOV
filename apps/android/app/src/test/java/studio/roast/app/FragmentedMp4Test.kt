package studio.roast.app

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** YouTube's DASH files declare their full duration in a moov that holds no samples; the import clears those declared durations. */
class FragmentedMp4Test {
    @get:Rule val folder=TemporaryFolder()

    private fun be32(value:Long)=byteArrayOf((value shr 24).toByte(),(value shr 16).toByte(),(value shr 8).toByte(),value.toByte())
    private fun box(type:String,payload:ByteArray)=be32(payload.size+8L)+type.toByteArray(Charsets.US_ASCII)+payload
    /** version 0: flags, creation, modification, then timescale + duration (mvhd/mdhd) or id + reserved + duration (tkhd). */
    private fun header(type:String,duration:Long):ByteArray {
        val common=ByteArray(4)+be32(1)+be32(2)
        val body=if(type=="tkhd")common+be32(1)+be32(0)+be32(duration)+ByteArray(60) else common+be32(60_000)+be32(duration)+ByteArray(80)
        return box(type,body)
    }
    private fun movie(fragmented:Boolean,duration:Long):ByteArray {
        val trak=box("trak",header("tkhd",duration)+box("mdia",header("mdhd",duration)))
        val moov=box("moov",header("mvhd",duration)+(if(fragmented)box("mvex",box("trex",ByteArray(24))) else ByteArray(0))+trak)
        return box("ftyp","dash".toByteArray(Charsets.US_ASCII)+ByteArray(4))+moov+box("mdat",ByteArray(32){7})
    }

    @Test fun fragmentedFileHasItsDeclaredDurationsCleared() {
        val original=movie(fragmented=true,duration=25_540_515)
        val file=folder.newFile("dash.mp4").apply{writeBytes(original)}
        assertTrue(normalizeFragmentedMp4(file))
        val patched=file.readBytes()
        assertEquals(original.size,patched.size)
        assertArrayEquals("Only the three declared durations change.",movie(fragmented=true,duration=0),patched)
        // Running it again is harmless.
        assertTrue(normalizeFragmentedMp4(file))
        assertArrayEquals(patched,file.readBytes())
    }
    @Test fun regularFileIsLeftUntouched() {
        val original=movie(fragmented=false,duration=25_540_515)
        val file=folder.newFile("regular.mp4").apply{writeBytes(original)}
        assertFalse(normalizeFragmentedMp4(file))
        assertArrayEquals(original,file.readBytes())
    }
}
