package studio.roast.app

/** As on iOS, saving a finished video needs an account; recording, editing and drafts never do. Pure. */
internal object SaveSignIn {
    /** Save while signed out opens the Account screen instead of saving. */
    fun needed(session:AccountSession?)=session==null
    /** Like iOS onChange(of: session user id): only a new sign-in, made while Account is open, continues the save. */
    fun signedIn(previousUserId:String?,userId:String?)=userId!=null&&userId!=previousUserId
}
