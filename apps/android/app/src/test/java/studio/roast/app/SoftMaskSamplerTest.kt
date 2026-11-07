package studio.roast.app

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class SoftMaskSamplerTest {
    private fun alphas(pixels:IntArray)=IntArray(pixels.size){pixels[it] ushr 24}
    private fun opaque(size:Int)=IntArray(size){0xffaabbcc.toInt()}

    @Test fun interpolatesInBothAxesInsteadOfNearestNeighbor() {
        val pixels=opaque(16)
        SoftMaskSampler(2,2,4,4).applyTo(pixels,floatArrayOf(0f,1f,1f,0f))
        assertEquals(96,pixels[1*4+1] ushr 24)
        assertEquals(159,pixels[1*4+2] ushr 24)
    }

    @Test fun pixelCentersHaveNoHalfPixelShiftAndEqualSizesAreIdentity() {
        val pixels=opaque(4)
        SoftMaskSampler(2,1,4,1).applyTo(pixels,floatArrayOf(0f,1f))
        assertArrayEquals(intArrayOf(0,64,191,255),alphas(pixels))
        val equal=opaque(6)
        SoftMaskSampler(2,3,2,3).applyTo(equal,floatArrayOf(0f,.2f,.4f,.6f,.8f,1f))
        assertArrayEquals(intArrayOf(0,51,102,153,204,255),alphas(equal))
    }

    @Test fun portraitAndLandscapeMasksKeepTheirAlreadyOrientedCorners() {
        val portrait=opaque(4*6)
        SoftMaskSampler(2,3,4,6).applyTo(portrait,floatArrayOf(1f,0f,.25f,.5f,0f,.75f))
        assertEquals(255,portrait[0] ushr 24);assertEquals(0,portrait[3] ushr 24)
        assertEquals(0,portrait[5*4] ushr 24);assertEquals(191,portrait[5*4+3] ushr 24)
        val landscape=opaque(6*4)
        SoftMaskSampler(3,2,6,4).applyTo(landscape,floatArrayOf(0f,.25f,1f,.75f,.5f,0f))
        assertEquals(0,landscape[0] ushr 24);assertEquals(255,landscape[5] ushr 24)
        assertEquals(191,landscape[3*6] ushr 24);assertEquals(0,landscape[3*6+5] ushr 24)
    }

    @Test fun preservesLowAndHighConfidenceHairAlphaWithoutContrastHardening() {
        val pixels=opaque(6)
        SoftMaskSampler(6,1,6,1).applyTo(pixels,floatArrayOf(.02f,.08f,.12f,.5f,.88f,.98f))
        assertArrayEquals(intArrayOf(5,20,31,128,224,250),alphas(pixels))
    }

    @Test fun multipliesExistingAlphaOnceWithoutDarkeningStraightRgb() {
        val pixels=intArrayOf(0x80123456.toInt(),0x00123456)
        SoftMaskSampler(1,1,2,1).applyTo(pixels,floatArrayOf(.5f))
        assertEquals(64,pixels[0] ushr 24);assertEquals(0,pixels[1] ushr 24)
        assertEquals(0x00123456,pixels[0] and 0x00ffffff)
        assertEquals(0x00123456,pixels[1] and 0x00ffffff)
    }

    @Test fun clampsInvalidConfidenceAndSupportsSingleColumnMasks() {
        val pixels=opaque(6)
        SoftMaskSampler(1,6,1,6).applyTo(pixels,floatArrayOf(-.1f,1.1f,Float.NaN,Float.POSITIVE_INFINITY,.5f,1f))
        assertArrayEquals(intArrayOf(0,255,0,0,128,255),alphas(pixels))
    }
}
