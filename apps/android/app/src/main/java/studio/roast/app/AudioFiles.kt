package studio.roast.app

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.Closeable
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.sqrt

class NoAudioTrack:IllegalStateException("This video has no source audio track.")

class WaveReader(file:File):Closeable {
    private val input=RandomAccessFile(file,"r")
    val frames:Long
    init {
        val header=ByteArray(44);input.readFully(header)
        check(String(header,0,4)=="RIFF"&&String(header,8,4)=="WAVE"){"The audio stem could not be opened."}
        val h=ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
        check(h.getShort(22).toInt()==1&&h.getInt(24)==STEM_SAMPLE_RATE&&h.getShort(34).toInt()==16){"The audio stem format is unsupported."}
        frames=(input.length()-44)/2
    }
    fun read(frame:Long,count:Int,loop:Boolean=false):FloatArray {
        val result=FloatArray(count)
        if(frames<=0)return result
        var cursor=frame.coerceAtLeast(0);var written=0
        while(written<count) {
            if(loop)cursor%=frames
            if(cursor>=frames)break
            val length=minOf((frames-cursor).coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),count-written)
            val bytes=ByteArray(length*2)
            input.seek(44+cursor*2);input.readFully(bytes)
            val data=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            repeat(length){result[written+it]=data.short/32768f}
            written+=length;cursor+=length
        }
        return result
    }
    fun rms():Double {
        var position=0L;var energy=0.0
        while(position<frames) {
            val block=read(position,minOf(16_384L,frames-position).toInt())
            block.forEach{energy+=it.toDouble()*it}
            position+=block.size
        }
        return if(frames>0)sqrt(energy/frames)else 0.0
    }
    override fun close(){input.close()}
}

private fun waveHeader(frames:Long):ByteArray=ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
    require(frames*2+36<=Int.MAX_VALUE){"This recording is too long for its audio stem."}
    put("RIFF".toByteArray());putInt((frames*2+36).toInt());put("WAVEfmt ".toByteArray());putInt(16)
    putShort(1);putShort(1);putInt(STEM_SAMPLE_RATE);putInt(STEM_SAMPLE_RATE*2);putShort(2);putShort(16)
    put("data".toByteArray());putInt((frames*2).toInt())
}.array()

class WaveWriter(file:File):Closeable {
    private val output=RandomAccessFile(file,"rw").apply{setLength(0);write(waveHeader(0))}
    private val buffer=ByteBuffer.allocate(32_768).order(ByteOrder.LITTLE_ENDIAN)
    var frames=0L;private set
    private var cursor=0L
    fun position(frame:Long) {
        flush();cursor=frame.coerceAtLeast(0)
        if(cursor>frames){frames=cursor;output.setLength(44+frames*2)}
        output.seek(44+cursor*2)
    }
    fun sample(value:Float) {
        if(buffer.remaining()<2)flush()
        buffer.putShort((value.coerceIn(-1f,1f)*32767f).toInt().toShort());cursor++;frames=maxOf(frames,cursor)
    }
    fun write(samples:ShortArray){samples.forEach{if(buffer.remaining()<2)flush();buffer.putShort(it);cursor++;frames=maxOf(frames,cursor)}}
    private fun flush(){output.write(buffer.array(),0,buffer.position());buffer.clear()}
    override fun close(){flush();output.seek(0);output.write(waveHeader(frames));output.close()}
}

fun createSilentWave(file:File,frames:Long) {
    RandomAccessFile(file,"rw").use{it.setLength(0);it.setLength(44+frames*2);it.seek(0);it.write(waveHeader(frames))}
}
fun copyWaveSpan(source:File,destination:File,span:StemCopySpan) {
    WaveReader(source).use{reader->RandomAccessFile(destination,"rw").use{writer->
        var copied=0L
        while(copied<span.frames) {
            val count=minOf(16_384L,span.frames-copied).toInt()
            val input=reader.read(span.inputFrame+copied,count)
            val bytes=ByteBuffer.allocate(count*2).order(ByteOrder.LITTLE_ENDIAN)
            input.forEach{bytes.putShort((it*32768f).toInt().coerceIn(-32768,32767).toShort())}
            writer.seek(44+(span.outputFrame+copied)*2);writer.write(bytes.array());copied+=count
        }
    }}
}

