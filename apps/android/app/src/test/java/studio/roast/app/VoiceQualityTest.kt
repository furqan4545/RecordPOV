package studio.roast.app

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.Random
import kotlin.math.*

class VoiceQualityTest {
    private fun hash(file:File)=MessageDigest.getInstance("SHA-256").digest(file.readBytes()).toList()
    private fun tone(hz:Double,amplitude:Double,index:Int)=sin(2*PI*hz*index/STEM_SAMPLE_RATE)*amplitude
    private fun write(file:File,seconds:Int,sample:(Int)->Double){WaveWriter(file).use{writer->repeat(seconds*STEM_SAMPLE_RATE){writer.sample(sample(it).toFloat())}}}
    private fun samples(file:File,start:Double,end:Double)=WaveReader(file).use{it.read((start*STEM_SAMPLE_RATE).toLong(),((end-start)*STEM_SAMPLE_RATE).toInt())}
    private fun rms(values:FloatArray)=sqrt(values.sumOf{it.toDouble()*it}/values.size)
    private fun amplitude(values:FloatArray,hz:Double,start:Double):Double {
        var real=0.0;var imaginary=0.0
        values.forEachIndexed{i,value->val phase=2*PI*hz*(i+start*STEM_SAMPLE_RATE)/STEM_SAMPLE_RATE;real+=value*sin(phase);imaginary+=value*cos(phase)}
        return 2*hypot(real,imaginary)/values.size
    }
    @Test fun liveEffectsNeedAnActiveMatchingSessionAndReadbackOrEnabledDescriptor() {
        assertFalse(verifiedVoiceEffect(null,true,false,false,null,true))
        assertFalse(verifiedVoiceEffect(11,true,false,false,10,true))
        assertFalse(verifiedVoiceEffect(11,true,false,false,11,false))
        assertTrue(verifiedVoiceEffect(11,true,false,false,11,true))
        assertTrue(verifiedVoiceEffect(11,true,false,true,null,false))
    }
    @Test fun pausedAndSystemSilencedCaptureNeverClaimsProtectionIsActive() {
        assertFalse(verifiedVoiceEffect(11,false,false,true,11,true))
        assertFalse(verifiedVoiceEffect(11,true,true,true,11,true))
        assertTrue(VoiceProtectionStatus(sessionActive=true,silenced=true).description.contains("muted"))
    }
    @Test fun newTakesDefaultToGentleCleanupButLegacyOptOutSurvivesTrimming() {
        assertTrue(DraftEdits(trimEndMs=5_000).voiceCleanupEnabled)
        val legacy=DraftEdits(trimEndMs=5_000,voiceCleanupEnabled=false)
        assertFalse(contiguousTrimEdits(legacy,TrimBounds(500,4_000),5_000).voiceCleanupEnabled)
    }
    @Test fun highPassReducesRumbleWithoutAGainBoost() {
        val low=VoiceHighPass();val high=VoiceHighPass()
        val rumble=FloatArray(2*STEM_SAMPLE_RATE){low.process((.2+tone(30.0,.1,it)).toFloat())}
        val voice=FloatArray(2*STEM_SAMPLE_RATE){high.process(tone(1_000.0,.1,it).toFloat())}
        val a=rumble.copyOfRange(STEM_SAMPLE_RATE,rumble.size)
        val b=voice.copyOfRange(STEM_SAMPLE_RATE,voice.size)
        assertTrue(amplitude(a,30.0,1.0)<.025)
        assertTrue(abs(a.average())<.00001)
        assertEquals(.1,amplitude(b,1_000.0,1.0),.001)
    }
    @Test fun productionCleanupGentlyReducesStationaryHissAndPreservesSpeechEnergy()=runBlocking {
        val root=Files.createTempDirectory("roast-voice-hiss").toFile()
        try {
            val raw=File(root,"microphone.wav");val clean=File(root,"clean.wav");val random=Random(81)
            write(raw,4){i->random.nextGaussian()*.008+if(i in STEM_SAMPLE_RATE until 3*STEM_SAMPLE_RATE)tone(700.0,.12,i)else 0.0}
            val originalHash=hash(raw)
            cleanVoiceWave(raw,clean)
            val before=rms(samples(raw,.3,.8));val after=rms(samples(clean,.3,.8))
            val reduction=20*log10(before/after)
            assertTrue("Expected audible but gentle hiss reduction; measured $reduction dB",reduction in .7..6.5)
            val rawVoice=amplitude(samples(raw,1.3,2.7),700.0,1.3)
            val cleanVoice=amplitude(samples(clean,1.3,2.7),700.0,1.3)
            println("VOICE_CLEANUP_METRICS hissReductionDb=$reduction voiceAmplitudeRatio=${cleanVoice/rawVoice}")
            assertTrue("Voice should retain at least95% of its tone energy",cleanVoice/rawVoice>.95)
            assertTrue(cleanVoice/rawVoice<1.01)
            assertEquals(hash(raw),originalHash)
            assertEquals(WaveReader(raw).use{it.frames},WaveReader(clean).use{it.frames})
        }finally{root.deleteRecursively()}
    }
    @Test fun cleanQuietVoiceIsNotGatedAndSilenceStaysFinite()=runBlocking {
        val root=Files.createTempDirectory("roast-quiet-voice").toFile()
        try {
            val raw=File(root,"raw.wav");val clean=File(root,"clean.wav")
            write(raw,1){tone(1_000.0,.001,it)};cleanVoiceWave(raw,clean)
            assertTrue(rms(samples(clean,.2,.8))>.0005)
            write(raw,1){0.0};cleanVoiceWave(raw,clean)
            WaveReader(clean).use{assertEquals(STEM_SAMPLE_RATE.toLong(),it.frames);assertEquals(0.0,it.rms(),0.0)}
        }finally{root.deleteRecursively()}
    }
    @Test fun voiceCleanupIsReversibleAndNeverChangesRawSourceOrMusicFiles()=runBlocking {
        val root=Files.createTempDirectory("roast-voice-stems").toFile()
        try {
            val random=Random(22)
            val mic=File(root,"microphone.wav");val source=File(root,"source.wav");val music=File(root,"music.wav")
            write(mic,2){tone(700.0,.12,it)+random.nextGaussian()*.006}
            write(source,2){tone(440.0,.2,it)};write(music,2){tone(880.0,.08,it)}
            val originals=listOf(mic,source,music).map(::hash)
            val edits=DraftEdits(gains=MixGains(1f,1f,1f),trimEndMs=2_000,musicName="music.wav",voiceCleanupEnabled=false)
            val rawDraft=ReactionDraft("test","Test",2_000,root,edits,sourceAvailable=true)
            assertEquals(mic,microphoneForMix(rawDraft))
            val cleanedDraft=rawDraft.copy(edits=edits.copy(voiceCleanupEnabled=true))
            assertNotEquals(mic,microphoneForMix(cleanedDraft))
            val output=File(root,"mix.wav");mixDraftAudio(cleanedDraft,output)
            val values=samples(output,.4,1.6)
            assertEquals(.2,amplitude(values,440.0,.4),.001)
            assertEquals(.08,amplitude(values,880.0,.4),.001)
            assertEquals(originals,listOf(mic,source,music).map(::hash))
            assertEquals(mic,microphoneForMix(rawDraft))
        }finally{root.deleteRecursively()}
    }
    @Test fun cleanCacheTracksRawContentEvenIfItsLengthAndTimestampAreUnchanged()=runBlocking {
        val root=Files.createTempDirectory("roast-voice-cache").toFile()
        try {
            val mic=File(root,"microphone.wav");createSilentWave(File(root,"source.wav"),STEM_SAMPLE_RATE.toLong())
            write(mic,1){tone(440.0,.1,it)};val modified=mic.lastModified()
            val draft=ReactionDraft("test","Test",1_000,root,DraftEdits(trimEndMs=1_000))
            val first=hash(microphoneForMix(draft))
            write(mic,1){tone(880.0,.1,it)};mic.setLastModified(modified)
            val rawHash=hash(mic)
            assertNotEquals(first,hash(microphoneForMix(draft)))
            assertEquals(rawHash,hash(mic))
        }finally{root.deleteRecursively()}
    }
}
