package studio.roast.app

import org.junit.Assert.assertEquals
import org.junit.Test

class PipPlacementTest {
    @Test fun gesturesAccumulateWithoutReplacingOtherChoices() {
        val initial = PipPlacement(style = PipStyle.Cutout)
        val moved = initial.transformed(-.1f, .05f, 1.5f, 35f)
        assertEquals(.63f, moved.x, .0001f)
        assertEquals(.78f, moved.y, .0001f)
        assertEquals(PipPlacement.DEFAULT_SCALE * 1.5f, moved.scale, .0001f)
        assertEquals(35f, moved.rotation, .0001f)
        assertEquals(PipStyle.Cutout, moved.style)
    }
    @Test fun largeGesturesKeepCameraReachableAndScaleBounded() {
        val maximum = PipPlacement().transformed(100f, -100f, 100f, 725f)
        assertEquals(1f, maximum.x, .0001f)
        assertEquals(0f, maximum.y, .0001f)
        assertEquals(2.8f, maximum.scale, .0001f)
        assertEquals(5f, maximum.rotation, .0001f)
        val minimum = maximum.transformed(0f, 0f, .0001f, 0f)
        assertEquals(.45f, minimum.scale, .0001f)
    }
    @Test fun defaultCameraFrameIsAboutHalfTheVideoWidth() {
        assertEquals(1.4f, PipPlacement().scale, 0f)
        assertEquals(.476f, .34f * PipPlacement().scale, .0001f)
        val (width, _) = PipGeometry.gestureSize(720f, PipPlacement())
        assertEquals(720f * .476f, width, .01f)
    }
    @Test fun resetCanPreserveTheSelectedShape() {
        val selected = PipPlacement(style=PipStyle.Circle).transformed(.1f, .1f, 2f, 45f)
        val reset = PipPlacement(style=selected.style)
        assertEquals(PipStyle.Circle, reset.style)
        assertEquals(.73f, reset.x, .0001f)
        assertEquals(PipPlacement.DEFAULT_SCALE, reset.scale, .0001f)
        assertEquals(0f, reset.rotation, .0001f)
    }
}
