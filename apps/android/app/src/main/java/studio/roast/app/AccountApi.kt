package studio.roast.app

import kotlinx.coroutines.suspendCancellableCoroutine
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
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal class AccountApiException(val status:Int,val code:String,message:String):IOException(message)
internal class AccountApi {
    private val client=OkHttpClient.Builder().connectTimeout(15,TimeUnit.SECONDS).readTimeout(20,TimeUnit.SECONDS)
        .callTimeout(25,TimeUnit.SECONDS).followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).build()
    suspend fun config()=AccountConfig.parse(request("GET","/v1/auth/config"))
    suspend fun signIn(token:String,nonce:String,name:String?)=AccountSession.parse(request("POST","/v1/auth/sign-in",
        JSONObject().put("provider","google").put("idToken",token).put("nonce",nonce).put("name",name)))
    suspend fun session(token:String)=request("GET","/v1/auth/session",token=token)
    suspend fun signOut(token:String){request("POST","/v1/auth/sign-out",JSONObject(),token)}
    suspend fun delete(token:String){request("DELETE","/v1/auth/account",token=token)}
    suspend fun appleStart(challenge:String,state:String)=request("POST","/v1/auth/apple/browser/start",JSONObject().put("codeChallenge",challenge).put("state",state))
    suspend fun appleExchange(code:String,verifier:String)=AccountSession.parse(request("POST","/v1/auth/apple/browser/exchange",JSONObject().put("code",code).put("codeVerifier",verifier)))
    private suspend fun request(method:String,path:String,body:JSONObject?=null,token:String?=null):JSONObject {
        val payload=body?.toString()?.toRequestBody("application/json; charset=utf-8".toMediaType())
        val request=Request.Builder().url(AccountBrowserPolicy.BASE+path).method(method,payload)
            .apply{if(token!=null)header("Authorization","Bearer $token")}.build()
        val call=client.newCall(request)
        return suspendCancellableCoroutine {continuation ->
            continuation.invokeOnCancellation{call.cancel()}
            call.enqueue(object:Callback {
                override fun onFailure(call:Call,e:IOException) {
                    if(continuation.isActive)continuation.resumeWithException(IOException("Account could not connect. Check your connection and try again."))
                }
                override fun onResponse(call:Call,response:Response) {
                    try {
                        val result=response.use {
                            if(response.code==204)return@use JSONObject()
                            val output=ByteArrayOutputStream();val buffer=ByteArray(4096)
                            response.body.byteStream().use {input->while(true){val count=input.read(buffer);if(count<0)break;require(count<=65536-output.size());output.write(buffer,0,count)}}
                            val json=runCatching{JSONObject(output.toString(Charsets.UTF_8.name()))}.getOrNull()
                            if(!response.isSuccessful) {
                                val error=json?.optJSONObject("error")
                                throw AccountApiException(response.code,error?.optString("code").orEmpty(),
                                    error?.optString("message")?.takeIf{it.isNotBlank()}?.take(300) ?: "Account request failed. Please try again.")
                            }
                            requireNotNull(json){"The account service returned an invalid response."}
                        }
                        if(continuation.isActive)continuation.resume(result)
                    }catch(e:Exception){if(continuation.isActive)continuation.resumeWithException(e)}
                }
            })
        }
    }
}
