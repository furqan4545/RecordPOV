package studio.roast.app

import kotlin.math.max
import kotlin.math.min
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

data class CameraFramingRect(val left:Float,val top:Float,val width:Float,val height:Float) {
    val right:Float get()=left+width
    val bottom:Float get()=top+height
}

/** Pure geometry shared by the live camera preview and the encoded frame. */
object PipGeometry {
    const val MIN_CUTOUT_FRAMING=.55f
    const val MAX_FRAMING=2.5f
    fun heightForWidth(width:Float,style:PipStyle):Float =
        if(style==PipStyle.Circle||style==PipStyle.Square)width else width*1.32f

    fun minimumFraming(style:PipStyle):Float = if(style==PipStyle.Cutout)MIN_CUTOUT_FRAMING else 1f

    /** Preserve the stored Cutout choice while regular shapes always cover their bounds. */
    fun effectiveFraming(style:PipStyle,storedScale:Float):Float =
        if(storedScale.isFinite())storedScale.coerceIn(minimumFraming(style),MAX_FRAMING)else 1f

    fun contains(x:Float,y:Float,width:Float,height:Float,placement:PipPlacement):Boolean {
        val angle=Math.toRadians(-placement.rotation.toDouble())
        val dx=x-width*placement.x;val dy=y-height*placement.y
        val localX=dx*cos(angle)-dy*sin(angle);val localY=dx*sin(angle)+dy*cos(angle)
        val w=width*.34f*placement.scale;val h=heightForWidth(w,placement.style)
        return abs(localX)<=maxOf(22f,w/2)&&abs(localY)<=maxOf(22f,h/2)
    }

    fun keepVisible(placement:PipPlacement,width:Float,height:Float):PipPlacement {
        if(width<=0f||height<=0f)return placement
        val angle=Math.toRadians(placement.rotation.toDouble())
        val w=width*.34f*placement.scale;val h=heightForWidth(w,placement.style)
        val halfX=((abs(cos(angle))*w+abs(sin(angle))*h)/2/width).toFloat().coerceAtMost(.5f)
        val halfY=((abs(sin(angle))*w+abs(cos(angle))*h)/2/height).toFloat().coerceAtMost(.5f)
        return placement.copy(x=placement.x.coerceIn(halfX,1-halfX),y=placement.y.coerceIn(halfY,1-halfY))
    }

    fun cameraRect(sourceWidth:Float,sourceHeight:Float,viewportWidth:Float,viewportHeight:Float,
                   style:PipStyle,framingScale:Float=1f):CameraFramingRect {
        require(sourceWidth>0&&sourceHeight>0&&viewportWidth>0&&viewportHeight>0)
        val scale=if(style==PipStyle.Cutout)min(viewportWidth/sourceWidth,viewportHeight/sourceHeight)
            else max(viewportWidth/sourceWidth,viewportHeight/sourceHeight)
        val framing=effectiveFraming(style,framingScale)
        val width=sourceWidth*scale*framing
        val height=sourceHeight*scale*framing
        return CameraFramingRect((viewportWidth-width)/2,(viewportHeight-height)/2,width,height)
    }
}
