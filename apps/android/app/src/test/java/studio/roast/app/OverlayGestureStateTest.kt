package studio.roast.app

import org.junit.Assert.*
import org.junit.Test

class OverlayGestureStateTest {
    @Test fun liftingOneFingerImmediatelyFreezesRotationAndRebasesTheDrag() {
        val gesture=OverlayGestureState()
        gesture.update(listOf(OverlayTouch(1,100f,100f)),1000f,1000f)
        val adding=gesture.update(listOf(OverlayTouch(1,100f,100f),OverlayTouch(2,200f,100f)),1000f,1000f)
        assertEquals(OverlayGestureDelta(),adding)
        val rotated=gesture.update(listOf(OverlayTouch(1,100f,100f),OverlayTouch(2,100f,200f)),1000f,1000f)
        assertEquals(31.5f,rotated.rotation,.001f)
        val lifting=gesture.update(listOf(OverlayTouch(2,100f,200f)),1000f,1000f)
        assertEquals(OverlayGestureDelta(),lifting)
        val drag=gesture.update(listOf(OverlayTouch(2,200f,250f)),1000f,1000f)
        assertEquals(.065f,drag.dx,.00001f);assertEquals(.0325f,drag.dy,.00001f)
        assertEquals(0f,drag.rotation,0f);assertEquals(1f,drag.zoom,0f)
    }

    @Test fun rotationCrossingTheAngleBoundaryStaysSmallAndPinchIsDamped() {
        val gesture=OverlayGestureState()
        gesture.update(listOf(OverlayTouch(1,0f,0f),OverlayTouch(2,-100f,1f)),1000f,1000f)
        val crossed=gesture.update(listOf(OverlayTouch(1,0f,0f),OverlayTouch(2,-100f,-1f)),1000f,1000f)
        assertTrue(crossed.rotation>0f&&crossed.rotation<1f)
        val zoom=gesture.update(listOf(OverlayTouch(1,0f,0f),OverlayTouch(2,-200f,-2f)),1000f,1000f)
        assertTrue(zoom.zoom>1f&&zoom.zoom<1.6f)
    }

    @Test fun aNewGestureOrReplacedFingerNeverInheritsAnOldAnchor() {
        val gesture=OverlayGestureState()
        gesture.update(listOf(OverlayTouch(1,0f,0f),OverlayTouch(2,100f,0f)),100f,100f)
        assertEquals(OverlayGestureDelta(),gesture.update(listOf(OverlayTouch(3,50f,50f)),100f,100f))
        gesture.reset()
        assertEquals(OverlayGestureDelta(),gesture.update(listOf(OverlayTouch(1,90f,90f)),100f,100f))
        assertEquals(OverlayGestureDelta(),gesture.update(emptyList(),100f,100f))
    }

    @Test fun fingerCrossingsAndThreeFingerChangesRebaseWithoutASuddenTurn() {
        val gesture=OverlayGestureState()
        gesture.update(listOf(OverlayTouch(1,0f,0f),OverlayTouch(2,100f,0f)),1000f,1000f)
        val crossing=gesture.update(listOf(OverlayTouch(1,100f,0f),OverlayTouch(2,0f,0f)),1000f,1000f)
        assertEquals(0f,crossing.rotation,0f);assertEquals(1f,crossing.zoom,0f)
        assertEquals(OverlayGestureDelta(),gesture.update(listOf(OverlayTouch(1,100f,0f),OverlayTouch(2,0f,0f),OverlayTouch(3,50f,50f)),1000f,1000f))
        assertEquals(OverlayGestureDelta(),gesture.update(listOf(OverlayTouch(1,100f,0f),OverlayTouch(2,0f,0f)),1000f,1000f))
        val slow=gesture.update(listOf(OverlayTouch(1,100f,0f),OverlayTouch(2,0f,-10f)),1000f,1000f)
        assertTrue(slow.rotation>0f&&slow.rotation<3f)
    }

    @Test fun rotatedCameraBoundsStayReachableWithoutChangingTheChosenSize() {
        val initial=PipPlacement(x=1f,y=0f,scale=1.5f,rotation=45f,style=PipStyle.Rounded)
        val adjusted=PipGeometry.keepVisible(initial,720f,1280f)
        assertTrue(adjusted.x<1f&&adjusted.y>0f)
        assertEquals(initial.scale,adjusted.scale,0f);assertEquals(initial.rotation,adjusted.rotation,0f)
        assertTrue(PipGeometry.contains(adjusted.x*720f,adjusted.y*1280f,720f,1280f,adjusted))
        assertFalse(PipGeometry.contains(0f,0f,720f,1280f,adjusted))
    }
}
