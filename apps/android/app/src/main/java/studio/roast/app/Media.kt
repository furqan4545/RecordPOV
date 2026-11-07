package studio.roast.app

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class MediaSource(val uri: Uri, val title: String, val isImage: Boolean)
enum class PipStyle(val label: String) {
    Rounded("Rounded"), Circle("Circle"), Square("Square"), Cutout("Cutout")
}
data class PipPlacement(
    val x: Float = .73f, val y: Float = .73f,
    val scale: Float = 1f, val rotation: Float = 0f,
    val style: PipStyle = PipStyle.Rounded,
    val framingScale: Float = 1f
) {
    fun transformed(dx: Float, dy: Float, zoom: Float, angle: Float) = copy(
        x = (x + dx).coerceIn(.04f, .96f),
        y = (y + dy).coerceIn(.04f, .96f),
        scale = (scale * zoom).coerceIn(.45f, 2.8f),
        rotation = (rotation + angle) % 360f
    )
}

class MediaResolver(private val context: Context,private val endpointOverride:String?=null) {
    private val preferences = context.getSharedPreferences("roast", Context.MODE_PRIVATE)
    init {
        if(!preferences.getBoolean(ResolverEndpointDefaults.MIGRATION_KEY,false)) {
            val endpoint=ResolverEndpointDefaults.afterMigration(preferences.getString("server",null),completed=false)
            preferences.edit().putString("server",endpoint).putBoolean(ResolverEndpointDefaults.MIGRATION_KEY,true).apply()
        }
    }
    var baseUrl: String
        get() = endpointOverride ?: preferences.getString("server", ResolverEndpointDefaults.PUBLIC)?.takeIf{it.isNotBlank()}?:ResolverEndpointDefaults.PUBLIC
        set(value) { preferences.edit().putString("server", value.trim().trimEnd('/'))
            .putBoolean(ResolverEndpointDefaults.MIGRATION_KEY,true).apply() }

