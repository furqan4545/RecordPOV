package studio.roast.app

enum class StageTemplate(val label:String,val shortLabel:String) {
    Pip("Small camera","Small camera"),Split("Split","Split"),CameraMain("You on stage","Stage")
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
