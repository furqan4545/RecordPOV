package studio.roast.app

import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.Socket
import java.time.Instant
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** HTTP and relay are also usable on a JVM for explicit integration testing. */
internal object YouTubePhoneFetch {
    suspend fun resolve(
        base:String,url:String,client:OkHttpClient,
        lookup:(String)->List<InetAddress> ={InetAddress.getAllByName(it).toList()},bindSocket:(Socket)->Unit={},
        resolvePath:String="/v1/media/resolve"
    ):JSONObject=coroutineScope {
        require(resolvePath in listOf("/v1/media/resolve","/v2/media/resolve"))
        YouTubeTransportPolicy.apiEndpoint(base) // capability creation must also use HTTPS
        val session=post(client,base,"/v1/media/youtube/sessions",JSONObject().put("url",url),20)
        val id=session.getString("sessionId");val token=session.getString("token")
        val endpoint=YouTubeTransportPolicy.socketEndpoint(base,id,token,session.getString("socketUrl"))
        val remaining=Instant.parse(session.getString("expiresAt")).toEpochMilli()-System.currentTimeMillis()
        require(remaining>0) { "The YouTube connection expired. Please try again." }
        withTimeout(minOf(remaining,YouTubeTransportPolicy.SESSION_MILLIS)) {
            val relay=YouTubePhoneRelay(this,client,lookup,bindSocket)
            try {
                relay.attach(endpoint,token)
                val response=async {post(client,base,resolvePath,JSONObject().put("url",url).put("youtubeSessionId",id),650,token)}
                select<JSONObject> {response.onAwait{it};relay.failure.onAwait{throw it}}
            } finally {relay.close()} // close the phone path before local normalized-MP4 transfer
        }
    }

    internal suspend fun post(client:OkHttpClient,base:String,path:String,body:JSONObject,timeoutSeconds:Long,token:String?=null):JSONObject {
        val request=Request.Builder().url(base.trimEnd('/')+path)
            .post(body.toString().toRequestBody("application/json; charset=utf-8".toMediaType()))
            .apply{if(token!=null)header("X-YouTube-Session-Token",token)}.build()
        val call=client.newBuilder().readTimeout(timeoutSeconds,TimeUnit.SECONDS)
            .callTimeout(timeoutSeconds,TimeUnit.SECONDS).build().newCall(request)
        return suspendCancellableCoroutine { continuation ->
            continuation.invokeOnCancellation{call.cancel()}
            call.enqueue(object:Callback {
                override fun onFailure(call:Call,e:IOException) {
                    if(continuation.isActive)continuation.resumeWithException(IOException("Your phone’s connection was interrupted. Please try the video again."))
                }
                override fun onResponse(call:Call,response:Response) {
                    try {
                        val result=response.use {
                            val bytes=ByteArrayOutputStream();val buffer=ByteArray(4096)
                            response.body.byteStream().use {input ->while(true) {
                                val count=input.read(buffer);if(count<0)break
                                require(count<=65_536-bytes.size()) {"The video service returned an invalid response."}
                                bytes.write(buffer,0,count)
                            }}
                            val data=JSONObject(YouTubeRelayWire.text(bytes.toByteArray()))
                            if(!response.isSuccessful) {
                                val error=data.opt("error")
                                val message=if(error is JSONObject)error.optString("message")else error as? String
                                throw IOException(message?.takeIf{it.isNotBlank()} ?: "This video could not be opened. Please try again.")
                            }
                            data
                        }
                        if(continuation.isActive)continuation.resume(result)
                    } catch(e:Exception) {if(continuation.isActive)continuation.resumeWithException(e)}
                }
            })
        }
    }
}
