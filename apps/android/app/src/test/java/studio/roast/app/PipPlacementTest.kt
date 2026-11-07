package studio.roast.app

import org.junit.Assert.assertEquals
import org.junit.Test

class PipPlacementTest {
    @Test fun gesturesAccumulateWithoutReplacingOtherChoices() {
        val initial = PipPlacement(style = PipStyle.Cutout)
        val moved = initial.transformed(-.1f, .05f, 1.5f, 35f)
        assertEquals(.63f, moved.x, .0001f)
        assertEquals(.78f, moved.y, .0001f)
        assertEquals(1.5f, moved.scale, .0001f)
        assertEquals(35f, moved.rotation, .0001f)
        assertEquals(PipStyle.Cutout, moved.style)
    }
    @Test fun largeGesturesKeepCameraReachableAndScaleBounded() {
        val maximum = PipPlacement().transformed(100f, -100f, 100f, 725f)
        assertEquals(.96f, maximum.x, .0001f)
        assertEquals(.04f, maximum.y, .0001f)
        assertEquals(2.8f, maximum.scale, .0001f)
        assertEquals(5f, maximum.rotation, .0001f)
        val minimum = maximum.transformed(0f, 0f, .0001f, 0f)
        assertEquals(.45f, minimum.scale, .0001f)
    }
    @Test fun resetCanPreserveTheSelectedShape() {
        val selected = PipPlacement(style=PipStyle.Circle).transformed(.1f, .1f, 2f, 45f)
        val reset = PipPlacement(style=selected.style)
        assertEquals(PipStyle.Circle, reset.style)
        assertEquals(.73f, reset.x, .0001f)
        assertEquals(1f, reset.scale, .0001f)
        assertEquals(0f, reset.rotation, .0001f)
    }
}
