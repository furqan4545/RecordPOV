package studio.roast.app

data class VoiceProtectionStatus(val sessionActive:Boolean=false,val echoCancellation:Boolean=false,
                                 val noiseSuppression:Boolean=false,val silenced:Boolean=false) {
    val description:String get()=when {
        silenced->"Android has muted your microphone. Check microphone privacy controls."
        !sessionActive->"Microphone protection is not verified yet."
        else->"Echo control ${if(echoCancellation)"on"else "unavailable"} · Noise reduction ${if(noiseSuppression)"on"else "unavailable"}"
    }
}

/** Availability or a successful enable request alone is not evidence of processing an active session. */
fun verifiedVoiceEffect(sessionId:Int?,captureActive:Boolean,silenced:Boolean,enabledDescriptor:Boolean,
                        handleSessionId:Int?,handleEnabled:Boolean):Boolean =
    captureActive&&!silenced&&sessionId!=null&&sessionId>0&&
        (enabledDescriptor||(handleSessionId==sessionId&&handleEnabled))
