package studio.roast.app

import android.animation.ValueAnimator
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext

@Composable internal fun homeMotionEnabled():Boolean {
    val resolver=LocalContext.current.contentResolver
    var enabled by remember{mutableStateOf(ValueAnimator.areAnimatorsEnabled())}
    DisposableEffect(resolver) {
        val observer=object:ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange:Boolean){enabled=ValueAnimator.areAnimatorsEnabled()}
        }
        resolver.registerContentObserver(Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE),false,observer)
        onDispose{resolver.unregisterContentObserver(observer)}
    }
    return enabled
}
