package studio.roast.app

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import kotlin.math.*

/** No gain normalization/gate: 70Hz rumble filtering and bounded stationary-hiss attenuation only. */
class VoiceHighPass(sampleRate:Int=STEM_SAMPLE_RATE) {
    private val omega=2*PI*70/sampleRate
    private val alpha=sin(omega)/(2*sqrt(.5))
    private val a0=1+alpha
    private val b0=(1+cos(omega))/2/a0
    private val b1=-(1+cos(omega))/a0
    private val b2=b0
    private val a1=-2*cos(omega)/a0
    private val a2=(1-alpha)/a0
    private var x1=0.0;private var x2=0.0;private var y1=0.0;private var y2=0.0
    fun process(input:Float):Float {
        val x=if(input.isFinite())input.toDouble()else 0.0
        val y=b0*x+b1*x1+b2*x2-a1*y1-a2*y2
        x2=x1;x1=x;y2=y1;y1=y
        return y.toFloat()
    }
}

private const val VOICE_FFT_SIZE=2048
private const val VOICE_HOP=512
private val voiceCleanupMutex=Mutex()

private fun fft(real:DoubleArray,imaginary:DoubleArray,inverse:Boolean=false) {
    val size=real.size;var j=0
    for(i in 1 until size) {
        var bit=size shr 1
        while(j and bit!=0){j=j xor bit;bit=bit shr 1}
        j=j xor bit
        if(i<j){val r=real[i];real[i]=real[j];real[j]=r;val v=imaginary[i];imaginary[i]=imaginary[j];imaginary[j]=v}
    }
    var length=2
    while(length<=size) {
        val angle=(if(inverse)2 else -2)*PI/length;val rootR=cos(angle);val rootI=sin(angle)
        for(start in 0 until size step length) {
            var wr=1.0;var wi=0.0
            for(k in 0 until length/2) {
                val a=start+k;val b=a+length/2
                val vr=real[b]*wr-imaginary[b]*wi;val vi=real[b]*wi+imaginary[b]*wr
                val ur=real[a];val ui=imaginary[a]
                real[a]=ur+vr;imaginary[a]=ui+vi;real[b]=ur-vr;imaginary[b]=ui-vi
                val next=wr*rootR-wi*rootI;wi=wr*rootI+wi*rootR;wr=next
            }
        }
        length=length shl 1
    }
    if(inverse)for(i in real.indices){real[i]/=size;imaginary[i]/=size}
}

private fun paddedFrame(reader:WaveReader,start:Long,count:Int):FloatArray {
    val result=FloatArray(count)
    val padding=(-start).coerceIn(0,count.toLong()).toInt()
    if(padding<count)reader.read(start.coerceAtLeast(0),count-padding).copyInto(result,padding)
    return result
}

private suspend fun estimateStationaryNoise(reader:WaveReader,window:DoubleArray):DoubleArray {
    val energies=mutableListOf<Pair<Long,Double>>()
    var position=0L
    while(position+VOICE_FFT_SIZE<=reader.frames) {
        currentCoroutineContext().ensureActive()
        val samples=reader.read(position,VOICE_FFT_SIZE)
        energies+=position to samples.sumOf{it.toDouble()*it}/VOICE_FFT_SIZE
        position+=VOICE_FFT_SIZE
    }
    val noise=DoubleArray(VOICE_FFT_SIZE/2+1)
    if(energies.isEmpty())return noise
    val sorted=energies.sortedBy{it.second}
    val quiet=sorted.take(maxOf(1,sorted.size/5))
    val contrast=sorted[(sorted.size*.8).toInt().coerceAtMost(sorted.lastIndex)].second/(quiet.last().second+1e-15)
    val selected=if(quiet.size<=64)quiet else (0 until 64).map{quiet[it*quiet.size/64]}
    var used=0
    selected.forEach{(start,_) ->
        currentCoroutineContext().ensureActive()
        val samples=reader.read(start,VOICE_FFT_SIZE)
        val real=DoubleArray(VOICE_FFT_SIZE){samples[it]*window[it]};val imaginary=DoubleArray(VOICE_FFT_SIZE)
        fft(real,imaginary)
        val power=DoubleArray(noise.size){real[it]*real[it]+imaginary[it]*imaginary[it]}
        val band=power.drop(4)
        val flatness=exp(band.sumOf{ln(it+1e-15)}/band.size)/(band.average()+1e-15)
        // A steady tonal voice is not a noise profile. Speech pauses or broadband
        // stationary noise provide evidence; otherwise retain only the gentle high-pass.
        if(contrast>=3.0||flatness>=.25||band.average()<1e-12) {
            power.forEachIndexed{index,value->noise[index]+=value};used++
        }
    }
    if(used>0)noise.indices.forEach{noise[it]/=used}
    return noise
}

