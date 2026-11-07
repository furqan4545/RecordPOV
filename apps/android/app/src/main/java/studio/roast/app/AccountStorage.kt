package studio.roast.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/** Separate account storage: this class never reads or deletes drafts, media, or resolver settings. */
internal class AccountStorage(context:Context) {
    private val preferences=context.getSharedPreferences("recordpov.account.v1",Context.MODE_PRIVATE)
    @Synchronized private fun key():SecretKey {
        val store=KeyStore.getInstance("AndroidKeyStore").apply{load(null)}
        (store.getKey(ALIAS,null) as? SecretKey)?.let{return it}
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS,KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }
    private fun read(name:String):JSONObject?=preferences.getString(name,null)?.let{
        JSONObject(AccountCipher.open(key(),"studio.roast.app:account:v1:$name",it))
    }
    private fun write(name:String,json:JSONObject) {
        val encrypted=AccountCipher.seal(key(),"studio.roast.app:account:v1:$name",json.toString())
        check(preferences.edit().putString(name,encrypted).commit()) {"Your account could not be saved securely. Please try again."}
    }
    fun session()=read("session")?.let(AccountSession::parse)
    fun save(session:AccountSession)=write("session",session.json())
    fun pending()=read("applePending")?.let(PendingAppleSignIn::parse)
    fun save(pending:PendingAppleSignIn)=write("applePending",pending.json())
    fun clearSession(){check(preferences.edit().remove("session").commit())}
    fun clearPending(){check(preferences.edit().remove("applePending").commit())}
    fun reset(){preferences.edit().clear().commit();KeyStore.getInstance("AndroidKeyStore").apply{load(null);deleteEntry(ALIAS)}}
    companion object {private const val ALIAS="recordpov.account.key.v1"}
}
