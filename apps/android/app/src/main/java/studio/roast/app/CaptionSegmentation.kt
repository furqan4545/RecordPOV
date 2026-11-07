package studio.roast.app

/** Measured microphone activity yields phrase intervals, not invented word timestamps. */
fun microphoneSpeechRanges(windowRms:List<Float>,durationMs:Long,windowMs:Long=20):List<EditRange> {
    val raw=mutableListOf<EditRange>()
    var start=-1;var lastVoice=-1
    fun close() {
        if(start>=0&&lastVoice-start>=4) {
            val a=(start*windowMs-100).coerceAtLeast(0)
            val b=((lastVoice+1)*windowMs+100).coerceAtMost(durationMs)
            raw+=EditRange(a,b)
        }
        start=-1;lastVoice=-1
    }
    windowRms.forEachIndexed {index,rms ->
        if(rms.isFinite()&&rms>=.006f){if(start<0)start=index;lastVoice=index}
        else if(start>=0&&(index-lastVoice)*windowMs>=400)close()
    }
    close()
    return raw.flatMap{range ->
        val pieces=mutableListOf<EditRange>();var cursor=range.startMs
        while(cursor<range.endMs){val end=minOf(cursor+6_000,range.endMs);pieces+=EditRange(cursor,end);cursor=end}
        pieces
    }
}
