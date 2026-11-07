package studio.roast.app

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin
import kotlin.math.sqrt
import kotlinx.coroutines.runBlocking
import java.io.File
import java.nio.file.Files
import org.json.JSONObject

class StemMixerTest {
    private fun tone(hz:Double,seconds:Int,amplitude:Float)=FloatArray(STEM_SAMPLE_RATE*seconds){(sin(2*PI*hz*it/STEM_SAMPLE_RATE)*amplitude).toFloat()}
    private fun amplitude(signal:ShortArray,hz:Double,startMs:Int,endMs:Int):Double {
        val start=frameAtMs(startMs.toLong()).toInt();val end=frameAtMs(endMs.toLong()).toInt()
        var real=0.0;var imaginary=0.0
        for(i in start until end){val phase=2*PI*hz*i/STEM_SAMPLE_RATE;val value=signal[i]/32767.0
            real+=value*sin(phase);imaginary+=value*kotlin.math.cos(phase)}
        return 2*sqrt(real*real+imaginary*imaginary)/(end-start)
    }
    @Test fun newEditsLowerOnlyTheMicrophoneToSixtyPercent() {
        val mic=tone(220.0,1,.2f);val source=tone(440.0,1,.2f);val music=tone(880.0,1,.2f)
        val mixed=StemMixer.mix(mic,source,music,DraftEdits(trimEndMs=1_000).gains,mic.size)
        assertEquals(.12,amplitude(mixed,220.0,0,1_000),.001)
        assertEquals(.2,amplitude(mixed,440.0,0,1_000),.001)
        assertEquals(.05,amplitude(mixed,880.0,0,1_000),.001)
    }
    @Test fun missingLegacyMicrophoneGainUsesSixtyPercentButExplicitEditsRemainExact() {
        assertEquals(.6f,storedMixGains(JSONObject()).microphone,0f)
        for(value in listOf(0f,.6f,1f,1.35f)) {
            val saved=JSONObject(JSONObject().put("microphoneGain",value).put("sourceGain",.4).put("musicGain",.1).toString())
            val gains=storedMixGains(saved)
            assertEquals(value,gains.microphone,0f)
            assertEquals(.4f,gains.source,0f);assertEquals(.1f,gains.music,0f)
        }
    }
    @Test fun sourceAndMicrophoneAreAudibleAndSourcePausesDoNotMuteNarration() {
        val mic=tone(220.0,3,.18f);val original=tone(440.0,3,.24f);val source=FloatArray(mic.size)
        for((timeline,input,length) in listOf(Triple(0L,0L,800L),Triple(1800L,800L,1200L))) {
            val span=sourceStemSpan(timeline,input,length,source.size.toLong())!!
            original.copyInto(source,span.outputFrame.toInt(),span.inputFrame.toInt(),(span.inputFrame+span.frames).toInt())
        }
        val mixed=StemMixer.mix(mic,source,FloatArray(0),MixGains(source=1f,microphone=1f,music=0f),mic.size)
        assertEquals(.18,amplitude(mixed,220.0,100,700),.001)
        assertEquals(.24,amplitude(mixed,440.0,100,700),.001)
        assertEquals(.18,amplitude(mixed,220.0,1000,1600),.001)
        assertTrue("Original source must be silent during the pause",amplitude(mixed,440.0,1000,1600)<.0001)
        assertEquals(.24,amplitude(mixed,440.0,2000,2800),.001)
        val rms=sqrt(mixed.map{it.toDouble()*it/32767.0/32767.0}.average())
        assertTrue("The rendered PCM must contain audible energy",rms>.15)
    }
    @Test fun threeIndependentGainsAndMutesAffectOnlyTheirOwnStem() {
        val mic=tone(220.0,1,.2f);val source=tone(440.0,1,.2f);val music=tone(880.0,1,.2f)
        val mixed=StemMixer.mix(mic,source,music,MixGains(source=2f,microphone=0f,music=.5f),mic.size)
        assertTrue(amplitude(mixed,220.0,0,1000)<.0001)
        assertEquals(.4,amplitude(mixed,440.0,0,1000),.001)
        assertEquals(.1,amplitude(mixed,880.0,0,1000),.001)
        assertTrue(StemMixer.mix(mic,source,music,MixGains(0f,0f,0f),mic.size).all{it==0.toShort()})
    }
    @Test fun limitingAndGainBoundsDoNotWrapPcmSamplesOrCreateNan() {
        val mixed=StemMixer.mix(floatArrayOf(1f,-1f,Float.NaN),floatArrayOf(1f,-1f,0f),FloatArray(0),MixGains(20f,20f,0f),3)
        assertArrayEquals(shortArrayOf(32767,-32767,0),mixed)
    }
    @Test fun sourceTimelineUsesExactSeekPositionsAndClipsAtTakeEnd() {
        val span=sourceStemSpan(500,2_000,900,frameAtMs(1_000))!!
        assertEquals(frameAtMs(500),span.outputFrame)
        assertEquals(frameAtMs(2_000),span.inputFrame)
        assertEquals(frameAtMs(500),span.frames)
        assertNull(sourceStemSpan(1_100,0,500,frameAtMs(1_000)))
    }
    @Test fun productionTimelineOmitsSourcePausesAndRetainsSeekOffsets() {
        val timeline=SourceAudioTimeline()
        timeline.begin("clip",0,1_000)
        timeline.close(1_800,800)
        // Narration continues alone from 800ms to1800ms.
        timeline.begin("clip",1_800,1_800)
        timeline.close(2_300,2_300)
        timeline.begin("clip",2_300,5_000)
        timeline.close(5_700,3_000)
        assertEquals(listOf(TimelineAudioSpan("clip",0,1_000,800),TimelineAudioSpan("clip",1_800,1_800,500),TimelineAudioSpan("clip",2_300,5_000,700)),timeline.segments)
    }
    @Test fun resamplingPreservesAnAudibleToneAtTheCaptionBackendRate() {
        val output=mutableListOf<Float>()
        val resampler=MonoResampler(STEM_SAMPLE_RATE,16_000,output::add)
        tone(440.0,1,.2f).forEach(resampler::accept)
        assertEquals(16_000,output.size)
        val energy=sqrt(output.map{it.toDouble()*it}.average())
        assertTrue(abs(energy-.2/sqrt(2.0))<.001)
    }
    @Test fun trimAndOverlappingDeletedIntervalsKeepOriginalTimeMapping() {
        assertEquals(listOf(EditRange(200,500),EditRange(1_600,2_800)),retainedRanges(3_000,200,2_800,listOf(EditRange(500,1_200),EditRange(900,1_600))))
        assertEquals(emptyList<EditRange>(),retainedRanges(3_000,0,3_000,listOf(EditRange(0,3_000))))
    }
    @Test fun captionTimesFollowTheSameTrimAndCutRangesAsAudioAndVideo() {
        val cues=editedCaptionCues(listOf(CaptionCue(400,1_400,"your words"),CaptionCue(1_800,2_400,"more words")),listOf(EditRange(200,800),EditRange(1_200,2_500)))
        assertEquals(listOf(CaptionCue(200,600,"your words"),CaptionCue(600,800,"your words"),CaptionCue(1_200,1_800,"more words")),cues)
    }
    @Test fun productionWaveFilesAndDraftMixerPreserveBothStemsAcrossAPause()=runBlocking {
        val root=Files.createTempDirectory("roast-audio-test").toFile()
        try {
            val original=File(root,"original.wav")
            WaveWriter(original).use{writer->tone(440.0,3,.24f).forEach(writer::sample)}
            WaveWriter(File(root,"microphone.wav")).use{writer->tone(220.0,3,.18f).forEach(writer::sample)}
            val source=File(root,"source.wav");createSilentWave(source,frameAtMs(3_000))
            listOf(Triple(0L,0L,800L),Triple(1_800L,800L,1_200L)).forEach{(timeline,input,length)->
                copyWaveSpan(original,source,sourceStemSpan(timeline,input,length,frameAtMs(3_000))!!)
            }
            val draft=ReactionDraft("test","Synthetic",3_000,root,DraftEdits(gains=MixGains(microphone=1f),trimEndMs=3_000,voiceCleanupEnabled=false),sourceAvailable=true)
            val mixed=File(root,"rendered.wav");mixDraftAudio(draft,mixed)
            WaveReader(mixed).use{reader ->
                assertEquals(frameAtMs(3_000),reader.frames)
                assertTrue(reader.rms()>.15)
                val pcm=reader.read(0,reader.frames.toInt()).map{(it*32767).toInt().toShort()}.toShortArray()
                assertEquals(.18,amplitude(pcm,220.0,100,700),.001)
                assertEquals(.24,amplitude(pcm,440.0,100,700),.001)
                assertEquals(.18,amplitude(pcm,220.0,1_000,1_600),.001)
                assertTrue(amplitude(pcm,440.0,1_000,1_600)<.0001)
                assertEquals(.24,amplitude(pcm,440.0,2_000,2_800),.001)
            }
        }finally{root.deleteRecursively()}
    }
    @Test fun speechSegmentationSkipsSilenceAndBoundsRealCaptionIntervals() {
        val windows=List(500){if(it in 50..99||it in 200..449).02f else 0f}
        assertEquals(listOf(EditRange(900,2_100),EditRange(3_900,9_100)),microphoneSpeechRanges(windows,10_000))
        assertTrue(microphoneSpeechRanges(List(1_000){.02f},20_000).all{it.durationMs<=6_000})
        assertTrue(microphoneSpeechRanges(List(1_000){0f},20_000).isEmpty())
    }
    @Test fun retryingASilentStemErasesPreviousAudioInsteadOfKeepingOldPcm() {
        val root=Files.createTempDirectory("roast-silence-test").toFile()
        try {
            val file=File(root,"source.wav")
            WaveWriter(file).use{writer->tone(440.0,1,.3f).forEach(writer::sample)}
            createSilentWave(file,STEM_SAMPLE_RATE.toLong())
            WaveReader(file).use{assertEquals(0.0,it.rms(),0.0)}
        }finally{root.deleteRecursively()}
    }
    @Test fun decoderTimestampPlacementKeepsTrackOffsetsAndCropsNegativePriming() {
        assertEquals(PcmTimestampPlacement(frameAtMs(500),0),pcmTimestampPlacement(500_000,48_000,1_024))
        assertEquals(PcmTimestampPlacement(0,480),pcmTimestampPlacement(-10_000,48_000,1_024))
        val root=Files.createTempDirectory("roast-timestamp-test").toFile()
        try {
            val file=File(root,"timed.wav")
            WaveWriter(file).use{writer->
                writer.position(pcmTimestampPlacement(500_000,STEM_SAMPLE_RATE,STEM_SAMPLE_RATE/2).outputFrame)
                tone(440.0,1,.2f).take(STEM_SAMPLE_RATE/2).forEach(writer::sample)
            }
            WaveReader(file).use{reader->
                assertEquals(STEM_SAMPLE_RATE.toLong(),reader.frames)
                assertTrue(reader.read(0,STEM_SAMPLE_RATE/2).all{it==0f})
                assertTrue(reader.read(STEM_SAMPLE_RATE/2L,STEM_SAMPLE_RATE/2).any{abs(it)>.1f})
            }
        }finally{root.deleteRecursively()}
    }
}
