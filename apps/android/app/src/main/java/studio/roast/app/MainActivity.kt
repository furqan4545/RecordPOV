package studio.roast.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat

class MainActivity: ComponentActivity() {
    private var pendingGranted: (() -> Unit)? = null
    private var pendingDenied: (() -> Unit)? = null
    private val runtimePermission = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        if (result[Manifest.permission.CAMERA] == true && result[Manifest.permission.RECORD_AUDIO] == true) pendingGranted?.invoke()
        else pendingDenied?.invoke()
        pendingGranted = null; pendingDenied = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        consumeAccountReturn(intent)
        setContent { RoastApp(
            enableCamera = { granted, denied -> requestCamera(granted,denied) }
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

    private fun requestCamera(granted: () -> Unit, denied: () -> Unit) {
        if (ContextCompat.checkSelfPermission(this,Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(this,Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED) granted()
        else {
            pendingGranted = granted; pendingDenied = denied
            runtimePermission.launch(arrayOf(Manifest.permission.CAMERA,Manifest.permission.RECORD_AUDIO))
        }
    }
}
