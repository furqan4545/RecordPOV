package studio.roast.app

import org.junit.Assert.*
import org.junit.Test

class BigAtBottomTest {
    private val start=CameraArrangement(
        PipPlacement(x=.3f,y=.4f,scale=1.1f,rotation=20f,style=PipStyle.Cutout,framingScale=.7f),
        fullScreenCamera=false,layout=StageLayout(template=StageTemplate.CameraMain,splitFraction=.5f))

    @Test fun shortcutPutsYouBigAtTheBottomAndTheSecondTapRestoresExactly() {
        val (on,saved)=BigAtBottom.toggle(start,null,null,null)
        assertEquals(start,saved)
        assertEquals(StageTemplate.Pip,on.layout.template)
        assertFalse(on.fullScreenCamera)
        assertEquals(PipStyle.Cutout,on.placement.style)
        assertEquals(2.5f,on.placement.scale,0f)
        assertEquals(.5f,on.placement.x,0f)
        assertEquals(1f,on.placement.framingScale,0f)
        assertEquals(0f,on.placement.rotation,0f)
        // Before the first camera picture arrives, the frame's bottom rests on the video's bottom edge.
        assertEquals(1f-720f*.34f*1.32f*2.5f/2f/1280f,on.placement.y,.0001f)
        val (off,cleared)=BigAtBottom.toggle(on,saved,null,null)
        assertNull(cleared)
        assertEquals("The second tap restores the camera exactly, Cutout and Stage included.",start,off)
    }

    @Test fun theVisibleCameraRestsOnTheBottomEdge() {
        // A landscape camera is shorter than its Cutout frame, so it sits lower to touch the bottom.
        val (on,_)=BigAtBottom.toggle(start,null,640f,480f)
        val visibleHeight=720f*.34f*480f/640f
        assertEquals(1f-visibleHeight*2.5f/2f/1280f,on.placement.y,.0001f)
        assertEquals(1280f,on.placement.y*1280f+visibleHeight*2.5f/2f,.01f)
    }

    @Test fun aLayoutOrFullScreenChangeEndsTheShortcutAndAMoveKeepsIt() {
        val (on,saved)=BigAtBottom.toggle(start,null,null,null)
        val moved=on.copy(placement=PipGeometry.keepVisible(on.placement.transformed(-.1f,0f,1.1f,0f),720f,1280f))
        assertEquals("Moving yourself keeps the way back.",saved,BigAtBottom.afterChange(saved,on,moved))
        val stage=moved.copy(layout=moved.layout.copy(template=StageTemplate.CameraMain))
        assertNull(BigAtBottom.afterChange(saved,moved,stage))
        assertNull(BigAtBottom.afterChange(saved,moved,moved.copy(fullScreenCamera=true)))
    }
}