    /**
     * The server returns links only. Downloads the manifest's primary set (converting it on this phone when
     * it is not directly playable) or its directly playable fallback, and switches to the fallback once if the
     * primary download or conversion fails. [primaryTried] restarts an interrupted import on its fallback.
     */
    suspend fun resolve(link:String,onPhase:suspend(MediaLoadingPhase)->Unit={},foregroundManaged:Boolean=false,
        primaryTried:Boolean=false,onFallback:suspend()->Unit={}):MediaSource=withContext(Dispatchers.IO) {
        val imports=ImportedVideoFiles(File(context.filesDir,"imports"))
        suspend fun phase(value:MediaLoadingPhase)=withContext(Dispatchers.Main){onPhase(value)}
        imports.find(link,minimumQualityVersion=2)?.let {phase(MediaLoadingPhase.Loading);return@withContext MediaSource(Uri.fromFile(it.file),it.title,false)}
        val directory=File(context.cacheDir,"import-transfer/${java.util.UUID.randomUUID()}").apply{check(mkdirs())}
        suspend fun metadata():JSONObject {
            val path="/v2/media/resolve"
            phase(MediaLoadingPhase.Downloading)
            // TikTok is looked up on the phone, like a browser; the server is not called.
            if(TikTokPhoneResolver.handles(link.trim()))return TikTokPhoneResolver.resolve(link.trim())
            if(YouTubeTransportPolicy.isYouTubeLink(link))return fetchYouTubeOnPhone(context,baseUrl,link.trim(),path,foregroundManaged)
            val client=okhttp3.OkHttpClient.Builder().connectTimeout(15,java.util.concurrent.TimeUnit.SECONDS)
                .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).build()
            try{return YouTubePhoneFetch.post(client,baseUrl,path,JSONObject().put("url",link.trim()),930)}
            finally{client.dispatcher.cancelAll();client.connectionPool.evictAll();client.dispatcher.executorService.shutdown()}
        }
        try {
            val json=metadata()
            val plan=DirectImportPolicy.plan(json)
            suspend fun deliver(set:DirectAssetSet):Pair<File,SourceFacts> {
                phase(MediaLoadingPhase.Downloading)
                val files=kotlinx.coroutines.withTimeoutOrNull(7_230_000) {
                    kotlinx.coroutines.coroutineScope {
                        val budget=ImportByteBudget(plan.maxBytes)
                        set.assets.map {asset->async {
                            val file=File(directory,"${asset.role}.mp4")
                            DirectAssetTransfer.asset(asset,plan.platform,file,budget)
                            asset.role to file
                        }}.map{it.await()}.toMap()
                    }
                } ?: throw java.io.IOException("The video download timed out.")
                phase(MediaLoadingPhase.Loading)
                return prepareDownloaded(files,set.expected,directory)
            }
            val choice=if(primaryTried&&plan.fallback!=null)ImportChoice.Fallback
                else DirectImportPolicy.choose(plan){codec,width,height,fps->DeviceVideoDecoders.canDecode(codec,width,height,fps)}
            val (file,facts)=when(choice) {
                is ImportChoice.Unsupported->error(choice.message)
                ImportChoice.Fallback->deliver(checkNotNull(plan.fallback))
                ImportChoice.Primary->plan.fallback?.let {fallback->
                    importWithFallback(primary={deliver(plan.primary)},fallback={
                        currentCoroutineContext().ensureActive()
                        onFallback()
                        directory.listFiles().orEmpty().forEach{it.deleteRecursively()} // fresh transfers for the fallback set
                        deliver(fallback)
                    })
                } ?: deliver(plan.primary)
            }
            currentCoroutineContext().ensureActive()
            val coroutine=currentCoroutineContext()
            val stored=imports.store(file.inputStream(),json.optString("title","Your video"),
                facts.durationUs/1000,json.optString("sourceUrl").ifBlank{link.trim()},link.trim(),
                qualityVersion=json.optInt("qualityVersion",0).coerceAtLeast(0),checkActive={coroutine.ensureActive()})
            MediaSource(Uri.fromFile(stored.file),stored.title,false)
        }finally{directory.deleteRecursively()}
    }

    /**
     * Inspects the downloaded codecs. H.264 8-bit 4:2:0 + AAC keeps the existing direct path (inspect or mux);
     * anything this phone decodes is converted to H.264 + AAC and then validated with the same strict rules.
     */
    private suspend fun prepareDownloaded(files:Map<String,File>,expected:ExpectedMedia,directory:File):Pair<File,SourceFacts> {
        // YouTube's DASH files declare their length twice; fix the header before anything reads them.
        files.values.forEach{runCatching{normalizeFragmentedMp4(it)}}
        val muxed=files["muxed"]
        val video=muxed?:checkNotNull(files["video"]);val audio=if(muxed==null)checkNotNull(files["audio"])else null
        val picture=NativeSourceMedia.probe(video);val sound=audio?.let{NativeSourceMedia.probe(it)}
        if(picture.videoMime!=null&&picture.directlyUsable&&sound?.directlyUsable!=false) {
            if(muxed!=null)return muxed to NativeSourceMedia.inspect(muxed,expected)
            val output=File(directory,"combined.mp4")
            return output to NativeSourceMedia.mux(video,checkNotNull(audio),output,expected)
                .also{video.delete();audio?.delete()} // free up to MAX_BYTES before store() copies
        }
        val mime=picture.videoMime ?: error("This file does not contain a video.")
        check(DeviceVideoDecoders.canDecode(mime,picture.width,picture.height,picture.fps)){DirectImportPolicy.UNSUPPORTED_FORMAT}
        val output=File(directory,"converted.mp4")
        OnDeviceConverter.convert(context,video,audio,output,picture)
        video.delete();audio?.delete() // the originals are no longer needed once the conversion is written
        return output to NativeSourceMedia.inspect(output,expected)
    }

}

data class SavedTake(val file: File, val title: String, val modified: Long)

