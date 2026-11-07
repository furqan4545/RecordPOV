package studio.roast.app

const val MIN_TRIM_DURATION_MS=250L
enum class TrimEdge {Start,End}
data class TrimBounds(val startMs:Long,val endMs:Long) {
    val durationMs:Long get()=endMs-startMs
    fun validFor(durationMs:Long)=startMs>=0&&endMs<=durationMs&&this.durationMs>=MIN_TRIM_DURATION_MS
}
fun visibleTrimBounds(durationMs:Long,startMs:Long,endMs:Long):TrimBounds =
    TrimBounds(startMs,endMs).takeIf{it.validFor(durationMs)}?:TrimBounds(0,durationMs.coerceAtLeast(0))
fun moveTrimEdge(bounds:TrimBounds,edge:TrimEdge,positionMs:Long,durationMs:Long):TrimBounds {
    val duration=durationMs.coerceAtLeast(0)
    val minimum=minOf(MIN_TRIM_DURATION_MS,duration)
    val valid=visibleTrimBounds(duration,bounds.startMs,bounds.endMs)
    return when(edge) {
        TrimEdge.Start->valid.copy(startMs=positionMs.coerceIn(0,(valid.endMs-minimum).coerceAtLeast(0)))
        TrimEdge.End->valid.copy(endMs=positionMs.coerceIn((valid.startMs+minimum).coerceAtMost(duration),duration))
    }
}
fun contiguousTrimEdits(edits:DraftEdits,bounds:TrimBounds,durationMs:Long):DraftEdits {
    require(bounds.validFor(durationMs)){"Keep at least a quarter of a second."}
    return edits.copy(trimStartMs=bounds.startMs,trimEndMs=bounds.endMs,cuts=emptyList())
}
fun timelinePositionAt(x:Float,left:Float,width:Float,durationMs:Long):Long =
    (((x-left)/width.coerceAtLeast(1f)).coerceIn(0f,1f)*durationMs).toLong()
fun timelineXAt(positionMs:Long,left:Float,width:Float,durationMs:Long):Float =
    left+positionMs.coerceIn(0,durationMs.coerceAtLeast(0)).toFloat()/durationMs.coerceAtLeast(1)*width
fun originalPositionAtEdited(editedMs:Long,ranges:List<EditRange>):Long {
    var offset=editedMs.coerceAtLeast(0)
    ranges.forEach{range->if(offset<range.durationMs)return range.startMs+offset else offset-=range.durationMs}
    return ranges.lastOrNull()?.endMs?:0
}
fun editedPositionAtOriginal(originalMs:Long,ranges:List<EditRange>):Long {
    var output=0L
    ranges.forEach{range->
        if(originalMs<range.startMs)return output
        if(originalMs<range.endMs)return output+originalMs-range.startMs
        output+=range.durationMs
    }
    return output
}

data class FrameSeek(val id:Long,val positionMs:Long)
/** One frame seek in flight, one replaceable latest target; obsolete timeouts cannot release newer work. */
class LatestFrameSeekGate {
    private var nextId=0L
    private var active:FrameSeek?=null
    private var latest:FrameSeek?=null
    fun request(positionMs:Long):FrameSeek? {
        latest=FrameSeek(++nextId,positionMs.coerceAtLeast(0))
        return if(active==null)dispatch()else null
    }
    fun rendered(positionMs:Long):FrameSeek? {
        val current=active?:return null
        if(kotlin.math.abs(positionMs-current.positionMs)>80)return null
        active=null;return dispatch()
    }
    fun timeout(id:Long):FrameSeek? {
        if(active?.id!=id)return null
        active=null;return dispatch()
    }
    fun cancel(){active=null;latest=null;nextId++}
    private fun dispatch():FrameSeek? {val request=latest;latest=null;active=request;return request}
}