suspend fun cleanVoiceWave(raw:File,destination:File)=withContext(Dispatchers.IO) {
    val highPassed=File(destination.parentFile,".voice-hp-${UUID.randomUUID()}.wav")
    val pending=File(destination.parentFile,".voice-clean-${UUID.randomUUID()}.wav")
    try {
        WaveReader(raw).use{reader->WaveWriter(highPassed).use{writer->
            val filter=VoiceHighPass();var frame=0L
            while(frame<reader.frames) {
                currentCoroutineContext().ensureActive()
                val block=reader.read(frame,minOf(16_384L,reader.frames-frame).toInt())
                block.forEach{writer.sample(filter.process(it))};frame+=block.size
            }
        }}
        val window=DoubleArray(VOICE_FFT_SIZE){.5-.5*cos(2*PI*it/VOICE_FFT_SIZE)}
        WaveReader(highPassed).use{reader ->
            val noise=estimateStationaryNoise(reader,window)
            val sum=DoubleArray(VOICE_FFT_SIZE);val normalization=DoubleArray(VOICE_FFT_SIZE)
            val previousGain=DoubleArray(noise.size){1.0}
            WaveWriter(pending).use{writer ->
                var start=-(VOICE_FFT_SIZE-VOICE_HOP).toLong()
                while(start<reader.frames) {
                    currentCoroutineContext().ensureActive()
                    val frame=paddedFrame(reader,start,VOICE_FFT_SIZE)
                    val real=DoubleArray(VOICE_FFT_SIZE){frame[it]*window[it]};val imaginary=DoubleArray(VOICE_FFT_SIZE)
                    fft(real,imaginary)
                    val gains=DoubleArray(noise.size){bin ->
                        val power=real[bin]*real[bin]+imaginary[bin]*imaginary[bin]
                        val hz=bin.toDouble()*STEM_SAMPLE_RATE/VOICE_FFT_SIZE
                        val floor=if(hz in 100.0..4_500.0).88 else .5 // at most1.1dB in voice band;6dB elsewhere
                        val target=sqrt((1-.75*noise[bin]/(power+1e-15)).coerceIn(floor*floor,1.0))
                        val smoothed=.7*previousGain[bin]+.3*target
                        previousGain[bin]=smoothed;smoothed
                    }
                    for(bin in real.indices) {
                        val k=if(bin<=VOICE_FFT_SIZE/2)bin else VOICE_FFT_SIZE-bin
                        val average=(gains[(k-1).coerceAtLeast(0)]+2*gains[k]+gains[(k+1).coerceAtMost(gains.lastIndex)])/4
                        val hz=k.toDouble()*STEM_SAMPLE_RATE/VOICE_FFT_SIZE
                        val gain=average.coerceIn(if(hz in 100.0..4_500.0).88 else .5,1.0)
                        real[bin]*=gain;imaginary[bin]*=gain
                    }
                    fft(real,imaginary,true)
                    for(i in real.indices){sum[i]+=real[i]*window[i];normalization[i]+=window[i]*window[i]}
                    for(i in 0 until VOICE_HOP)if(start+i>=0&&start+i<reader.frames) {
                        writer.sample((if(normalization[i]>1e-12)sum[i]/normalization[i]else 0.0).toFloat())
                    }
                    sum.copyInto(sum,0,VOICE_HOP,VOICE_FFT_SIZE);normalization.copyInto(normalization,0,VOICE_HOP,VOICE_FFT_SIZE)
                    sum.fill(0.0,VOICE_FFT_SIZE-VOICE_HOP);normalization.fill(0.0,VOICE_FFT_SIZE-VOICE_HOP)
                    start+=VOICE_HOP
                }
            }
        }
        currentCoroutineContext().ensureActive()
        check(pending.renameTo(destination)){"Your cleaned voice could not be saved. The original microphone audio is safe."}
    }finally{highPassed.delete();pending.delete()}
}

suspend fun microphoneForMix(draft:ReactionDraft):File {
    if(!draft.edits.voiceCleanupEnabled)return draft.microphone
    return withContext(Dispatchers.IO){voiceCleanupMutex.withLock {
        val digest=MessageDigest.getInstance("SHA-256")
        draft.microphone.inputStream().use{input->val buffer=ByteArray(64*1024);while(true){currentCoroutineContext().ensureActive();val n=input.read(buffer);if(n<0)break;digest.update(buffer,0,n)}}
        val hash=digest.digest().joinToString(""){"%02x".format(it)}
        val cleaned=File(draft.directory,"microphone-clean-v1.wav")
        val stamp=File(draft.directory,"microphone-clean-v1.sha256")
        val sameLength=runCatching{WaveReader(cleaned).use{it.frames}==WaveReader(draft.microphone).use{it.frames}}.getOrDefault(false)
        if(!sameLength||!stamp.isFile||stamp.readText()!=hash) {
            cleanVoiceWave(draft.microphone,cleaned)
            val pending=File(draft.directory,".voice-clean-stamp")
            pending.writeText(hash);check(pending.renameTo(stamp)){"The cleaned voice cache could not be saved. Your original audio is safe."}
        }
        cleaned
    }}
}
