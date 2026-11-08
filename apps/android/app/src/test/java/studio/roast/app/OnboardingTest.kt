package studio.roast.app

import org.junit.Assert.*
import org.junit.Test

class OnboardingTest {
    @Test fun welcomeThenFourStepsInTheIosOrder() {
        assertEquals(5,OnboardingCopy.pageCount)
        assertEquals(4,OnboardingCopy.lastPage)
        assertEquals("React to any video",OnboardingCopy.WELCOME_TITLE)
        assertEquals("Paste a link, hit record, and you’re on top of it.",OnboardingCopy.WELCOME_TEXT)
        assertEquals(listOf("Paste a link","Turn on camera and mic","Tap record","Export and share"),OnboardingCopy.steps.map{it.title})
    }
    @Test fun stepTextMatchesIosWithPhoneInsteadOfIphone() {
        assertEquals(listOf(
            "Copy a video from Instagram, YouTube, TikTok or X, then paste it into RecordPOV.",
            "Your face goes on top of the video. The background is removed right on your phone.",
            "React while the video plays. Stop whenever you’re done.",
            "Export your video, then share it to Instagram, TikTok, YouTube or X."),OnboardingCopy.steps.map{it.text})
        assertTrue(OnboardingCopy.steps.none{"iPhone" in it.text})
    }
    @Test fun buttonSaysGetStartedThenNextThenStart() {
        assertEquals(listOf("Get started","Next","Next","Next","Start"),(0 until OnboardingCopy.pageCount).map(OnboardingCopy::buttonTitle))
    }
    @Test fun stepLabelsCountFourSteps() {
        assertEquals(listOf("STEP 1 OF 4","STEP 2 OF 4","STEP 3 OF 4","STEP 4 OF 4"),(1..4).map(OnboardingCopy::stepLabel))
    }
    @Test fun pageDotsTellTalkBackWhichPageIsShown() {
        assertEquals("Page 1 of 5",OnboardingCopy.pageLabel(0))
        assertEquals("Page 5 of 5",OnboardingCopy.pageLabel(4))
    }
    @Test fun finishedFlagUsesTheIosName() {
        assertEquals("didFinishOnboarding",OnboardingCopy.FINISHED_KEY)
    }
    @Test fun onboardingNeverMentionsSigningUp() {
        val all=(OnboardingCopy.steps.flatMap{listOf(it.title,it.text)}+OnboardingCopy.WELCOME_TITLE+OnboardingCopy.WELCOME_TEXT)
            .joinToString(" ").lowercase()
        listOf("sign","account","log in","login").forEach{assertFalse(it,it in all)}
    }
}
