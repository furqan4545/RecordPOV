package studio.roast.app

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.os.SystemClock
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** A small, reusable blurred image fills the gaps; the actual video stays sharp and fully fitted. */
internal class SplitVideoBackdrop {
    private var image:Bitmap?=null
    private var source:Bitmap?=null
    private var aspect:Float?=null
    private var generation=0
    private var revision=0
    private var updatedAt=0L
    private val paint=Paint(Paint.FILTER_BITMAP_FLAG)
    private val shade=Paint().apply{color=Color.argb(88,0,0,0)}

    @Synchronized fun draw(canvas:Canvas,bitmap:Bitmap,rect:RectF,sourceAspect:Float?,frameRevision:Int) {
        if(bitmap.isRecycled||rect.isEmpty)return
        val now=SystemClock.elapsedRealtime()
        val replaced=source!==bitmap||aspect!=sourceAspect||image?.isRecycled!=false
        if(replaced||((generation!=bitmap.generationId||revision!=frameRevision)&&now-updatedAt>=200)) {
            val content=contentRect(bitmap,sourceAspect)
            val scale=min(1f,96f/max(content.width(),content.height()))
            val w=(content.width()*scale).roundToInt().coerceAtLeast(1)
            val h=(content.height()*scale).roundToInt().coerceAtLeast(1)
            val next=Bitmap.createBitmap(w,h,Bitmap.Config.ARGB_8888)
            Canvas(next).drawBitmap(bitmap,content,RectF(0f,0f,w.toFloat(),h.toFloat()),paint)
            val pixels=IntArray(w*h);next.getPixels(pixels,0,w,0,0,w,h)
            // Two small separable box passes approximate a soft blur without full-frame filtering.
            repeat(2){boxBlur(pixels,w,h,4)}
            next.setPixels(pixels,0,w,0,0,w,h)
            // A hardware Canvas may still retain the previous bitmap for a frame.
            // Let its native reference and GC release that tiny image safely.
            image=next;source=bitmap;aspect=sourceAspect
            generation=bitmap.generationId;revision=frameRevision;updatedAt=now
        }
        val background=image?:return
        val factor=max(rect.width()/background.width,rect.height()/background.height)
        val w=background.width*factor;val h=background.height*factor
        canvas.save();canvas.clipRect(rect)
        canvas.drawBitmap(background,null,RectF(rect.centerX()-w/2,rect.centerY()-h/2,rect.centerX()+w/2,rect.centerY()+h/2),paint)
        canvas.drawRect(rect,shade);canvas.restore()
    }

    companion object {
        fun contentRect(bitmap:Bitmap,aspect:Float?):Rect {
            if(aspect==null||!aspect.isFinite()||aspect<=0)return Rect(0,0,bitmap.width,bitmap.height)
            val width=min(bitmap.width.toFloat(),bitmap.height*aspect).roundToInt().coerceIn(1,bitmap.width)
            val height=min(bitmap.height.toFloat(),bitmap.width/aspect).roundToInt().coerceIn(1,bitmap.height)
            return Rect((bitmap.width-width)/2,(bitmap.height-height)/2,(bitmap.width+width)/2,(bitmap.height+height)/2)
        }
        private fun boxBlur(pixels:IntArray,width:Int,height:Int,radius:Int) {
            val temporary=IntArray(pixels.size)
            fun pass(input:IntArray,output:IntArray,horizontal:Boolean) {
                val lines=if(horizontal)height else width;val length=if(horizontal)width else height
                val count=radius*2+1
                for(line in 0 until lines) {
                    fun index(position:Int)=if(horizontal)line*width+position.coerceIn(0,length-1) else position.coerceIn(0,length-1)*width+line
                    var red=0;var green=0;var blue=0
                    for(offset in -radius..radius){val c=input[index(offset)];red+=Color.red(c);green+=Color.green(c);blue+=Color.blue(c)}
                    for(position in 0 until length) {
                        output[index(position)]=Color.rgb(red/count,green/count,blue/count)
                        val old=input[index(position-radius)];val next=input[index(position+radius+1)]
                        red+=Color.red(next)-Color.red(old);green+=Color.green(next)-Color.green(old);blue+=Color.blue(next)-Color.blue(old)
                    }
                }
            }
            pass(pixels,temporary,true);pass(temporary,pixels,false)
        }
    }
}
