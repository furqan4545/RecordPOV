package studio.roast.app

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat

class MainActivity: ComponentActivity() {
    private var notice by mutableStateOf<String?>(null)
    private var pendingGranted: (() -> Unit)? = null
    private var pendingDenied: (() -> Unit)? = null
    private var screenStyle = PipStyle.Rounded
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        prepareScreenCapture()
    }
    private val runtimePermission = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        if (result[Manifest.permission.CAMERA] == true && result[Manifest.permission.RECORD_AUDIO] == true) pendingGranted?.invoke()
        else pendingDenied?.invoke()
        pendingGranted = null; pendingDenied = null
    }
    private val overlayPermission = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        if (Settings.canDrawOverlays(this)) requestProjection()
        else notice = "Allow ‘Display over other apps’ to float your camera during a screen recording."
    }
    private val projectionPermission = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK && result.data != null) {
            ContextCompat.startForegroundService(this,Intent(this,ScreenTakeService::class.java).apply {
                putExtra(ScreenTakeService.EXTRA_RESULT_CODE,result.resultCode)
                putExtra(ScreenTakeService.EXTRA_DATA,result.data)
                putExtra(ScreenTakeService.EXTRA_STYLE,screenStyle.name)
            })
            notice = "Screen recording is starting. Open the app you want to show; stop from the floating button or notification."
        } else notice = "Screen recording was not started."
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        consumeAccountReturn(intent)
        setContent { RoastApp(
            notice = notice, clearNotice = { notice = null },
            enableCamera = { granted, denied -> requestCamera(granted,denied) },
            startScreenTake = { style ->
                screenStyle = style
                requestCamera({
                    if(Build.VERSION.SDK_INT>=33 && ContextCompat.checkSelfPermission(this,Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED)
                        notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                    else prepareScreenCapture()
                }, { notice = "Camera and microphone access are needed for a screen recording." })
            }
        ) }
    }
    override fun onNewIntent(intent:Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        consumeAccountReturn(intent)
    }
    private fun consumeAccountReturn(incoming:Intent?) {
        val value=incoming?.data?.toString() ?: return
        if(RecordPovAccounts.get(this).handleAppleReturn(value))incoming.data=null
    }
    private fun prepareScreenCapture() {
        if (Settings.canDrawOverlays(this)) requestProjection()
        else overlayPermission.launch(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,Uri.parse("package:$packageName")))
    }

    private fun requestCamera(granted: () -> Unit, denied: () -> Unit) {
        if (ContextCompat.checkSelfPermission(this,Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(this,Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED) granted()
        else {
            pendingGranted = granted; pendingDenied = denied
            runtimePermission.launch(arrayOf(Manifest.permission.CAMERA,Manifest.permission.RECORD_AUDIO))
        }
    }
    private fun requestProjection() {
        val manager=getSystemService(MediaProjectionManager::class.java)
        val request=if(Build.VERSION.SDK_INT>=34) manager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
            else manager.createScreenCaptureIntent()
        projectionPermission.launch(request)
    }
}
