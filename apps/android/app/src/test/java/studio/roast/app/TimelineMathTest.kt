package studio.roast.app

import org.junit.Assert.*
import org.junit.Test

class TimelineMathTest {
    @Test fun changingTheEndAloneExportsExactlyOneContiguousSection() {
        val before=DraftEdits(gains=MixGains(.7f,1.2f,.3f),trimEndMs=28_266,
            cuts=listOf(EditRange(0,28_266)),musicName="music.wav",loopMusic=true,captions=listOf(CaptionCue(500,1_000,"Your words")))
        val after=contiguousTrimEdits(before,TrimBounds(0,18_522),28_266)
        assertEquals(listOf(EditRange(0,18_522)),retainedRanges(28_266,after.trimStartMs,after.trimEndMs,after.cuts))
        assertEquals(before.gains,after.gains);assertEquals(before.musicName,after.musicName)
        assertEquals(before.loopMusic,after.loopMusic);assertEquals(before.captions,after.captions)
        assertTrue(after.cuts.isEmpty())
    }
    @Test fun bothEdgesClampAtTheOtherEdgeWithoutCreatingAnEmptyTrim() {
        val range=TrimBounds(3_000,18_522)
        assertEquals(TrimBounds(18_272,18_522),moveTrimEdge(range,TrimEdge.Start,40_000,28_266))
        assertEquals(TrimBounds(3_000,3_250),moveTrimEdge(range,TrimEdge.End,0,28_266))
        assertEquals(TrimBounds(0,18_522),moveTrimEdge(range,TrimEdge.Start,-5_000,28_266))
        assertEquals(TrimBounds(3_000,28_266),moveTrimEdge(range,TrimEdge.End,90_000,28_266))
    }
    @Test fun invalidLegacyBoundsStayInvalidUntilTheUserResetsOrCommitsAValidTrim() {
        val stored=TrimBounds(9_000,2_000)
        assertFalse(stored.validFor(28_266))
        assertEquals(TrimBounds(0,28_266),visibleTrimBounds(28_266,stored.startMs,stored.endMs))
        assertEquals(TrimBounds(9_000,2_000),stored)
        assertTrue(runCatching{contiguousTrimEdits(DraftEdits(trimEndMs=0),TrimBounds(0,0),28_266)}.isFailure)
        assertFalse(TrimBounds(0,100).validFor(100))
    }
    @Test fun pixelsAndMillisecondsUseTheSameOriginalCaptureTimeAxis() {
        val position=timelinePositionAt(180f,20f,320f,28_266)
        assertEquals(14_133L,position)
        assertEquals(180f,timelineXAt(position,20f,320f,28_266),.001f)
        assertEquals(0L,timelinePositionAt(-20f,20f,320f,28_266))
        assertEquals(28_266L,timelinePositionAt(600f,20f,320f,28_266))
    }
    @Test fun editedPlaybackMapsBackToOriginalTrimTimeWithoutMovingTheHandles() {
        val ranges=listOf(EditRange(3_000,18_522))
        assertEquals(3_000L,originalPositionAtEdited(0,ranges))
        assertEquals(13_000L,originalPositionAtEdited(10_000,ranges))
        assertEquals(18_522L,originalPositionAtEdited(90_000,ranges))
        assertEquals(0L,editedPositionAtOriginal(1_000,ranges))
        assertEquals(10_000L,editedPositionAtOriginal(13_000,ranges))
    }
    @Test fun rapidScrubbingKeepsOnlyTheLatestPendingFrameSeek() {
        val gate=LatestFrameSeekGate()
        val first=gate.request(0)!!
        assertNull(gate.request(200));assertNull(gate.request(500))
        val latest=gate.rendered(0)!!
        assertEquals(500L,latest.positionMs)
        assertNull(gate.timeout(first.id))
        assertNull(gate.rendered(200))
        assertNull(gate.request(900))
        assertEquals(900L,gate.rendered(500)!!.positionMs)
    }
    @Test fun stalledFrameSeeksAndCancellationCannotReviveObsoleteTargets() {
        val gate=LatestFrameSeekGate()
        val first=gate.request(5_000)!!
        gate.request(8_000);gate.request(2_000)
        val newest=gate.timeout(first.id)!!
        assertEquals(2_000L,newest.positionMs)
        gate.cancel()
        assertNull(gate.timeout(newest.id));assertNull(gate.rendered(2_000))
        assertEquals(1_000L,gate.request(1_000)!!.positionMs)
    }
}
