package studio.roast.app

import kotlin.math.roundToInt

const val STEM_SAMPLE_RATE=44_100
data class EditRange(val startMs:Long,val endMs:Long) {
    val durationMs:Long get()=(endMs-startMs).coerceAtLeast(0)
}
data class MixGains(val source:Float=1f,val microphone:Float=.6f,val music:Float=.25f) {
    fun clamped()=MixGains(source.safeGain(),microphone.safeGain(),music.safeGain())
}
private fun Float.safeGain()=if(isFinite())coerceIn(0f,2f)else 1f

/** Original capture time ranges retained after non-destructive trim and interval deletion. */
fun retainedRanges(durationMs:Long,trimStartMs:Long=0,trimEndMs:Long=durationMs,cuts:List<EditRange> = emptyList()):List<EditRange> {
    val start=trimStartMs.coerceIn(0,durationMs)
    val end=trimEndMs.coerceIn(start,durationMs)
    var cursor=start
    val kept=mutableListOf<EditRange>()
    for(cut in cuts.sortedBy{it.startMs}) {
        val a=cut.startMs.coerceIn(start,end);val b=cut.endMs.coerceIn(a,end)
        if(a>cursor)kept+=EditRange(cursor,a)
        cursor=maxOf(cursor,b)
    }
    if(cursor<end)kept+=EditRange(cursor,end)
    return kept.filter{it.durationMs>0}
}
fun frameAtMs(ms:Long,sampleRate:Int=STEM_SAMPLE_RATE):Long=ms.coerceAtLeast(0)*sampleRate/1_000
data class PcmTimestampPlacement(val outputFrame:Long,val skipInputFrames:Int)
fun pcmTimestampPlacement(presentationTimeUs:Long,inputRate:Int,inputFrames:Int):PcmTimestampPlacement {
    val skip=if(presentationTimeUs<0)minOf(inputFrames.toLong(),(-presentationTimeUs*inputRate+999_999)/1_000_000).toInt()else 0
    val startUs=(presentationTimeUs+skip.toLong()*1_000_000/inputRate).coerceAtLeast(0)
    return PcmTimestampPlacement(startUs*STEM_SAMPLE_RATE/1_000_000,skip)
}
data class StemCopySpan(val outputFrame:Long,val inputFrame:Long,val frames:Long)
data class TimelineAudioSpan(val sourceId:String,val timelineStartMs:Long,val sourceStartMs:Long,val durationMs:Long)
class SourceAudioTimeline {
    val segments=mutableListOf<TimelineAudioSpan>()
    private var sourceId:String?=null
    private var timelineStart=0L
    private var sourceStart=0L
    fun clear(){segments.clear();sourceId=null}
    fun begin(source:String,timelineMs:Long,sourceMs:Long){if(sourceId!=null)return;sourceId=source;timelineStart=timelineMs;sourceStart=sourceMs}
    fun close(sourceMs:Long,timelineMs:Long) {
        val source=sourceId?:return
        val length=minOf((sourceMs-sourceStart).coerceAtLeast(0),(timelineMs-timelineStart).coerceAtLeast(0))
        if(length>=40)segments+=TimelineAudioSpan(source,timelineStart,sourceStart,length)
        sourceId=null
    }
}
fun sourceStemSpan(timelineMs:Long,sourceMs:Long,lengthMs:Long,totalFrames:Long):StemCopySpan? {
    val output=frameAtMs(timelineMs)
    val count=minOf(frameAtMs(lengthMs),totalFrames-output)
    return if(count>0)StemCopySpan(output,frameAtMs(sourceMs),count)else null
}

/** The same per-sample gain/sum/limiter used to create preview and final export audio. */
object StemMixer {
    fun mix(microphone:FloatArray,source:FloatArray,music:FloatArray,gains:MixGains,count:Int):ShortArray {
        val g=gains.clamped()
        return ShortArray(count){i ->
            val sample=(microphone.getOrElse(i){0f}*g.microphone+source.getOrElse(i){0f}*g.source+music.getOrElse(i){0f}*g.music)
            ((if(sample.isFinite())sample else 0f).coerceIn(-1f,1f)*32767f).roundToInt().toShort()
        }
    }
}

/** Streaming linear resampling keeps decoder chunk boundaries out of the resulting audio. */
class MonoResampler(private val inputRate:Int,private val outputRate:Int,private val emit:(Float)->Unit) {
    private var index=0L
    private var next=0.0
    private var previous=0f
    fun accept(sample:Float) {
        val step=inputRate.toDouble()/outputRate
        while(next<=index) {
            val value=if(index==0L)sample else previous+(sample-previous)*(next-(index-1)).toFloat()
            emit(value)
            next+=step
        }
        previous=sample;index++
    }
}