class TakeStore(private val context: Context) {
    private val preferences=context.getSharedPreferences("roast",Context.MODE_PRIVATE)
    private val exports=GalleryExportLedger(
        read={key->preferences.getString("gallery:$key",null)},
        remember={key,uri->preferences.edit().putString("gallery:$key",uri).apply()},
        mutex=galleryMutex)
    var recordingDelay:RecordingDelay
        get()=RecordingDelay.fromStoredSeconds(preferences.getInt("recordingDelay",3))
        set(value){preferences.edit().putInt("recordingDelay",value.seconds).apply()}
    val directory = File(context.filesDir, "takes").apply { mkdirs() }
    fun newFile(prefix: String = "Video") = File(directory,
        "$prefix ${SimpleDateFormat("yyyy-MM-dd HH-mm-ss-SSS", Locale.US).format(Date())}.mp4")
    fun list(): List<SavedTake> = directory.listFiles().orEmpty()
        .filter { it.extension == "mp4" && it.length() > 0 }
        .sortedByDescending { it.lastModified() }
        .map { SavedTake(it, it.nameWithoutExtension, it.lastModified()) }
    fun delete(file:File)=OwnedMediaDeletion.saved(directory,file)
    fun isSavedToGallery(file:File):Boolean=preferences.contains("gallery:${file.name}")
    suspend fun saveToPhotos(file: File): Uri = withContext(Dispatchers.IO) {
        check(file.isFile&&file.length()>0){"Your video is still available in the app, but its video file could not be opened."}
        Uri.parse(exports.save(file.name,
            exists={saved->runCatching{context.contentResolver.query(Uri.parse(saved),arrayOf(MediaStore.Video.Media._ID),null,null,null)
                ?.use{it.moveToFirst()}==true}.getOrDefault(false)},
            findPublished={findGalleryCopy(file)?.toString()},
            publish={publishToGallery(file).toString()}))
    }
    private fun findGalleryCopy(file:File):Uri? = context.contentResolver.query(
        MediaStore.Video.Media.EXTERNAL_CONTENT_URI,arrayOf(MediaStore.Video.Media._ID),
        "${MediaStore.Video.Media.DISPLAY_NAME} = ? AND ${MediaStore.Video.Media.RELATIVE_PATH} IN (?, ?) AND ${MediaStore.Video.Media.IS_PENDING} = 0",
        arrayOf(file.name,"${Environment.DIRECTORY_MOVIES}/RecordPOV/","${Environment.DIRECTORY_MOVIES}/Roast/"),null)?.use {cursor ->
            if(cursor.moveToFirst())android.content.ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI,cursor.getLong(0))else null
        }
    private fun publishToGallery(file:File):Uri {
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, file.name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, "${Environment.DIRECTORY_MOVIES}/RecordPOV")
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }
        val uri = context.contentResolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
            ?: error("Gallery could not be opened. Your video is safe in the app.")
        try {
            checkNotNull(context.contentResolver.openOutputStream(uri)){"Gallery could not create the video. Your video is safe in the app."}
                .use { output -> file.inputStream().use { it.copyTo(output) } }
            values.clear(); values.put(MediaStore.Video.Media.IS_PENDING, 0)
            check(context.contentResolver.update(uri, values, null, null)>0){"Gallery could not finish saving. Your video is safe in the app."}
            return uri
        } catch (e: Exception) {
            runCatching{context.contentResolver.delete(uri, null, null)}
            throw e
        }
    }
    fun share(file: File) {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
            type = "video/mp4"; putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }, "Share your video").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
    fun play(file: File) {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        context.startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "video/mp4")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        })
    }
    companion object {private val galleryMutex=Mutex()}
}

suspend fun loadPicture(context: Context, uri: Uri): Bitmap = withContext(Dispatchers.IO) {
    ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, info, _ ->
        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        val ratio = minOf(1f, 1600f / maxOf(info.size.width, info.size.height))
        decoder.setTargetSize((info.size.width * ratio).toInt(), (info.size.height * ratio).toInt())
    }
}

suspend fun thumbnail(file: File): Bitmap? = withContext(Dispatchers.IO) {
    runCatching { MediaMetadataRetriever().use { retriever ->
        retriever.setDataSource(file.absolutePath)
        // Thumbnail raster only; never allocate a full 4K frame for every Recent card.
        retriever.getScaledFrameAtTime(0,MediaMetadataRetriever.OPTION_CLOSEST_SYNC,512,512)
    } }.getOrNull()
}
