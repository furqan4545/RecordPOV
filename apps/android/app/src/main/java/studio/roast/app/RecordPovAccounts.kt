package studio.roast.app

import android.content.Context
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import androidx.credentials.ClearCredentialStateRequest
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.job
import kotlinx.coroutines.withContext
import java.net.URI

internal data class AccountState(val loading:Boolean=true,val busy:Boolean=false,val config:AccountConfig?=null,
    val session:AccountSession?=null,val message:String?=null,val applePending:Boolean=false,val deletingAfterSignIn:Boolean=false)

internal class RecordPovAccounts private constructor(private val context:Context) {
    private val storage=AccountStorage(context)
    private val api=AccountApi()
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
    private val restored=CompletableDeferred<Unit>()
    private val mutable=MutableStateFlow(AccountState())
    val state=mutable.asStateFlow()
    val returnEvents=MutableStateFlow(0)
    private var work:Job?=null
    private var deleteUserId:String?=null
    private var receivingApple=false
    init {
        scope.launch {
            try {
                val saved=withContext(Dispatchers.IO){storage.session()}
                val pending=withContext(Dispatchers.IO){storage.pending()}
                if(saved!=null&&!saved.valid())withContext(Dispatchers.IO){storage.clearSession()}
                if(pending!=null&&!pending.valid())withContext(Dispatchers.IO){storage.clearPending()}
                deleteUserId=pending?.takeIf{it.valid()}?.deleteUserId
                mutable.update{it.copy(session=saved?.takeIf{it.valid()},applePending=pending?.valid()==true,
                    deletingAfterSignIn=deleteUserId!=null,loading=false)}
            }catch(e:Exception){
                withContext(Dispatchers.IO){runCatching{storage.reset()}}
                mutable.update{it.copy(loading=false,message="Your account could not be restored. Please sign in again.")}
            }finally{restored.complete(Unit)}
        }
    }
    fun refresh()=perform {
        val pending=withContext(Dispatchers.IO){storage.pending()}
        if(pending!=null&&!pending.valid())cancelAppleInternal()
        val config=api.config();mutable.update{it.copy(config=config)}
        mutable.value.session?.let {saved->
            try {
                val data=api.session(saved.token)
                val session=saved.copy(expiresAt=data.getString("expiresAt"),user=AccountUser.parse(data.getJSONObject("user")))
                require(session.valid()) {"Your session expired. Please sign in again."}
                withContext(Dispatchers.IO){storage.save(session)};mutable.update{it.copy(session=session)}
            }catch(e:AccountApiException){if(e.status==401)forgetSession()else throw e}
        }
    }
    fun google(activityContext:Context)=perform {
        val clientId=mutable.value.config?.googleClientId ?: error("Google sign-in is not configured yet.")
        cancelAppleInternal()
        val nonce=AccountBrowserPolicy.random()
        val option=GetSignInWithGoogleOption.Builder(clientId).setNonce(nonce).build()
        val response=CredentialManager.create(activityContext).getCredential(activityContext,
            GetCredentialRequest.Builder().addCredentialOption(option).build())
        val credential=response.credential
        require(credential is CustomCredential && credential.type==GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL) {"Google returned an unsupported credential."}
        val google=GoogleIdTokenCredential.createFrom(credential.data)
        accept(api.signIn(google.idToken,nonce,google.displayName),deleteUserId)
    }
    fun apple(activityContext:Context)=perform {
        require(mutable.value.config?.appleCallback!=null) {"Apple sign-in is not configured yet."}
        val verifier=AccountBrowserPolicy.random();val state=AccountBrowserPolicy.random()
        val result=api.appleStart(AccountBrowserPolicy.challenge(verifier),state)
        val url=result.getString("url")
        require(AccountBrowserPolicy.ownedUrl(url)) {"The account service returned an invalid sign-in link."}
        val pending=PendingAppleSignIn(verifier,state,result.getString("expiresAt"),deleteUserId)
        require(pending.valid()) {"This sign-in expired. Please try again."}
        withContext(Dispatchers.IO){storage.save(pending)}
        mutable.update{it.copy(applePending=true)}
        try{CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(activityContext,Uri.parse(url))}
        catch(e:Exception){cancelAppleInternal();throw IllegalStateException("A browser could not be opened. Install or enable a browser and try again.",e)}
    }
    fun handleAppleReturn(value:String):Boolean {
        if(!runCatching{AccountBrowserPolicy.ownedUrl(value)&&URI(value).rawPath=="/auth/apple/return"}.getOrDefault(false))return false
        returnEvents.value++
        if(receivingApple)return true
        receivingApple=true
        perform(waitForCurrent=true) {
            try {
                val pending=withContext(Dispatchers.IO){storage.pending()}
                if(pending==null) {
                    if(mutable.value.session!=null)return@perform // already consumed callback after activity recreation
                    error("This sign-in expired. Please start again.")
                }
                if(!pending.valid()){cancelAppleInternal();error("This sign-in expired. Please start again.")}
                val code=AccountBrowserPolicy.code(value,pending)
                if(code==null){cancelAppleInternal();return@perform}
                try{accept(api.appleExchange(code,pending.verifier),pending.deleteUserId)}finally{cancelAppleInternal()}
            }finally{receivingApple=false}
        }
        return true
    }
    fun cancelApple()=perform{cancelAppleInternal()}
    private suspend fun cancelAppleInternal(){withContext(Dispatchers.IO){storage.clearPending()};mutable.update{it.copy(applePending=false)}}
    fun cancelDeletion() {
        // Cancel the destructive intention immediately, including while identity exchange is in flight.
        deleteUserId=null
        mutable.update{it.copy(deletingAfterSignIn=false,message=null)}
        scope.launch {try{cancelAppleInternal()}catch(e:Exception){mutable.update{it.copy(message="The pending sign-in could not be cleared. Please try again.")}}}
    }
    fun signOut()=perform {
        val saved=mutable.value.session
        val remoteError=if(saved!=null)runCatching{api.signOut(saved.token)}.exceptionOrNull()else null
        forgetSession();cancelAppleInternal();clearProvider()
        if(remoteError!=null && !(remoteError is AccountApiException && remoteError.status==401))
            mutable.update{it.copy(message="Signed out on this phone. The service could not end the remote session; it will expire automatically.")}
    }
    fun deleteAccount()=perform{deleteCurrent(afterReauthentication=false)}
    private suspend fun deleteCurrent(afterReauthentication:Boolean) {
        val saved=mutable.value.session ?: error("Please sign in to delete your account.")
        try {
            api.delete(saved.token);forgetSession();cancelAppleInternal();clearProvider()
            mutable.update{it.copy(message="Account deleted. Your videos and drafts stay on this phone.")}
        }catch(e:AccountApiException) {
            if(e.code=="REAUTHENTICATION_REQUIRED" && !afterReauthentication) {
                if(mutable.value.config==null){val config=api.config();mutable.update{it.copy(config=config)}}
                deleteUserId=saved.user.id
                mutable.update{it.copy(deletingAfterSignIn=true,message="Sign in again to confirm account deletion.")}
            }else throw e
        }
    }
    private suspend fun accept(session:AccountSession,expectedDeleteUserId:String?) {
        require(session.valid()) {"The account session expired. Please sign in again."}
        if(!AccountBrowserPolicy.sameUserForDeletion(expectedDeleteUserId,session.user)) {
            runCatching{api.signOut(session.token)}
            error("Sign in to the same account to delete it.")
        }
        withContext(Dispatchers.IO){storage.save(session)};mutable.update{it.copy(session=session)}
        if(AccountBrowserPolicy.finishDeletion(expectedDeleteUserId,deleteUserId))deleteCurrent(afterReauthentication=true)
    }
    private suspend fun forgetSession(){
        withContext(Dispatchers.IO){storage.clearSession()}
        deleteUserId=null;mutable.update{it.copy(session=null,deletingAfterSignIn=false)}
    }
    private suspend fun clearProvider(){runCatching{CredentialManager.create(context).clearCredentialState(ClearCredentialStateRequest())}}
    private fun perform(waitForCurrent:Boolean=false,block:suspend()->Unit) {
        if(work?.isActive==true&&!waitForCurrent)return
        val previous=work
        work=scope.launch(start=CoroutineStart.LAZY) {
            if(waitForCurrent)previous?.join()
            restored.await();mutable.update{it.copy(busy=true,message=null)}
            try{block()}
            catch(e:GetCredentialCancellationException){}
            catch(e:GetCredentialException){mutable.update{it.copy(message="Google sign-in could not finish on this phone. Check Google Play services and try again.")}}
            catch(e:CancellationException){throw e}
            catch(e:Exception){mutable.update{it.copy(message=e.localizedMessage ?: "Account request failed. Please try again.")}}
            finally{if(work==currentCoroutineContext().job)mutable.update{it.copy(busy=false)}}
        }
        work?.start()
    }
    companion object {
        @Volatile private var instance:RecordPovAccounts?=null
        fun get(context:Context):RecordPovAccounts=instance ?: synchronized(this){instance ?: RecordPovAccounts(context.applicationContext).also{instance=it}}
    }
}
