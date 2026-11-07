package studio.roast.app

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaMetadataRetriever
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.ByteBuffer

internal data class SourceFacts(val durationUs:Long,val width:Int,val height:Int,val hasAudio:Boolean)
/** Actual codecs of a downloaded file, read before deciding between the existing direct path and conversion. */
internal data class MediaProbe(val videoMime:String?,val audioMime:String?,val width:Int,val height:Int,val durationUs:Long,
    val fps:Double?,val videoBitsPerSecond:Long?,val avcEightBit420:Boolean,val rotation:Int=0) {
    /** Upright H.264 8-bit 4:2:0 video (when present) and AAC audio (when present): the existing rules apply without conversion. */
    val directlyUsable get()=(videoMime==null||videoMime=="video/avc"&&avcEightBit420&&rotation%360==0)&&(audioMime==null||audioMime=="audio/mp4a-latm")
}
internal object NativeSourceMedia {
    /** Lenient read of any MP4-family file: track codecs, raster, measured frame rate and video data rate. */
    suspend fun probe(file:File):MediaProbe=withContext(Dispatchers.IO) {
        val context=currentCoroutineContext()
        require(file.isFile&&file.length()>0)
        val extractor=MediaExtractor()
        try {
            extractor.setDataSource(file.absolutePath)
            require(extractor.psshInfo.isNullOrEmpty()){ "Protected video cannot be imported." }
            var videoMime:String?=null;var audioMime:String?=null;var width=0;var height=0;var eightBit=false
            var videoDuration=0L;var audioDuration=0L;var frames=0;var bytes=0L;var span=0L;var rotation=0
            for(index in 0 until extractor.trackCount) {
                context.ensureActive()
                val format=extractor.getTrackFormat(index);val mime=format.getString(MediaFormat.KEY_MIME).orEmpty()
                if(!mime.startsWith("video/")&&!mime.startsWith("audio/"))continue
                val isVideo=mime.startsWith("video/")
                require(if(isVideo)videoMime==null else audioMime==null){"This file has unsupported extra tracks."}
                val declared=if(format.containsKey(MediaFormat.KEY_DURATION))format.getLong(MediaFormat.KEY_DURATION)else 0L
                if(!isVideo){audioMime=mime;audioDuration=declared;continue}
                videoMime=mime
                width=format.getInteger(MediaFormat.KEY_WIDTH);height=format.getInteger(MediaFormat.KEY_HEIGHT)
                if(format.containsKey(MediaFormat.KEY_ROTATION))rotation=format.getInteger(MediaFormat.KEY_ROTATION)
                if(mime=="video/avc")eightBit=format.getByteBuffer("csd-0")?.duplicate()?.let{csd->
                    csd.remaining()<=65536&&ByteArray(csd.remaining()).also{csd.get(it)}.let{AvcFormatPolicy.eightBit420(it)}
                }?:false
                extractor.selectTrack(index);extractor.seekTo(0,MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                var first:Long?=null;var last=0L
                while(extractor.sampleTime!=-1L) {
                    context.ensureActive()
                    require(extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_ENCRYPTED==0){ "Protected video cannot be imported." }
                    val time=extractor.sampleTime
                    if(first==null){first=time;last=time}else last=maxOf(last,time)
                    frames++;require(frames<=800_000){"The media sample table is too large."}
                    extractor.sampleSize.takeIf{it>0}?.let{bytes+=it}
                    if(!extractor.advance())break
                }
                extractor.unselectTrack(index)
                require(first!=null){"The media track is empty."}
                span=last-first
                videoDuration=maxOf(declared,span)
            }
            val seconds=videoDuration/1_000_000.0
            // first..last timestamps cover frames-1 frame intervals.
            MediaProbe(videoMime,audioMime,width,height,maxOf(videoDuration,audioDuration),
                if(videoMime!=null&&frames>1&&span>0)(frames-1)/(span/1_000_000.0) else null,
                if(videoMime!=null&&seconds>0)(bytes*8/seconds).toLong() else null,eightBit,rotation)
        }finally{extractor.release()}
    }

    private data class Track(val index:Int,val format:MediaFormat,val first:Long,val duration:Long,val last:Long,val samples:Int)
    private data class Inspection(val facts:SourceFacts,val video:Track?,val audio:Track?)

    suspend fun inspect(file:File,expected:ExpectedMedia?=null,strict:Boolean=true):SourceFacts=withContext(Dispatchers.IO) {
        val context=currentCoroutineContext()
        val inspection=read(file,strict){context.ensureActive()}
        require(inspection.video!=null){"This file does not contain a video."}
        val facts=inspection.facts
        if(expected!=null)require(DirectImportPolicy.matches(facts.durationUs/1_000_000.0,facts.width,facts.height,facts.hasAudio,expected)) {"The video does not match its source."}
        facts
    }

    suspend fun mux(video:File,audio:File,output:File,expected:ExpectedMedia):SourceFacts=withContext(Dispatchers.IO) {
        val context=currentCoroutineContext();val check={context.ensureActive()}
        val picture=read(video,true,check);val sound=read(audio,true,check)
        require(picture.video!=null&&picture.audio==null&&sound.video==null&&sound.audio!=null){"The source tracks could not be combined safely."}
        val v=picture.video;val a=sound.audio
        require(MuxTiming.compatibleDurations(v.duration/1_000_000.0,a.duration/1_000_000.0)){"The source audio and video have different lengths."}
        val origin=MuxTiming.origin(listOf(v.first,a.first))
        val muxer=MediaMuxer(output.absolutePath,MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var started=false
        try {
            val videoOut=muxer.addTrack(v.format);val audioOut=muxer.addTrack(a.format)
            muxer.start();started=true
            // Preserve extractor/decode order, original PTS, codec configuration and sync flags.
            // MediaMuxer supports AVC B-frames on this app's API29+ baseline.
            copyTracks(listOf(Triple(video,v,videoOut),Triple(audio,a,audioOut)),muxer,origin,check)
            muxer.stop();started=false
        }finally {if(started)runCatching{muxer.stop()};muxer.release()}
        val result=read(output,true,check).facts
        require(DirectImportPolicy.matches(result.durationUs/1_000_000.0,result.width,result.height,result.hasAudio,expected)){"The combined video could not be verified."}
        result
    }

    private fun read(file:File,strict:Boolean,check:()->Unit):Inspection {
        require(file.isFile&&file.length()>0)
        if(strict)file.inputStream().use {input->val prefix=ByteArray(12);require(input.read(prefix)==12&&String(prefix,4,4,Charsets.US_ASCII)=="ftyp"){"The source is not a progressive MP4 file."}}
        val extractor=MediaExtractor()
        try {
            extractor.setDataSource(file.absolutePath)
            require(extractor.psshInfo.isNullOrEmpty()){ "Protected video cannot be imported." }
            var video:Track?=null;var audio:Track?=null
            for(index in 0 until extractor.trackCount) {
                check();val format=extractor.getTrackFormat(index);val mime=format.getString(MediaFormat.KEY_MIME).orEmpty()
                if(!mime.startsWith("video/")&&!mime.startsWith("audio/"))continue
                val isVideo=mime.startsWith("video/")
                require(if(isVideo)video==null else audio==null){"This file has unsupported extra tracks."}
                if(strict) {
                    require(mime==if(isVideo)"video/avc" else "audio/mp4a-latm"){"The source codec needs conversion."}
                    if(isVideo) {
                        require(!format.containsKey(MediaFormat.KEY_ROTATION)||format.getInteger(MediaFormat.KEY_ROTATION)%360==0){"The source orientation needs conversion."}
                        val csd=format.getByteBuffer("csd-0")?.duplicate() ?: error("The video codec could not be verified.")
                        require(csd.remaining()<=65536);val bytes=ByteArray(csd.remaining());csd.get(bytes)
                        require(AvcFormatPolicy.eightBit420(bytes)){"The source color format needs conversion."}
                    }else require(format.getInteger(MediaFormat.KEY_SAMPLE_RATE) in 8000..192000&&format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) in 1..8)
                }
                val declared=if(format.containsKey(MediaFormat.KEY_DURATION))format.getLong(MediaFormat.KEY_DURATION)else 0L
                extractor.selectTrack(index);extractor.seekTo(0,MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                val first=extractor.sampleTime
                require(first>=-1_000_000 && first!=-1L){"The media track is empty."}
                var last=first;var samples=0;val pts=if(strict&&isVideo)ArrayList<Long>()else null
                if(strict)while(extractor.sampleTime!=-1L) {
                    check();require(extractor.sampleFlags and (MediaExtractor.SAMPLE_FLAG_ENCRYPTED or MediaExtractor.SAMPLE_FLAG_PARTIAL_FRAME)==0)
                    last=maxOf(last,extractor.sampleTime);pts?.add(extractor.sampleTime);samples++
                    require(samples<=800_000){"The media sample table is too large."}
                    if(!extractor.advance())break
                }
                extractor.unselectTrack(index)
                val duration=maxOf(declared,last-first)
                require(duration>0){"The media duration could not be read."}
                if(strict&&isVideo) {
                    require(DirectImportPolicy.frameTimingAllowed(duration,pts!!)) {"The source frame rate needs conversion."}
                }
                val track=Track(index,format,first,duration,last,samples)
                if(isVideo)video=track else audio=track
            }
            val v=video
            if(strict&&v!=null)MediaMetadataRetriever().use {retriever->
                retriever.setDataSource(file.absolutePath)
                val rotation=retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull()?:0
                require(rotation%360==0){"The source orientation needs conversion."}
            }
            val duration=maxOf(v?.duration?:0,audio?.duration?:0)
            val width=v?.format?.getInteger(MediaFormat.KEY_WIDTH)?:0;val height=v?.format?.getInteger(MediaFormat.KEY_HEIGHT)?:0
            if(strict&&v!=null)require(duration<=DirectImportPolicy.MAX_DURATION_US+DirectImportPolicy.MAX_DURATION_TOLERANCE_US&&DirectImportPolicy.rasterAllowed(width,height))
            return Inspection(SourceFacts(duration,width,height,audio!=null),video,audio)
        }finally{extractor.release()}
    }
    private fun copyTracks(inputs:List<Triple<File,Track,Int>>,muxer:MediaMuxer,origin:Long,check:()->Unit) {
        val readers=ArrayList<Pair<MediaExtractor,Int>>()
        try {
            inputs.forEach{(file,track,output)->
                val extractor=MediaExtractor();readers.add(extractor to output)
                extractor.setDataSource(file.absolutePath);extractor.selectTrack(track.index)
                extractor.seekTo(0,MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            }
            val largest=inputs.maxOf{(_,track,_)->if(track.format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE))track.format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)else 0}
            val buffer=ByteBuffer.allocateDirect(maxOf(4*1024*1024,largest).coerceAtMost(16*1024*1024));val info=MediaCodec.BufferInfo()
            while(true) {
                check()
                val (extractor,outputTrack)=readers.filter{it.first.sampleTime!=-1L}.minByOrNull{it.first.sampleTime} ?: break
                val expected=extractor.sampleSize
                require(expected in 1..buffer.capacity().toLong()){ "The media sample is too large." }
                buffer.clear();val size=extractor.readSampleData(buffer,0);require(size==expected.toInt())
                val flags=if(extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC!=0)MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                info.set(0,size,MuxTiming.timestamp(extractor.sampleTime,origin),flags)
                muxer.writeSampleData(outputTrack,buffer,info)
                extractor.advance()
            }
        }finally{readers.forEach{it.first.release()}}
    }
}
