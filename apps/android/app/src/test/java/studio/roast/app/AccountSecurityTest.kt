package studio.roast.app

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import javax.crypto.AEADBadTagException
import javax.crypto.KeyGenerator

class AccountSecurityTest {
    private val future=Instant.ofEpochMilli(2_000_000_000_000).toString()
    private val pending=PendingAppleSignIn("v".repeat(43),"s".repeat(43),future)
    private val code="c".repeat(43)
    private val callback="${AccountBrowserPolicy.CALLBACK}?code=$code&state=${pending.state}"
    @Test fun pkceUsesTheRfc7636ChallengeVector() {
        assertEquals("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",AccountBrowserPolicy.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
    }
    @Test fun secureRandomChallengesHaveIndependentUnreservedEntropy() {
        val values=(1..100).map{AccountBrowserPolicy.random()}
        assertEquals(100,values.toSet().size)
        assertTrue(values.all{it.matches(Regex("[A-Za-z0-9_-]{43}"))})
    }
    @Test fun callbackRequiresTheInitiatingState() {
        assertEquals(code,AccountBrowserPolicy.code(callback,pending,1_000_000))
        assertThrows(IllegalArgumentException::class.java){AccountBrowserPolicy.code(callback.replace(pending.state,"x".repeat(43)),pending,1_000_000)}
    }
    @Test fun expiredPendingRequestCannotExchange() {
        assertThrows(IllegalArgumentException::class.java){AccountBrowserPolicy.code(callback,pending,2_000_000_000_000)}
        assertFalse(pending.copy(verifier="short").valid(1_000_000))
    }
    @Test fun foreignOriginCredentialsPortFragmentAndEncodedPathAreRejected() {
        listOf(callback.replace("api.recordpov.app","api.recordpov.app.evil.test"),
            callback.replace("https:","http:"),callback.replace("api.recordpov.app","user@api.recordpov.app"),
            callback.replace("api.recordpov.app","api.recordpov.app:8443"),"$callback#fragment",
            callback.replace("/return","/%72eturn")).forEach{
            assertThrows(IllegalArgumentException::class.java){AccountBrowserPolicy.code(it,pending,1_000_000)}
        }
    }
    @Test fun duplicateAndExtraQueryFieldsAreNotAccepted() {
        listOf("$callback&code=$code","$callback&state=${pending.state}","$callback&next=https://evil.test",callback.replace("code=$code","error=unknown"))
            .forEach{assertThrows(IllegalArgumentException::class.java){AccountBrowserPolicy.code(it,pending,1_000_000)}}
    }
    @Test fun cancellationStillRequiresMatchingState() {
        assertNull(AccountBrowserPolicy.code("${AccountBrowserPolicy.CALLBACK}?error=SIGN_IN_CANCELLED&state=${pending.state}",pending,1_000_000))
        assertThrows(IllegalArgumentException::class.java){AccountBrowserPolicy.code("${AccountBrowserPolicy.CALLBACK}?error=SIGN_IN_CANCELLED&state=wrong",pending,1_000_000)}
    }
    @Test fun accountDeletionCannotSwitchToADifferentIdentity() {
        val user=AccountUser("user1","Name","email@example.com")
        assertTrue(AccountBrowserPolicy.sameUserForDeletion("user1",user))
        assertFalse(AccountBrowserPolicy.sameUserForDeletion("user2",user))
        assertTrue(AccountBrowserPolicy.sameUserForDeletion(null,user))
        assertTrue(AccountBrowserPolicy.finishDeletion("user1","user1"))
        assertFalse(AccountBrowserPolicy.finishDeletion("user1",null)) // cancelled while exchange was in flight
        assertFalse(AccountBrowserPolicy.finishDeletion("user1","user2"))
        assertFalse(AccountBrowserPolicy.finishDeletion(null,null))
    }
    @Test fun disabledServerHidesEveryProviderEvenWhenIdsArePresent() {
        val json=config().put("enabled",false)
        assertFalse(AccountConfig.parse(json).available)
    }
    @Test fun providerConfigRequiresRealAudienceAndOwnedCallback() {
        val valid=AccountConfig.parse(config())
        assertEquals("123-valid.apps.googleusercontent.com",valid.googleClientId)
        assertEquals(AccountBrowserPolicy.CALLBACK,valid.appleCallback)
        val bad=config().put("androidCallbackURL","https://evil.test/auth/apple/return")
        bad.getJSONObject("providers").getJSONObject("google").put("serverClientId","fake")
        assertFalse(AccountConfig.parse(bad).available)
        assertFalse(AccountConfig.parse(config().put("appleAndroidEnabled",false)).appleCallback!=null)
    }
    @Test fun sessionsExpireAndSecretsAreRedactedFromDiagnostics() {
        val session=AccountSession.parse(JSONObject().put("token","secret".repeat(8)).put("expiresAt",future)
            .put("user",AccountUser("id","Name","email@example.com").json()))
        assertTrue(session.valid(1_000_000));assertFalse(session.valid(2_000_000_000_000))
        assertFalse(session.toString().contains(session.token));assertFalse(pending.toString().contains(pending.verifier))
        assertThrows(IllegalArgumentException::class.java){AccountSession.parse(session.json().put("token","unsafe\r\nAuthorization: secret"))}
    }
    @Test fun encryptedSessionRoundTripsWithoutPlaintextAndUsesFreshNonces() {
        val key=key();val secret="token=personal-session-value"
        val first=AccountCipher.seal(key,"session",secret);val second=AccountCipher.seal(key,"session",secret)
        assertNotEquals(first,second);assertFalse(first.contains(secret))
        assertEquals(secret,AccountCipher.open(key,"session",first))
    }
    @Test fun tamperingWrongKeyAndSwappedPurposeFailAuthentication() {
        val key=key();val value=AccountCipher.seal(key,"session","secret")
        assertThrows(AEADBadTagException::class.java){AccountCipher.open(key,"applePending",value)}
        assertThrows(AEADBadTagException::class.java){AccountCipher.open(key(),"session",value)}
        val parts=value.split('.').toMutableList();val decoded=java.util.Base64.getUrlDecoder().decode(parts[2]);decoded[0]=(decoded[0].toInt() xor 1).toByte()
        parts[2]=java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(decoded)
        assertThrows(AEADBadTagException::class.java){AccountCipher.open(key,"session",parts.joinToString("."))}
    }
    @Test fun encryptedEnvelopeRejectsUnsupportedVersionAndOversizeData() {
        assertThrows(IllegalArgumentException::class.java){AccountCipher.open(key(),"session","2.invalid.invalid")}
        assertThrows(IllegalArgumentException::class.java){AccountCipher.open(key(),"session","a".repeat(65537))}
    }
    @Test fun pendingDeletionIntentSurvivesEncryptedRoundTrip() {
        val value=pending.copy(deleteUserId="original-user")
        val key=key();val encrypted=AccountCipher.seal(key,"applePending",value.json().toString())
        val restored=PendingAppleSignIn.parse(JSONObject(AccountCipher.open(key,"applePending",encrypted)))
        assertEquals(value,restored);assertTrue(restored.valid(1_000_000))
    }
    private fun config()=JSONObject().put("version",1).put("enabled",true).put("appleAndroidEnabled",true)
        .put("androidCallbackURL",AccountBrowserPolicy.CALLBACK).put("providers",JSONObject().put("google",JSONObject()
            .put("enabled",true).put("serverClientId","123-valid.apps.googleusercontent.com")))
    private fun key()=KeyGenerator.getInstance("AES").apply{init(256)}.generateKey()
}
