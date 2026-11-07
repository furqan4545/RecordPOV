package studio.roast.app

import org.json.JSONObject
import java.net.URI
import java.net.URLDecoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Instant
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal data class AccountUser(val id:String,val name:String,val email:String) {
    fun json()=JSONObject().put("id",id).put("name",name).put("email",email)
    companion object {
        fun parse(json:JSONObject)=AccountUser(json.getString("id").also{require(it.isNotBlank()&&it.length<=256)},
            json.optString("name").take(256),json.optString("email").take(320))
    }
}
internal data class AccountSession(val token:String,val expiresAt:String,val user:AccountUser) {
    fun json()=JSONObject().put("token",token).put("expiresAt",expiresAt).put("user",user.json())
    fun valid(now:Long=System.currentTimeMillis())=runCatching{Instant.parse(expiresAt).toEpochMilli()>now}.getOrDefault(false)
    override fun toString()="AccountSession(token=[redacted], user=[redacted])"
    companion object {
        fun parse(json:JSONObject)=AccountSession(json.getString("token").also{
            require(it.matches(Regex("[A-Za-z0-9._~+/-]{16,4096}={0,2}"))) {"Invalid account session."}
        },json.getString("expiresAt").also{Instant.parse(it)},AccountUser.parse(json.getJSONObject("user")))
    }
}
internal data class AccountConfig(val googleClientId:String?=null,val appleCallback:String?=null) {
    val available get()=googleClientId!=null||appleCallback!=null
    companion object {
        fun parse(json:JSONObject):AccountConfig {
            require(json.getInt("version")==1)
            if(!json.optBoolean("enabled"))return AccountConfig()
            val google=json.optJSONObject("providers")?.optJSONObject("google")
            val googleId=google?.optString("serverClientId")?.takeIf{
                google.optBoolean("enabled") && it.matches(Regex("[A-Za-z0-9_-]+\\.apps\\.googleusercontent\\.com"))
            }
            val callback=json.optString("androidCallbackURL").takeIf{
                json.optBoolean("appleAndroidEnabled")&&runCatching{AccountBrowserPolicy.callbackOrigin(it)}.getOrDefault(false)
            }
            return AccountConfig(googleId,callback)
        }
    }
}

internal data class PendingAppleSignIn(val verifier:String,val state:String,val expiresAt:String,val deleteUserId:String?=null) {
    fun json()=JSONObject().put("verifier",verifier).put("state",state).put("expiresAt",expiresAt).put("deleteUserId",deleteUserId)
    fun valid(now:Long=System.currentTimeMillis())=runCatching{
        verifier.matches(Regex("[A-Za-z0-9_-]{43,128}"))&&state.matches(Regex("[A-Za-z0-9_-]{16,128}"))&&Instant.parse(expiresAt).toEpochMilli()>now
    }.getOrDefault(false)
    override fun toString()="PendingAppleSignIn([redacted])"
    companion object {
        fun parse(json:JSONObject)=PendingAppleSignIn(json.getString("verifier"),json.getString("state"),json.getString("expiresAt"),
            json.optString("deleteUserId").takeIf{it.isNotBlank()&&it!="null"})
    }
}
internal object AccountBrowserPolicy {
    const val BASE="https://api.recordpov.app"
    const val CALLBACK="$BASE/auth/apple/return"
    fun random():String=Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).also(SecureRandom()::nextBytes))
    fun challenge(verifier:String):String {
        require(verifier.matches(Regex("[A-Za-z0-9._~-]{43,128}")))
        return Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII)))
    }
    fun ownedUrl(value:String):Boolean=runCatching {
        val uri=URI(value)
        uri.scheme=="https"&&uri.host=="api.recordpov.app"&&uri.port in listOf(-1,443)&&uri.rawUserInfo==null&&uri.rawFragment==null
    }.getOrDefault(false)
    fun callbackOrigin(value:String):Boolean=runCatching {
        val uri=URI(value)
        ownedUrl(value)&&uri.rawPath=="/auth/apple/return"&&uri.rawQuery==null
    }.getOrDefault(false)
    /** State is compared before a one-use code can reach the exchange endpoint. */
    fun code(value:String,pending:PendingAppleSignIn,now:Long=System.currentTimeMillis()):String? {
        require(value.length<=4096) {"Invalid account return link."}
        require(pending.valid(now)) {"This sign-in expired. Please try again."}
        val uri=URI(value)
        require(ownedUrl(value)&&uri.rawPath=="/auth/apple/return") {"Invalid account return link."}
        val query=uri.rawQuery?.split('&')?.map {part ->
            val bits=part.split('=',limit=2);require(bits.size==2)
            URLDecoder.decode(bits[0],"UTF-8") to URLDecoder.decode(bits[1],"UTF-8")
        } ?: error("Invalid account return link.")
        require(query.map{it.first}.distinct().size==query.size && query.size==2) {"Invalid account return link."}
        val fields=query.toMap();val state=fields["state"].orEmpty()
        require(MessageDigest.isEqual(state.toByteArray(Charsets.UTF_8),pending.state.toByteArray(Charsets.UTF_8))) {"This sign-in belongs to a different request. Please try again."}
        if(fields["error"]=="SIGN_IN_CANCELLED" && fields.keys==setOf("state","error"))return null
        require(fields.keys==setOf("state","code")) {"Invalid account return link."}
        return fields.getValue("code").also{require(it.matches(Regex("[A-Za-z0-9_-]{16,256}"))) {"Invalid account return code."}}
    }
    fun sameUserForDeletion(expected:String?,actual:AccountUser)=expected==null||expected==actual.id
    fun finishDeletion(expected:String?,active:String?)=expected!=null&&expected==active
}

/** AES-GCM envelope; the actual app key is non-exportable AndroidKeyStore material. */
internal object AccountCipher {
    fun seal(key:SecretKey,purpose:String,plain:String):String {
        val cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,key)
        cipher.updateAAD(purpose.toByteArray(Charsets.UTF_8))
        val encoder=Base64.getUrlEncoder().withoutPadding()
        return "1.${encoder.encodeToString(cipher.iv)}.${encoder.encodeToString(cipher.doFinal(plain.toByteArray(Charsets.UTF_8)))}"
    }
    fun open(key:SecretKey,purpose:String,value:String):String {
        require(value.length<=65536)
        val parts=value.split('.');require(parts.size==3&&parts[0]=="1")
        val decoder=Base64.getUrlDecoder();val iv=decoder.decode(parts[1]);require(iv.size==12)
        val cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.DECRYPT_MODE,key,GCMParameterSpec(128,iv))
        cipher.updateAAD(purpose.toByteArray(Charsets.UTF_8))
        return cipher.doFinal(decoder.decode(parts[2])).toString(Charsets.UTF_8)
    }
}
