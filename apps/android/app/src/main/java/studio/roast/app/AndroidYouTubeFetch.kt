package studio.roast.app

import android.content.Context
import android.content.ContextWrapper
import android.net.ConnectivityManager
import android.net.Network
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.job
import kotlinx.coroutines.withContext
import okhttp3.Dns
import org.json.JSONObject

/** The phone route exists only for this foreground import on this one network. */
internal suspend fun fetchYouTubeOnPhone(context:Context,base:String,url:String,resolvePath:String="/v1/media/resolve",foregroundManaged:Boolean=false):JSONObject=coroutineScope {
    val owner=if(foregroundManaged)null else context.lifecycleOwner() ?: error("Keep RecordPOV open while downloading your YouTube video.")
    val job=currentCoroutineContext().job
    val lifecycleObserver=LifecycleEventObserver {_,event ->
        if(event==Lifecycle.Event.ON_STOP)job.cancel(CancellationException("YouTube fetching stopped when RecordPOV left the foreground."))
    }
    val connectivity=context.getSystemService(ConnectivityManager::class.java)
    val network=connectivity.activeNetwork ?: error("Connect your phone to the internet and try again.")
    val networkObserver=object:ConnectivityManager.NetworkCallback() {
        override fun onLost(lost:Network) {if(lost==network)job.cancel(CancellationException("The phone connection changed. Please try again."))}
        override fun onAvailable(available:Network) {if(available!=network)job.cancel(CancellationException("The phone connection changed. Please try again."))}
    }
    var watchingLifecycle=false;var watchingNetwork=false
    // New pool per network: never reuse a capability-bearing connection from a different route.
    val client=YouTubePhoneRelay.client().newBuilder().socketFactory(network.socketFactory)
        .dns(object:Dns {override fun lookup(hostname:String)=network.getAllByName(hostname).toList()}).build()
    try {
        if(owner!=null)withContext(Dispatchers.Main.immediate) {
            check(owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) {"Keep RecordPOV open while downloading your YouTube video."}
            owner.lifecycle.addObserver(lifecycleObserver);watchingLifecycle=true
        }
        connectivity.registerDefaultNetworkCallback(networkObserver);watchingNetwork=true
        YouTubePhoneFetch.resolve(base,url,client,lookup={network.getAllByName(it).toList()},bindSocket=network::bindSocket,resolvePath=resolvePath)
    } finally {
        if(watchingNetwork)runCatching{connectivity.unregisterNetworkCallback(networkObserver)}
        withContext(NonCancellable+Dispatchers.Main.immediate) {if(watchingLifecycle)owner?.lifecycle?.removeObserver(lifecycleObserver)}
        client.dispatcher.cancelAll();client.connectionPool.evictAll();client.dispatcher.executorService.shutdown()
    }
}

private fun Context.lifecycleOwner():LifecycleOwner? {
    var current=this
    repeat(12) {
        if(current is LifecycleOwner)return current as LifecycleOwner
        val wrapper=current as? ContextWrapper ?: return null
        val next=wrapper.baseContext;if(next===current)return null
        current=next
    }
    return null
}
