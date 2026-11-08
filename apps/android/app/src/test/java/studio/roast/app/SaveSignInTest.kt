package studio.roast.app

import org.junit.Assert.*
import org.junit.Test

class SaveSignInTest {
    private val session=AccountSession("a".repeat(32),"2099-01-01T00:00:00Z",AccountUser("user-1","Test","test@example.com"))

    @Test fun saveAsksForSignInOnlyWhenSignedOut() {
        assertTrue(SaveSignIn.needed(null))
        assertFalse(SaveSignIn.needed(session))
    }
    @Test fun aSignInWhileAccountIsOpenContinuesTheSave() {
        assertTrue(SaveSignIn.signedIn(previousUserId=null,userId="user-1"))
    }
    @Test fun staySignedOutOrUnchangedNeverSaves() {
        assertFalse(SaveSignIn.signedIn(null,null))
        assertFalse(SaveSignIn.signedIn("user-1","user-1"))
    }
    @Test fun signingOutNeverSaves() {
        assertFalse(SaveSignIn.signedIn("user-1",null))
    }
    @Test fun anotherAccountCountsAsANewSignIn() {
        assertTrue(SaveSignIn.signedIn("user-1","user-2"))
    }
}
