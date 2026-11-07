package studio.roast.app

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.IosShare
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.io.File

internal data class HomeRecentVideo(val key:String,val file:File,val title:String,val subtitle:String,val modified:Long,
    val imported:ImportedVideo?=null,val draft:ReactionDraft?=null,val saved:SavedTake?=null)

/** Saved = finished saved videos and unfinished edits (drafts); Imported = imported source videos. */
internal enum class VideoShelf { Saved,Imported }
internal fun VideoShelf.accepts(video:HomeRecentVideo):Boolean=(video.imported!=null)==(this==VideoShelf.Imported)

/** Existing stores stay authoritative; no new copies or persistence format. A null shelf lists everything. */
internal fun homeRecentVideos(imports:ImportedVideoFiles,drafts:DraftStore,takes:TakeStore,shelf:VideoShelf?=null):List<HomeRecentVideo> {
    val includeImports=shelf!=VideoShelf.Saved
    val includeSaved=shelf!=VideoShelf.Imported
    val saved:List<SavedTake> =if(includeSaved)takes.list() else emptyList()
    val exportedNames=saved.map{it.file.name}.toSet()
    val imported:List<ImportedVideo> =if(includeImports)imports.list() else emptyList()
    val unfinished:List<ReactionDraft> =if(includeSaved)drafts.list() else emptyList()
    return (imported.map{HomeRecentVideo("import:${it.id}",it.file,it.title,"Imported · ${formatTime(it.durationMs)}",it.createdAt,imported=it)}+
        unfinished.filter{"Video ${it.id.take(8)}-v${it.revision}.mp4" !in exportedNames}.map{
            HomeRecentVideo("draft:${it.id}",it.capture,it.title,"Draft · ${formatTime(it.outputDurationMs)}",File(it.directory,"project.json").lastModified(),draft=it)}+
        saved.map{HomeRecentVideo("saved:${it.file.name}",it.file,it.title,"Saved video",it.modified,saved=it)})
        .sortedByDescending{it.modified}
}

@Composable internal fun HomeRecentCard(video:HomeRecentVideo,modifier:Modifier=Modifier,
    onShare:(()->Unit)?=null,onSave:(()->Unit)?=null,onDelete:()->Unit,onClick:()->Unit) {
    var picture by remember(video.key,video.modified){mutableStateOf<android.graphics.Bitmap?>(null)}
    var menu by remember(video.key){mutableStateOf(false)}
    LaunchedEffect(video.key,video.modified){picture=thumbnail(video.file)}
    Box(modifier) {
    Surface(modifier=Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).combinedClickable(onClick=onClick,
        onLongClick={menu=true},onLongClickLabel="Show video actions"),shape=RoundedCornerShape(16.dp),color=Color.White) {
        Column {
            Box(Modifier.fillMaxWidth().aspectRatio(1.3f).clip(RoundedCornerShape(topStart=16.dp,topEnd=16.dp)).background(Ink),contentAlignment=Alignment.Center) {
                picture?.let{Image(it.asImageBitmap(),null,Modifier.fillMaxSize(),contentScale=ContentScale.Crop)}
                Surface(shape=RoundedCornerShape(10.dp),color=Ink.copy(alpha=.65f),contentColor=Color.White) {
                    Icon(if(video.draft!=null)Icons.Rounded.Edit else Icons.Rounded.PlayArrow,null,Modifier.padding(7.dp).size(21.dp))
                }
            }
            Column(Modifier.padding(12.dp),verticalArrangement=Arrangement.spacedBy(5.dp)) {
                Text(video.title,fontSize=13.sp,lineHeight=18.sp,fontWeight=FontWeight.SemiBold,maxLines=2,minLines=2,overflow=TextOverflow.Ellipsis)
                Text(video.subtitle,fontSize=11.sp,color=Muted,maxLines=1,overflow=TextOverflow.Ellipsis)
            }
        }
    }
    DropdownMenu(expanded=menu,onDismissRequest={menu=false}) {
        onShare?.let{share->DropdownMenuItem(text={Text("Share")},leadingIcon={Icon(Icons.Rounded.IosShare,null)},onClick={menu=false;share()})}
        onSave?.let{save->DropdownMenuItem(text={Text("Save to Gallery")},leadingIcon={Icon(Icons.Rounded.Download,null)},onClick={menu=false;save()})}
        DropdownMenuItem(text={Text("Delete permanently",color=MaterialTheme.colorScheme.error)},
            leadingIcon={Icon(Icons.Rounded.DeleteOutline,null,tint=MaterialTheme.colorScheme.error)},
            onClick={menu=false;onDelete()})
    }
    }
}
