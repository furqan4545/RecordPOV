package studio.roast.app

enum class MediaLoadingPhase(val buttonTitle:String,val message:String) {
    Downloading("Downloading…","Please wait, we’re downloading your video."),
    Loading("Almost ready…","Loading your video…")
}
