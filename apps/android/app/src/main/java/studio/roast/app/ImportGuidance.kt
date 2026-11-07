package studio.roast.app

/** Whether the user may leave RecordPOV right now while an import runs. Pure: no Android or Compose types. */
internal enum class ImportGuidanceTone { Stay,Go }
internal data class ImportGuidance(val tone:ImportGuidanceTone,val text:String)

internal object ImportGuidanceCopy {
    const val INTERRUPTED="Your import was interrupted. Tap Download & open video to try again."
    const val INTERRUPTED_UPLOAD="Your upload was interrupted. Tap Upload video or photo to try again."
    private const val LEAVE="You can leave RecordPOV. It keeps going in the background."
    /** A vanished import: uploads have no link to paste, so name the button that adds them again. */
    fun missingFile(upload:Boolean)=if(upload)"This video is no longer on this phone. Add it again with Upload video or photo."
        else "This video is no longer on this phone. Paste its link to download it again."
    // MediaImportService is a foreground service for the whole import (YouTube included), so leaving is safe in every active status.
    fun guidance(status:ImportStatus?):ImportGuidance?=when(status) {
        ImportStatus.Downloading,ImportStatus.Loading->ImportGuidance(ImportGuidanceTone.Go,LEAVE)
        else->null
    }
}