/** MediaCodec decodes existing files only. It never opens a microphone or an audio output device. */
object StemDecoder {
    private fun bytesPerSample(encoding:Int)=when(encoding){AudioFormat.ENCODING_PCM_8BIT->1;AudioFormat.ENCODING_PCM_FLOAT,AudioFormat.ENCODING_PCM_32BIT->4;AudioFormat.ENCODING_PCM_24BIT_PACKED->3;AudioFormat.ENCODING_PCM_16BIT->2;else->error("This audio encoding is unsupported.")}
    private fun feedPcm(buffer:ByteBuffer,encoding:Int,channels:Int,resampler:MonoResampler) {
        val bytes=bytesPerSample(encoding)
        repeat(buffer.remaining()/bytes/channels) {
            var mono=0f
            repeat(channels){mono+=when(encoding) {
                AudioFormat.ENCODING_PCM_FLOAT->buffer.float
                AudioFormat.ENCODING_PCM_8BIT->((buffer.get().toInt() and 255)-128)/128f
                AudioFormat.ENCODING_PCM_32BIT->buffer.int/2147483648f
                AudioFormat.ENCODING_PCM_24BIT_PACKED->{val a=buffer.get().toInt() and 255;val b=buffer.get().toInt() and 255;val c=buffer.get().toInt();((c shl 16) or (b shl 8) or a)/8388608f}
                else->buffer.short/32768f
            }}
            resampler.accept(mono/channels)
        }
    }
    private class TimedPcm(private val writer:WaveWriter) {
        private var expectedUs:Long?=null
        private var previousRate=0
        private var resampler:MonoResampler?=null
        fun write(buffer:ByteBuffer,presentationTimeUs:Long,encoding:Int,channels:Int,rate:Int) {
            val bytes=bytesPerSample(encoding)*channels
            val frames=buffer.remaining()/bytes
            val placement=pcmTimestampPlacement(presentationTimeUs,rate,frames)
            if(placement.skipInputFrames>=frames){expectedUs=presentationTimeUs+frames.toLong()*1_000_000/rate;return}
            if(expectedUs==null||previousRate!=rate||kotlin.math.abs(presentationTimeUs-checkNotNull(expectedUs))>2_000) {
                writer.position(placement.outputFrame)
                resampler=MonoResampler(rate,STEM_SAMPLE_RATE,writer::sample)
            }
            buffer.position(buffer.position()+placement.skipInputFrames*bytes)
            feedPcm(buffer,encoding,channels,checkNotNull(resampler))
            previousRate=rate;expectedUs=presentationTimeUs+frames.toLong()*1_000_000/rate
        }
    }
    suspend fun decode(context:Context,uri:Uri,destination:File):Long=withContext(Dispatchers.IO) {
        val extractor=MediaExtractor();var codec:MediaCodec?=null
        try {
            extractor.setDataSource(context,uri,null)
            val track=(0 until extractor.trackCount).firstOrNull{extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/")==true}
                ?: throw NoAudioTrack()
            extractor.selectTrack(track)
            val format=extractor.getTrackFormat(track)
            val mime=checkNotNull(format.getString(MediaFormat.KEY_MIME))
            if(mime=="audio/raw") {
                var frames=0L
                WaveWriter(destination).use {writer ->
                    val channels=format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    val encoding=if(format.containsKey(MediaFormat.KEY_PCM_ENCODING))format.getInteger(MediaFormat.KEY_PCM_ENCODING)else AudioFormat.ENCODING_PCM_16BIT
                    val rate=format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    val timed=TimedPcm(writer)
                    val buffer=ByteBuffer.allocate(256*1024).order(ByteOrder.LITTLE_ENDIAN)
                    while(true) {
                        currentCoroutineContext().ensureActive();buffer.clear()
                        val size=extractor.readSampleData(buffer,0);if(size<0)break
                        buffer.position(0);buffer.limit(size);timed.write(buffer,extractor.sampleTime,encoding,channels,rate);extractor.advance()
                    }
                    frames=writer.frames
                }
                check(frames>0){"This audio file contains no samples."}
                return@withContext frames
            }
            val decoder=MediaCodec.createDecoderByType(mime)
            codec=decoder;decoder.configure(format,null,null,0);decoder.start()
            var inputDone=false;var outputDone=false
            var channels=format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var sampleRate=format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var encoding=AudioFormat.ENCODING_PCM_16BIT
            var outputFrames=0L
            WaveWriter(destination).use{writer ->
                val timed=TimedPcm(writer)
                val info=MediaCodec.BufferInfo()
                while(!outputDone) {
                    currentCoroutineContext().ensureActive()
                    if(!inputDone) {
                        val index=decoder.dequeueInputBuffer(10_000)
                        if(index>=0) {
                            val buffer=checkNotNull(decoder.getInputBuffer(index));val size=extractor.readSampleData(buffer,0)
                            if(size<0){decoder.queueInputBuffer(index,0,0,0,MediaCodec.BUFFER_FLAG_END_OF_STREAM);inputDone=true}
                            else{decoder.queueInputBuffer(index,0,size,extractor.sampleTime,0);extractor.advance()}
                        }
                    }
                    when(val index=decoder.dequeueOutputBuffer(info,10_000)) {
                        MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val next=decoder.outputFormat
                            channels=next.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            val rate=next.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            sampleRate=rate
                            encoding=if(next.containsKey(MediaFormat.KEY_PCM_ENCODING))next.getInteger(MediaFormat.KEY_PCM_ENCODING)else AudioFormat.ENCODING_PCM_16BIT
                        }
                        else -> if(index>=0) {
                            if(info.size>0) {
                                val buffer=checkNotNull(decoder.getOutputBuffer(index)).order(ByteOrder.LITTLE_ENDIAN)
                                buffer.position(info.offset);buffer.limit(info.offset+info.size)
                                timed.write(buffer,info.presentationTimeUs,encoding,channels,sampleRate)
                            }
                            outputDone=info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM!=0
                            decoder.releaseOutputBuffer(index,false)
                        }
                    }
                }
                outputFrames=writer.frames
            }
            check(outputFrames>0){"The audio decoder returned no samples."}
            outputFrames
        }catch(e:Throwable){destination.delete();throw e}
        finally{runCatching{codec?.stop()};codec?.release();extractor.release()}
    }
}
