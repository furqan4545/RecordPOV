package studio.roast.app

import kotlin.math.floor
import kotlin.math.roundToInt

/** Pixel-center bilinear mask scaling. Input pixels are straight ARGB, as returned by Bitmap.getPixels. */
class SoftMaskSampler(val maskWidth:Int,val maskHeight:Int,val outputWidth:Int,val outputHeight:Int) {
    private val left:IntArray
    private val right:IntArray
    private val horizontal:FloatArray
    private val top:IntArray
    private val bottom:IntArray
    private val vertical:FloatArray

    init {
        require(maskWidth>0&&maskHeight>0&&outputWidth>0&&outputHeight>0)
        left=IntArray(outputWidth);right=IntArray(outputWidth);horizontal=FloatArray(outputWidth)
        top=IntArray(outputHeight);bottom=IntArray(outputHeight);vertical=FloatArray(outputHeight)
        for(x in 0 until outputWidth) {
            val coordinate=((x+.5f)*maskWidth/outputWidth-.5f).coerceIn(0f,(maskWidth-1).toFloat())
            left[x]=floor(coordinate).toInt();right[x]=(left[x]+1).coerceAtMost(maskWidth-1)
            horizontal[x]=coordinate-left[x]
        }
        for(y in 0 until outputHeight) {
            val coordinate=((y+.5f)*maskHeight/outputHeight-.5f).coerceIn(0f,(maskHeight-1).toFloat())
            top[y]=floor(coordinate).toInt();bottom[y]=(top[y]+1).coerceAtMost(maskHeight-1)
            vertical[y]=coordinate-top[y]
        }
    }

    fun matches(maskWidth:Int,maskHeight:Int,outputWidth:Int,outputHeight:Int)=
        this.maskWidth==maskWidth&&this.maskHeight==maskHeight&&this.outputWidth==outputWidth&&this.outputHeight==outputHeight

    /** No threshold, contrast remap, extra mirror, or temporal averaging is applied. */
    fun applyTo(pixels:IntArray,confidence:FloatArray) {
        require(pixels.size==outputWidth*outputHeight&&confidence.size==maskWidth*maskHeight)
        for(y in 0 until outputHeight) {
            val rowA=top[y]*maskWidth
            val rowB=bottom[y]*maskWidth
            val wy=vertical[y]
            for(x in 0 until outputWidth) {
                val wx=horizontal[x]
                val a=valid(confidence[rowA+left[x]])
                val b=valid(confidence[rowA+right[x]])
                val c=valid(confidence[rowB+left[x]])
                val d=valid(confidence[rowB+right[x]])
                val upper=a+(b-a)*wx
                val lower=c+(d-c)*wx
                val alpha=(upper+(lower-upper)*wy).coerceIn(0f,1f)
                val index=y*outputWidth+x
                val original=pixels[index]
                val masked=((original ushr 24)*alpha).roundToInt().coerceIn(0,255)
                // RGB stays straight here. Bitmap.createBitmap performs premultiplication once.
                pixels[index]=(original and 0x00ffffff) or (masked shl 24)
            }
        }
    }

    private fun valid(value:Float)=if(value.isFinite())value.coerceIn(0f,1f)else 0f
}
