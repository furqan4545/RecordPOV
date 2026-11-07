package studio.roast.app

import android.content.Context
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineWhisperModelConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlin.math.sqrt

/** Offline file inference only: neither SpeechRecognizer nor a microphone input is used. */
class OfflineCaptions(private val context:Context) {
    private data class ModelFile(val name:String,val bytes:Long,val sha256:String)
    private val files=listOf(
        ModelFile("tiny-encoder.int8.onnx",12_937_772,"d24fb083ae3b1041fc24e97971d60e280c9342201fbb67b0ab428a8b4a51a434"),
        ModelFile("tiny-decoder.int8.onnx",89_855_401,"d2fece8dd42771f1df975c6c0445770d0c292bf7547c2cae04a6c0cc57540925"),
        ModelFile("tiny-tokens.txt",816_730,"b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126"))
    private val base="https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny/resolve/65176e2deb88badc814a94058666cadccc29b61c/"
    private fun hash(file:File):String {
        val digest=MessageDigest.getInstance("SHA-256")
        file.inputStream().use{input->val buffer=ByteArray(64*1024);while(true){val n=input.read(buffer);if(n<0)break;digest.update(buffer,0,n)}}
        return digest.digest().joinToString(""){"%02x".format(it)}
    }
    private suspend fun ensureModel(progress:suspend(String,Float?)->Unit):File=withContext(Dispatchers.IO) {
        val root=File(context.filesDir,"speech/whisper-tiny-int8-65176e2").apply{mkdirs()}
        val total=files.sumOf{it.bytes};var completed=0L
        for(model in files) {
            currentCoroutineContext().ensureActive()
            val destination=File(root,model.name)
            if(destination.length()==model.bytes&&hash(destination)==model.sha256){completed+=model.bytes;continue}
            val temporary=File(root,"${model.name}.download")
            val connection=URL(base+model.name).openConnection() as HttpURLConnection
            try {
                connection.connectTimeout=15_000;connection.readTimeout=10_000
                check(connection.responseCode==200){"The speech model could not be downloaded. Check your connection and try again."}
                var received=0L;var lastUpdate=0L
                connection.inputStream.use{input->temporary.outputStream().use{output->
                    val buffer=ByteArray(64*1024)
                    while(true) {
                        currentCoroutineContext().ensureActive()
                        val n=input.read(buffer);if(n<0)break
                        received+=n;check(received<=model.bytes){"The downloaded speech model has an unexpected size."}
                        output.write(buffer,0,n)
                        val now=System.nanoTime()
                        if(now-lastUpdate>150_000_000){lastUpdate=now;progress("Downloading speech model · ${(completed+received)*100/total}%",(completed+received).toFloat()/total)}
                    }
                }}
                check(received==model.bytes&&hash(temporary)==model.sha256){"Speech model verification failed. Please try the download again."}
                check(temporary.renameTo(destination)){"The speech model could not be stored on this phone."}
                completed+=model.bytes
            }finally{connection.disconnect();temporary.delete()}
        }
        root
    }
    suspend fun generate(draft:ReactionDraft,language:String,onProgress:(String,Float?)->Unit):List<CaptionCue> {
        require(language in setOf("","en","ur","hi","ko")){"Choose a supported caption language."}
        suspend fun progress(label:String,value:Float?){withContext(Dispatchers.Main){onProgress(label,value)}}
        val root=ensureModel(::progress)
        return withContext(Dispatchers.Default) {
            check(draft.audioReady){"Prepare the microphone stem before generating captions."}
            progress("Finding speech in your microphone…",null)
            // This is deliberately the isolated, pre-mix microphone file. Source/music never enter ASR.
            WaveReader(draft.microphone).use {mic ->
                val activity=mutableListOf<Float>();var cursor=0L
                val window=STEM_SAMPLE_RATE/50
                while(cursor<mic.frames) {
                    currentCoroutineContext().ensureActive()
                    val block=mic.read(cursor,minOf(window.toLong(),mic.frames-cursor).toInt())
                    activity+=sqrt(block.sumOf{it.toDouble()*it}/block.size).toFloat();cursor+=block.size
                }
                val ranges=microphoneSpeechRanges(activity,draft.durationMs)
                if(ranges.isEmpty())return@use emptyList<CaptionCue>()
                progress("Loading on-device speech model…",null)
                val model=OfflineModelConfig(whisper=OfflineWhisperModelConfig(
                    encoder=File(root,"tiny-encoder.int8.onnx").absolutePath,decoder=File(root,"tiny-decoder.int8.onnx").absolutePath,
                    language=language,task="transcribe",tailPaddings=300,enableTokenTimestamps=false,enableSegmentTimestamps=false),
                    tokens=File(root,"tiny-tokens.txt").absolutePath,numThreads=2,provider="cpu",modelType="whisper",debug=false)
                val recognizer=try{OfflineRecognizer(config=OfflineRecognizerConfig(featConfig=FeatureConfig(sampleRate=16_000,featureDim=80),modelConfig=model))}
                    catch(e:LinkageError){throw IllegalStateException("The offline speech runtime is unavailable on this device. Your draft and microphone audio are safe.",e)}
                try {
                    val captions=mutableListOf<CaptionCue>()
                    ranges.forEachIndexed{index,range ->
                        currentCoroutineContext().ensureActive()
                        progress("Transcribing your microphone · ${index+1}/${ranges.size}",index.toFloat()/ranges.size)
                        val input=mic.read(frameAtMs(range.startMs),(frameAtMs(range.endMs)-frameAtMs(range.startMs)).toInt())
                        val samples=FloatArray((input.size.toLong()*16_000/STEM_SAMPLE_RATE+2).toInt());var count=0
                        val resampler=MonoResampler(STEM_SAMPLE_RATE,16_000){samples[count++]=it}
                        input.forEach(resampler::accept)
                        val stream=recognizer.createStream()
                        try {
                            stream.acceptWaveform(samples.copyOf(count),16_000);recognizer.decode(stream)
                            currentCoroutineContext().ensureActive()
                            val text=recognizer.getResult(stream).text.trim()
                            if(text.isNotBlank())captions+=CaptionCue(range.startMs,range.endMs,text)
                        }finally{stream.release()}
                    }
                    captions
                }finally{recognizer.release()}
            }
        }
    }
}
