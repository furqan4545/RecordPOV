package studio.roast.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PipGeometryTest {
    private val regularStyles=listOf(PipStyle.Rounded,PipStyle.Circle,PipStyle.Square)
    private val cameraSizes=listOf(480f to 640f,640f to 480f,1080f to 1920f,1920f to 1080f)

    @Test fun squareFillsPortraitWithoutPadding() {
        val result=PipGeometry.cameraRect(480f,640f,200f,200f,PipStyle.Square)
        assertEquals(200f,result.width,.001f)
        assertEquals(266.6667f,result.height,.001f)
        assertEquals(0f,result.left,.001f)
        assertEquals(-33.3333f,result.top,.001f)
    }

    @Test fun everyRegularShapeCoversAllEdgesForPortraitAndLandscapeFeeds() {
        for(style in regularStyles)for((width,height) in cameraSizes)for(framing in listOf(.55f,1f,1.7f,2.5f)) {
            val viewportHeight=PipGeometry.heightForWidth(200f,style)
            val result=PipGeometry.cameraRect(width,height,200f,viewportHeight,style,framing)
            assertTrue("$style leaves horizontal padding for $width x $height",result.left<=.001f&&result.right>=199.999f)
            assertTrue("$style leaves vertical padding for $width x $height",result.top<=.001f&&result.bottom>=viewportHeight-.001f)
            assertEquals(100f,result.left+result.width/2,.001f)
            assertEquals(viewportHeight/2,result.top+result.height/2,.001f)
            assertEquals(width/height,result.width/result.height,.0001f)
            if(framing<=1f)assertTrue(kotlin.math.abs(result.width-200f)<.001f||kotlin.math.abs(result.height-viewportHeight)<.001f)
        }
    }

    @Test fun cutoutRetainsTheFullPortraitAndLandscapeWithTransparentMargins() {
        for((width,height) in cameraSizes) {
            val result=PipGeometry.cameraRect(width,height,200f,264f,PipStyle.Cutout)
            assertTrue(result.left>=-.001f&&result.top>=-.001f&&result.right<=200.001f&&result.bottom<=264.001f)
            assertTrue(kotlin.math.abs(result.width-200f)<.001f||kotlin.math.abs(result.height-264f)<.001f)
            assertEquals(width/height,result.width/result.height,.0001f)
        }
    }

    @Test fun regularZoomOutStopsAtFillAndZoomInStopsAtTheMaximum() {
        for(style in regularStyles) {
            assertEquals(1f,PipGeometry.minimumFraming(style),0f)
            val filled=PipGeometry.cameraRect(480f,640f,200f,200f,style)
            for(scale in listOf(-1f,0f,.55f,1f,Float.NaN,Float.POSITIVE_INFINITY)) {
                assertEquals(filled,PipGeometry.cameraRect(480f,640f,200f,200f,style,scale))
                assertEquals(1f,PipGeometry.effectiveFraming(style,scale),0f)
            }
            val maximum=PipGeometry.cameraRect(480f,640f,200f,200f,style,2.5f)
            assertEquals(maximum,PipGeometry.cameraRect(480f,640f,200f,200f,style,10f))
        }
    }

    @Test fun cutoutAllowsWiderFramingAndClampsItsOwnZoomRange() {
        assertEquals(.55f,PipGeometry.minimumFraming(PipStyle.Cutout),0f)
        val wide=PipGeometry.cameraRect(480f,640f,200f,264f,PipStyle.Cutout,-1f)
        val close=PipGeometry.cameraRect(480f,640f,200f,264f,PipStyle.Cutout,10f)
        assertEquals(108.9f,wide.width,.001f)
        assertEquals(145.2f,wide.height,.001f)
        assertEquals(495f,close.width,.001f)
        assertEquals(660f,close.height,.001f)
    }

    @Test fun changingShapePreservesTheStoredWiderCutoutChoice() {
        val cutout=PipPlacement(style=PipStyle.Cutout,framingScale=.7f)
        val circle=cutout.copy(style=PipStyle.Circle)
        assertEquals(.7f,circle.framingScale,0f)
        assertEquals(1f,PipGeometry.effectiveFraming(circle.style,circle.framingScale),0f)
        val restored=circle.copy(style=PipStyle.Cutout)
        assertEquals(.7f,PipGeometry.effectiveFraming(restored.style,restored.framingScale),0f)
    }

    @Test fun resetChangesOnlyCameraFraming() {
        val outer=PipPlacement(.2f,.6f,1.8f,35f,PipStyle.Circle,2f)
        val reset=outer.copy(framingScale=1f)
        assertEquals(outer.x,reset.x,0f);assertEquals(outer.y,reset.y,0f)
        assertEquals(outer.scale,reset.scale,0f);assertEquals(outer.rotation,reset.rotation,0f)
        assertEquals(outer.style,reset.style)
        assertEquals(1f,reset.framingScale,0f)
    }
    @Test fun outerManipulationPreservesTheChosenFramingScale() {
        val moved=PipPlacement(framingScale=.75f).transformed(.1f,-.1f,1.5f,45f)
        assertEquals(.75f,moved.framingScale,0f)
    }
}
