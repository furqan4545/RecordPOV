package studio.roast.app

enum class StageTemplate(val label:String,val shortLabel:String) {
    Pip("Camera","Camera"),Split("Split","Split"),CameraMain("You on stage","Stage")
}
data class SourceOverlayPlacement(val x:Float=.76f,val y:Float=.22f,val scale:Float=1f) {
    fun transformed(dx:Float,dy:Float,zoom:Float)=copy(x=(x+dx).coerceIn(.05f,.95f),y=(y+dy).coerceIn(.05f,.95f),scale=(scale*zoom).coerceIn(.5f,2.5f))
}
data class StageLayout(val template:StageTemplate=StageTemplate.Pip,val splitFraction:Float=.7f,
                       val sourceOverlay:SourceOverlayPlacement=SourceOverlayPlacement()) {
    fun splitAt(fraction:Float)=copy(splitFraction=fraction.coerceIn(.2f,.8f))
}
object StageGeometry {
    fun sourceFit(sourceWidth:Float,sourceHeight:Float,viewport:CameraFramingRect):CameraFramingRect {
        require(sourceWidth>0&&sourceHeight>0&&viewport.width>0&&viewport.height>0)
        val scale=minOf(viewport.width/sourceWidth,viewport.height/sourceHeight)
        val width=sourceWidth*scale;val height=sourceHeight*scale
        return CameraFramingRect(viewport.left+(viewport.width-width)/2,viewport.top+(viewport.height-height)/2,width,height)
    }
    fun sourceTop(width:Float,height:Float,layout:StageLayout)=CameraFramingRect(0f,0f,width,height*layout.splitFraction.coerceIn(.2f,.8f))
    fun cameraBottom(width:Float,height:Float,layout:StageLayout):CameraFramingRect {
        val top=height*layout.splitFraction.coerceIn(.2f,.8f)
        return CameraFramingRect(0f,top,width,height-top)
    }
    fun sourceOverlay(width:Float,height:Float,aspect:Float,placement:SourceOverlayPlacement):CameraFramingRect {
        val ratio=aspect.takeIf{it.isFinite()&&it>0}?:9f/16f
        val w=minOf(width*.34f*placement.scale,height*.75f*ratio)
        val h=w/ratio
        return CameraFramingRect(width*placement.x-w/2,height*placement.y-h/2,w,h)
    }
}

/** Layout changes never overwrite an explicit frame choice with Square. */
fun PipPlacement.forLayoutChange():PipPlacement=if(style==PipStyle.Cutout)copy(style=PipStyle.Rounded)else this

/** Everything the "big at the bottom" shortcut changes, so a second tap can put it all back. */
data class CameraArrangement(val placement:PipPlacement,val fullScreenCamera:Boolean,val layout:StageLayout)

/**
 * The "big at the bottom" shortcut: Camera layout, Cutout, the largest size, centered with the visible
 * camera resting on the video's bottom edge. While it is on, the arrangement from before is kept; tapping
 * again restores exactly that. A different layout or full screen ends it; moving or resizing keeps it.
 */
object BigAtBottom {
    const val SCALE=2.5f

    /** Returns the new arrangement and what to keep for the way back (null once it is off). */
    fun toggle(current:CameraArrangement,saved:CameraArrangement?,cameraWidth:Float?,cameraHeight:Float?):Pair<CameraArrangement,CameraArrangement?> {
        if(saved!=null)return saved to null
        val next=CameraArrangement(placement(current.placement,cameraWidth,cameraHeight),fullScreenCamera=false,
            layout=current.layout.copy(template=StageTemplate.Pip))
        return next to current
    }

    /** y puts the bottom of the camera you can see on the bottom edge of the 720x1280 video, at framing 1. */
    fun placement(current:PipPlacement,cameraWidth:Float?,cameraHeight:Float?,canvasWidth:Float=720f,canvasHeight:Float=1280f):PipPlacement {
        val frameWidth=canvasWidth*.34f
        val frameHeight=PipGeometry.heightForWidth(frameWidth,PipStyle.Cutout)
        val visibleHeight=if(cameraWidth!=null&&cameraHeight!=null)
            PipGeometry.visibleSize(cameraWidth,cameraHeight,frameWidth,frameHeight,PipStyle.Cutout,1f).height else frameHeight
        return current.copy(style=PipStyle.Cutout,rotation=0f,framingScale=1f,scale=SCALE,x=.5f,
            y=1f-visibleHeight*SCALE/2f/canvasHeight)
    }

    /** What to keep for the way back after a change from [before] to [after]. */
    fun afterChange(saved:CameraArrangement?,before:CameraArrangement,after:CameraArrangement):CameraArrangement? =
        if(before.layout.template!=after.layout.template||before.fullScreenCamera!=after.fullScreenCamera)null else saved
}
