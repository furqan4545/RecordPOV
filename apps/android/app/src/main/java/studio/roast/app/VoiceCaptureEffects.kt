package studio.roast.app

import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.media.AudioRouting
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.media.audiofx.NoiseSuppressor
import android.os.Handler
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.Closeable
import java.util.concurrent.Executor

/** Own-recorder effects only. No audio mode, output route, source gain, or playback settings are changed. */
class VoiceCaptureEffects(private val recorder:MediaRecorder,private val handler:Handler):Closeable {
    private val mutableStatus=MutableStateFlow(VoiceProtectionStatus())
    val status=mutableStatus.asStateFlow()
    @Volatile private var closed=false
    private var recording=false
    private var sessionId:Int?=null
    private var routeId:Int?=null
    private var epoch=0L
    private var echo:AcousticEchoCanceler?=null
    private var noise:NoiseSuppressor?=null
    private var callbackRegistered=false
    private var routeRegistered=false
    private val callback=object:AudioManager.AudioRecordingCallback() {
        override fun onRecordingConfigChanged(configs:MutableList<AudioRecordingConfiguration>){refresh()}
    }
    private val routing=AudioRouting.OnRoutingChangedListener{refresh()}
    private val poll=object:Runnable {
        override fun run(){if(!closed&&recording){refresh();handler.postDelayed(this,1_000)}}
    }
    init {
        val executor=Executor{command->if(!closed)handler.post(command)}
        callbackRegistered=runCatching{recorder.registerAudioRecordingCallback(executor,callback);true}.getOrDefault(false)
        routeRegistered=runCatching{recorder.addOnRoutingChangedListener(routing,handler);true}.getOrDefault(false)
    }
    fun started() {
        if(closed)return
        recording=true;refresh();handler.removeCallbacks(poll);handler.postDelayed(poll,1_000)
    }
    fun paused() {
        recording=false;handler.removeCallbacks(poll);releaseEffects();mutableStatus.value=VoiceProtectionStatus()
    }
    private fun refresh() {
        if(closed||!recording)return
        // Query this MediaRecorder rather than guessing from another app's recording callback entry.
        val config=runCatching{recorder.activeRecordingConfiguration}.getOrNull()
        val current=config?.clientAudioSessionId?.takeIf{it>0}
        if(config==null||current==null) {
            releaseEffects();mutableStatus.value=VoiceProtectionStatus();return
        }
        val device=runCatching{config.audioDevice?.id}.getOrNull()
        if(current!=sessionId||device!=routeId) {
            releaseEffects();sessionId=current;routeId=device
            val ownEpoch=epoch
            echo=runCatching{if(AcousticEchoCanceler.isAvailable())AcousticEchoCanceler.create(current)else null}.getOrNull()
            noise=runCatching{if(NoiseSuppressor.isAvailable())NoiseSuppressor.create(current)else null}.getOrNull()
            listOfNotNull(echo,noise).forEach{effect ->
                val changed={handler.post{if(!closed&&ownEpoch==epoch)refresh()};Unit}
                runCatching{effect.setEnableStatusListener{_,_->changed()}}
                runCatching{effect.setControlStatusListener{_,_->changed()}}
            }
        }
        fun enabled(effect:AudioEffect?):Boolean=runCatching {
            if(effect==null)return@runCatching false
            if(!effect.enabled&&effect.hasControl()) {
                if(effect.setEnabled(true)!=AudioEffect.SUCCESS)return@runCatching effect.enabled
            }
            effect.enabled
        }.getOrDefault(false)
        val echoReadback=enabled(echo);val noiseReadback=enabled(noise)
        val types=runCatching{(config.clientEffects+config.effects).map{it.type}.toSet()}.getOrDefault(emptySet())
        val silenced=runCatching{config.isClientSilenced}.getOrDefault(false)
        mutableStatus.value=VoiceProtectionStatus(sessionActive=true,
            echoCancellation=verifiedVoiceEffect(current,true,silenced,AudioEffect.EFFECT_TYPE_AEC in types,sessionId,echoReadback),
            noiseSuppression=verifiedVoiceEffect(current,true,silenced,AudioEffect.EFFECT_TYPE_NS in types,sessionId,noiseReadback),silenced=silenced)
    }
    private fun releaseEffects() {
        epoch++
        listOfNotNull(echo,noise).forEach{effect ->
            runCatching{effect.setEnableStatusListener(null)}
            runCatching{effect.setControlStatusListener(null)}
            runCatching{effect.release()}
        }
        echo=null;noise=null;sessionId=null;routeId=null
    }
    override fun close() {
        if(closed)return
        closed=true;recording=false;handler.removeCallbacks(poll)
        if(callbackRegistered)runCatching{recorder.unregisterAudioRecordingCallback(callback)}
        if(routeRegistered)runCatching{recorder.removeOnRoutingChangedListener(routing)}
        releaseEffects();mutableStatus.value=VoiceProtectionStatus()
    }
}
