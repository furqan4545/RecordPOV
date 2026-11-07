package studio.roast.app

import kotlin.math.atan2
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.ln

data class OverlayTouch(val id:Long,val x:Float,val y:Float)
data class OverlayGestureDelta(val dx:Float=0f,val dy:Float=0f,val zoom:Float=1f,val rotation:Float=0f)

/** Incremental canvas-space input. Changing fingers rebases instead of reusing a stale rotation. */
class OverlayGestureState {
    private var previous=emptyList<OverlayTouch>()

    fun update(touches:List<OverlayTouch>,width:Float,height:Float):OverlayGestureDelta {
        val current=touches.filter{it.x.isFinite()&&it.y.isFinite()}.sortedBy{it.id}
        val old=previous
        previous=current
        if(!width.isFinite()||!height.isFinite()||width<=0f||height<=0f||current.size !in 1..2||old.map{it.id}!=current.map{it.id})return OverlayGestureDelta()
        val dx=(current.map{it.x}.average()-old.map{it.x}.average()).toFloat()/width*DRAG_SENSITIVITY
        val dy=(current.map{it.y}.average()-old.map{it.y}.average()).toFloat()/height*DRAG_SENSITIVITY
        if(current.size==1)return OverlayGestureDelta(dx,dy)
        val oldDistance=hypot(old[1].x-old[0].x,old[1].y-old[0].y)
        val newDistance=hypot(current[1].x-current[0].x,current[1].y-current[0].y)
        val zoom=if(oldDistance.isFinite()&&newDistance.isFinite()&&oldDistance>=2f&&newDistance>=2f)
            exp(ln(newDistance/oldDistance)*PINCH_SENSITIVITY).takeIf{it.isFinite()&&it>0}?:1f else 1f
        val oldAngle=atan2(old[1].y-old[0].y,old[1].x-old[0].x)
        val newAngle=atan2(current[1].y-current[0].y,current[1].x-current[0].x)
        var radians=newAngle-oldAngle
        while(radians>Math.PI)radians-=(2*Math.PI).toFloat()
        while(radians< -Math.PI)radians+=(2*Math.PI).toFloat()
        // A finger crossing changes the measured angle abruptly. Rebase this
        // event so that one crossing cannot fling the camera around.
        if(kotlin.math.abs(radians)>Math.PI/2+.0001)return OverlayGestureDelta(dx,dy)
        val degrees=if(oldDistance>=2f&&newDistance>=2f)Math.toDegrees(radians.toDouble()).toFloat()*ROTATION_SENSITIVITY else 0f
        return OverlayGestureDelta(dx,dy,zoom,degrees)
    }

    fun reset(){previous=emptyList()}

    companion object {
        const val DRAG_SENSITIVITY=.65f
        const val ROTATION_SENSITIVITY=.35f
        const val PINCH_SENSITIVITY=.6f
    }
}
