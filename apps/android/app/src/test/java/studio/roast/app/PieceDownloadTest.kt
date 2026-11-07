package studio.roast.app

import org.junit.Assert.*
import org.junit.Test

class PieceDownloadTest {
    private val mebibytes10=10L*1024*1024

    @Test fun smallFileIsOnePieceCoveringEveryByte() {
        assertEquals(mebibytes10,PieceDownload.PIECE_SIZE)
        assertEquals(listOf(0L..6_890_573L),PieceDownload.pieceRanges(6_890_574))
    }
    @Test fun largeFileIsSplitIntoTenMiBPiecesWithAShorterLastOne() {
        val ranges=PieceDownload.pieceRanges(106_424_608)
        assertEquals(11,ranges.size)
        assertEquals(0L..10_485_759L,ranges.first())
        assertEquals(10_485_760L..20_971_519L,ranges[1])
        assertEquals(104_857_600L..106_424_607L,ranges.last())
        ranges.zipWithNext().forEach{(previous,next)->assertEquals(previous.last+1,next.first)}
        assertTrue(ranges.dropLast(1).all{it.last-it.first+1==mebibytes10})
        assertEquals(106_424_608L,ranges.sumOf{it.last-it.first+1})
        assertTrue(PieceDownload.pieceRanges(0).isEmpty())
    }
    @Test fun totalSizeIsReadFromClenOrAContentRange() {
        assertEquals(106_424_608L,PieceDownload.declaredLength("https://rr1---sn.test.googlevideo.com/videoplayback?itag=137&clen=106424608&dur=300"))
        assertNull(PieceDownload.declaredLength("https://rr1---sn.test.googlevideo.com/videoplayback?itag=137"))
        assertEquals(6_890_574L,PieceDownload.contentRangeTotal("bytes 0-0/6890574"))
        assertNull(PieceDownload.contentRangeTotal("bytes 0-0/*"))
        assertNull(PieceDownload.contentRangeTotal(null))
    }
    @Test fun stalledDownloadIsRetriedAfterThirtySecondsAndFailsAfterFiveAttempts() {
        val start=1_000_000L
        assertEquals(PieceDownload.StallDecision.Keep,PieceDownload.stallDecision(start,start+29_900,1))
        assertEquals(PieceDownload.StallDecision.Keep,PieceDownload.stallDecision(start,start+29_900,5))
        for(attempts in 1..4)assertEquals("$attempts",PieceDownload.StallDecision.Retry,PieceDownload.stallDecision(start,start+30_000,attempts))
        assertEquals(PieceDownload.StallDecision.Fail,PieceDownload.stallDecision(start,start+30_000,5))
        assertEquals(5_000L,PieceDownload.STALL_CHECK_MS)
        assertEquals(4,PieceDownload.PARALLEL_PIECES)
    }
    @Test fun progressIsBytesAcrossPiecesOverTheTotalAndNeverAboveOneHundredPercent() {
        assertEquals(0.5,PieceDownload.progress(50,100),0.0)
        assertEquals(1.0,PieceDownload.progress(150,100),0.0)
        assertEquals(0.0,PieceDownload.progress(10,0),0.0)
    }
    @Test fun aPieceTransferCountsItsTotalOnceAndARestartGivesItsBytesBack() {
        val budget=ImportByteBudget(100)
        budget.reserve(60)
        assertThrows(IllegalArgumentException::class.java){budget.reserve(41)}
        budget.add(40);budget.release(40);budget.add(40)
        assertThrows(IllegalArgumentException::class.java){budget.add(1)}
    }
}
