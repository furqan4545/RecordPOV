package studio.roast.app

/** One of the four how-it-works screens. Pure: no Android or Compose types. */
internal data class OnboardingStep(val title:String,val text:String)

/** First launch only, as on iOS: a welcome (page 0), then four screens showing how RecordPOV works.
 *  Start on the last screen opens Create, and the flow never appears again. */
internal object OnboardingCopy {
    /** Same name as the iOS flag; saved once Start is tapped. */
    const val FINISHED_KEY="didFinishOnboarding"
    const val WELCOME_TITLE="React to any video"
    const val WELCOME_TEXT="Paste a link, hit record, and you’re on top of it."
    val steps=listOf(
        OnboardingStep("Paste a link","Copy a video from Instagram, YouTube, TikTok or X, then paste it into RecordPOV."),
        OnboardingStep("Turn on camera and mic","Your face goes on top of the video. The background is removed right on your phone."),
        OnboardingStep("Tap record","React while the video plays. Stop whenever you’re done."),
        OnboardingStep("Export and share","Export your video, then share it to Instagram, TikTok, YouTube or X."))
    val lastPage get()=steps.size
    val pageCount get()=steps.size+1
    fun stepLabel(number:Int)="STEP $number OF ${steps.size}"
    fun buttonTitle(page:Int)=if(page==0)"Get started" else if(page<lastPage)"Next" else "Start"
    fun pageLabel(page:Int)="Page ${page+1} of $pageCount"
}
