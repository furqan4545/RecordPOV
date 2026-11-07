package studio.roast.app

import org.junit.Assert.*
import org.junit.Test

class StageGeometryTest {
    @Test fun splitSourceEdgesRemainInsideEveryPaneWithoutChangingAspect() {
        for(fraction in listOf(.2f,.43f,.7f,.8f))for((sourceWidth,sourceHeight) in listOf(1080f to 1920f,1920f to 1080f,1000f to 1000f,2560f to 1080f)) {
            val pane=StageGeometry.sourceTop(720f,1280f,StageLayout(template=StageTemplate.Split).splitAt(fraction))
            val fitted=StageGeometry.sourceFit(sourceWidth,sourceHeight,pane)
            assertTrue(fitted.left>=pane.left-.001f&&fitted.top>=pane.top-.001f)
            assertTrue(fitted.right<=pane.right+.001f&&fitted.bottom<=pane.bottom+.001f)
            assertEquals(sourceWidth/sourceHeight,fitted.width/fitted.height,.0001f)
            assertTrue(kotlin.math.abs(fitted.width-pane.width)<.001f||kotlin.math.abs(fitted.height-pane.height)<.001f)
        }
    }

    @Test fun layoutChangesReturnCutoutToRoundedAndPreserveExplicitShapes() {
        assertEquals(PipStyle.Rounded,PipPlacement(style=PipStyle.Cutout).forLayoutChange().style)
        for(style in listOf(PipStyle.Circle,PipStyle.Rounded,PipStyle.Square)) {
            val before=PipPlacement(style=style,x=.4f,scale=1.4f,rotation=22f)
            assertEquals(before,before.forLayoutChange())
        }
    }

    @Test fun splitDividerAlwaysPartitionsTheSamePreviewAndExportCanvas() {
        for(fraction in listOf(-1f,.2f,.7f,.8f,2f)) {
            val layout=StageLayout(template=StageTemplate.Split).splitAt(fraction)
            for((w,h) in listOf(360f to 640f,720f to 1280f)) {
                val top=StageGeometry.sourceTop(w,h,layout);val bottom=StageGeometry.cameraBottom(w,h,layout)
                assertEquals(top.bottom,bottom.top,0f)
                assertEquals(h,bottom.bottom,.001f)
                assertEquals(w,top.width,0f);assertEquals(w,bottom.width,0f)
                assertTrue(top.height/h>=.1999f&&top.height/h<=.8001f)
            }
        }
    }
    @Test fun sourceOverlayRetainsSourceAspectWhileMovingAndResizing() {
        for(aspect in listOf(9f/16f,16f/9f,1f)) {
            val initial=StageGeometry.sourceOverlay(720f,1280f,aspect,SourceOverlayPlacement())
            val moved=SourceOverlayPlacement().transformed(-.2f,.1f,1.5f)
            val changed=StageGeometry.sourceOverlay(720f,1280f,aspect,moved)
            assertEquals(aspect,initial.width/initial.height,.0001f)
            assertEquals(aspect,changed.width/changed.height,.0001f)
            assertEquals(720f*moved.x,changed.left+changed.width/2,.001f)
            assertEquals(1280f*moved.y,changed.top+changed.height/2,.001f)
            assertTrue(changed.width>initial.width)
        }
    }
}
