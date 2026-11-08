package studio.roast.app

import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.runtime.saveable.rememberSaveable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.CancellationException
import java.io.File

val Bone=Color(0xFFF7F5F0)
val Ink=Color(0xFF202326)
val Lime=Color(0xFFDDFC67)
val Muted=Color(0xFF71736D)
val Rule=Color(0xFFE5E5DC)
private val RoastColors=lightColorScheme(primary=Ink,onPrimary=Color.White,secondary=Lime,
    secondaryContainer=Lime,onSecondaryContainer=Ink,background=Bone,onBackground=Ink,
    surface=Bone,onSurface=Ink,surfaceContainer=Color.White,surfaceVariant=Color(0xFFECEDE5),
    error=Color(0xFFB43127))

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun RoastApp(enableCamera:((()->Unit),(()->Unit))->Unit) {
    val context=LocalContext.current
    val resolver=remember{MediaResolver(context)}
    val imports=remember{ImportCoordinator.get(context)}
    val importedFiles=remember{ImportedVideoFiles(File(context.filesDir,"imports"))}
    val sourceNavigation=remember{Mutex()}
    var sourceOpenSequence by remember{mutableLongStateOf(0L)}
    var homeURL by rememberSaveable{mutableStateOf("")}
    var homeInputHydrated by rememberSaveable{mutableStateOf(false)}
    val importRecord by imports.state.collectAsState()
    val owner=LocalLifecycleOwner.current
    var foreground by remember{mutableStateOf(owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))}
    // "Download & open video" opens the finished import in Studio by itself. Leaving the app or Create keeps
    // this; only explicitly opening another video or photo clears it (the import then stays in Recent).
    val autoOpenJobId by imports.autoOpenJobId.collectAsState()
    DisposableEffect(owner) {
        val observer=LifecycleEventObserver{_,event->
            if(event==Lifecycle.Event.ON_START)foreground=true
            if(event==Lifecycle.Event.ON_STOP){foreground=false;sourceOpenSequence++}
        }
        owner.lifecycle.addObserver(observer)
        onDispose{owner.lifecycle.removeObserver(observer)}
    }
    val store=remember{TakeStore(context)}
    val accounts=remember{RecordPovAccounts.get(context)}
    val accountState by accounts.state.collectAsState()
    val accountReturns by accounts.returnEvents.collectAsState()
    val scope=rememberCoroutineScope()
    var tab by remember{mutableIntStateOf(0)}
    var source by remember{mutableStateOf<MediaSource?>(null)}
    var draft by remember{mutableStateOf<ReactionDraft?>(null)}
    var settings by remember{mutableStateOf(false)}
    var account by remember{mutableStateOf(false)}
    // Set while Account was opened by the editor's Save: a sign-in there continues that save; Not now never does.
    var saveAfterSignIn by remember{mutableStateOf<(()->Unit)?>(null)}
    val onboarding=remember{OnboardingPreference(context)}
    var onboardingDone by remember{mutableStateOf(onboarding.finished)}
    var libraryVersion by remember{mutableIntStateOf(0)}
    var libraryShelf by rememberSaveable{mutableStateOf(VideoShelf.Saved)}
    val snack=remember{SnackbarHostState()}
    fun openImported(video:ImportedVideo) {
        imports.deferOpening()
        val generation=++sourceOpenSequence
        scope.launch {
            sourceNavigation.withLock {
                if(generation!=sourceOpenSequence)return@withLock
                try {
                    val saved=withContext(Dispatchers.IO){checkNotNull(importedFiles.get(video.id)){"This import is no longer available."}.also{runCatching{importedFiles.markOpened(it.id)}}}
                    imports.consumeReady(saved.id) // never consumes or cancels a different active/new import
                    if(generation==sourceOpenSequence)source=MediaSource(Uri.fromFile(saved.file),saved.title,false)
                }catch(e:CancellationException){throw e}
                catch(e:Exception){imports.forgetReady(video.id);libraryVersion++;scope.launch{snack.showSnackbar(ImportGuidanceCopy.missingFile(video.sourceUrl==null))}}
            }
        }
    }
    LaunchedEffect(importRecord?.id){
        if(!homeInputHydrated&&importRecord!=null){
            if(homeURL.isBlank()&&importRecord?.local==false)homeURL=importRecord!!.input
            homeInputHydrated=true
        }
    }
    LaunchedEffect(accountReturns){if(accountReturns>0){settings=false;account=true}}
    LaunchedEffect(tab,source,draft,settings,account){
        if(tab!=0||source!=null||draft!=null||settings||account)sourceOpenSequence++
    }
    LaunchedEffect(importRecord?.id,importRecord?.status){if(importRecord?.status==ImportStatus.Ready)libraryVersion++}
    // A finished import waits until the first-launch onboarding is done, as on iOS.
    fun createVisible()=foreground&&onboardingDone&&tab==0&&source==null&&draft==null&&!settings&&!account
    LaunchedEffect(importRecord?.id,importRecord?.status,autoOpenJobId,foreground,onboardingDone,tab,source,draft,settings,account){
        if(importRecord?.status==ImportStatus.Ready&&importRecord?.id==autoOpenJobId&&createVisible()){
            // Completion updates the observed job state; keep navigation in the root scope
            // so consuming that state cannot cancel its own file/open operation.
            scope.launch {
                sourceNavigation.withLock {
                    val ready=importRecord?.takeIf{it.status==ImportStatus.Ready&&it.id==imports.autoOpenJobId.value} ?: return@withLock
                    // Left Create meanwhile, or another video was opened: the video opens when the user is back, or stays in Recent.
                    val wanted={imports.autoOpenJobId.value==ready.id&&createVisible()&&importRecord?.id==ready.id}
                    if(!wanted())return@withLock
                    val id=ready.importedId
                    val video=id?.let{withContext(Dispatchers.IO){importedFiles.get(it)}}
                    if(!wanted())return@withLock
                    if(video==null){
                        imports.deferOpening()
                        // The finished import's file vanished: never open an empty Studio; drop the stale job and explain.
                        if(id!=null)imports.forgetReady(id)
                        libraryVersion++
                        scope.launch{snack.showSnackbar(ImportGuidanceCopy.missingFile(ready.local))}
                    }else{
                        // Let the status area finish its 300 ms fade before Studio replaces Create.
                        delay(300)
                        if(!wanted())return@withLock
                        imports.deferOpening()
                        source=MediaSource(Uri.fromFile(video.file),video.title,false)
                        imports.consumeReady(video.id)
                        withContext(Dispatchers.IO){runCatching{importedFiles.markOpened(video.id)}}
                    }
                }
            }
        }
    }
    MaterialTheme(colorScheme=RoastColors,typography=Typography(),shapes=Shapes(
        extraSmall=RoundedCornerShape(8.dp),small=RoundedCornerShape(12.dp),medium=RoundedCornerShape(16.dp),
        large=RoundedCornerShape(20.dp),extraLarge=RoundedCornerShape(24.dp))) {
        Surface(Modifier.fillMaxSize(),color=Bone) {
            Box(Modifier.fillMaxSize()) {
            when {
                draft!=null -> EditorScreen(initialDraft=draft!!,store=store,onClose={draft=null;libraryVersion++},
                    onDone={draft=null;source=null;tab=1;libraryShelf=VideoShelf.Saved;libraryVersion++;scope.launch{snack.showSnackbar("Saved to Gallery. Your editable draft is kept in My videos.")}},
                    onSignInToSave={save->saveAfterSignIn=save;account=true})
                source!=null -> StudioScreen(initialSource=source!!,store=store,enableCamera=enableCamera,
                    onClose={source=null;libraryVersion++},onDraftReady={draft=it;source=null;libraryVersion++})
                // First launch only: the welcome and how-it-works screens replace Create and the tab bar until Start.
                else -> Crossfade(targetState=onboardingDone,animationSpec=tween(250,easing=EaseInOut),label="Onboarding") {done ->
                    if(!done)OnboardingScreen(onFinish={onboarding.finished=true;onboardingDone=true})
                    else Scaffold(containerColor=Bone,
                        bottomBar={
                            Row(Modifier.navigationBarsPadding().padding(horizontal=24.dp,vertical=10.dp)
                                .fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Color.White.copy(alpha=.94f))
                                .padding(4.dp),horizontalArrangement=Arrangement.spacedBy(4.dp)) {
                                GlassTab("Create",Icons.Rounded.AddCircleOutline,tab==0,Modifier.weight(1f)){tab=0}
                                GlassTab("My videos",Icons.Rounded.VideoLibrary,tab==1,Modifier.weight(1f)){tab=1;libraryVersion++}
                            }
                        }) { padding ->
                        AnimatedContent(targetState=tab,label="App tabs",modifier=Modifier.padding(padding)) { selected ->
                            when(selected) {
                                0 -> CreateScreen(resolver,imports,store,libraryVersion,homeURL,onURL={homeURL=it},
                                    onSource={imports.deferOpening();sourceOpenSequence++;source=it},onSettings={settings=true},
                                    onOpenSaved=::openImported,onEdit={imports.deferOpening();draft=it},
                                    onError={scope.launch{snack.showSnackbar(it)}})
                                else -> LibraryScreen(store,libraryVersion,libraryShelf,onShelf={libraryShelf=it},onCreate={tab=0},onEdit={imports.deferOpening();draft=it},onImport=::openImported,onError={scope.launch{snack.showSnackbar(it)}})
                            }
                        }
                    }
                }
            }
            SnackbarHost(snack,Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(20.dp))
            if(settings) ModalBottomSheet(onDismissRequest={settings=false},containerColor=Bone) {
                var address by remember{mutableStateOf(resolver.baseUrl)}
                var validation by remember{mutableStateOf<String?>(null)}
                Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal=24.dp).padding(bottom=40.dp),verticalArrangement=Arrangement.spacedBy(18.dp)) {
                    Text("Settings",fontSize=28.sp,fontWeight=FontWeight.Bold)
                    Surface(onClick={settings=false;account=true},modifier=Modifier.fillMaxWidth(),shape=RoundedCornerShape(12.dp),color=Color.White) {
                        Row(Modifier.padding(14.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                            Icon(Icons.Rounded.PersonOutline,null,Modifier.size(23.dp))
                            Column(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(3.dp)) {
                                Text("Account",fontWeight=FontWeight.SemiBold,fontSize=15.sp)
                                Text(accountState.session?.user?.name?.takeIf{it.isNotBlank()} ?: if(accountState.session!=null)"Signed in" else "Sign in to save your videos",fontSize=12.sp,color=Muted)
                            }
                            Icon(Icons.AutoMirrored.Rounded.ArrowForward,null,Modifier.size(18.dp))
                        }
                    }
                    Text("Video service",fontSize=19.sp,fontWeight=FontWeight.SemiBold)
                    Text("Connect your video service to open links. Imported photos and videos work without it.",color=Muted)
                    OutlinedTextField(address,{address=it;validation=null},label={Text("Service address")},singleLine=true,
                        modifier=Modifier.fillMaxWidth(),shape=RoundedCornerShape(12.dp),
                        keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Uri),isError=validation!=null)
                    validation?.let{Text(it,color=MaterialTheme.colorScheme.error)}
                    Button(onClick={
                        val uri=Uri.parse(address.trim())
                        if(uri.scheme !in listOf("http","https") || uri.host.isNullOrBlank()) validation="Enter a complete http or https address."
                        else{resolver.baseUrl=address;settings=false}
                    },modifier=Modifier.fillMaxWidth().height(48.dp),shape=RoundedCornerShape(12.dp)){Text("Save address")}
                }
            }
            if(account)AccountSheet(accounts,onDismiss={account=false;saveAfterSignIn=null},
                onSignedInToSave=saveAfterSignIn?.let{save->{account=false;saveAfterSignIn=null;save()}})
            }
        }
    }
}

@Composable private fun GlassTab(label:String,icon:ImageVector,selected:Boolean,modifier:Modifier,onClick:()->Unit) {
    Surface(onClick=onClick,modifier=modifier.height(44.dp).semantics{this.selected=selected;role=Role.Tab},shape=RoundedCornerShape(12.dp),color=if(selected) Ink else Color.Transparent,
        contentColor=if(selected) Color.White else Muted) {
        Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.Center) {
            Icon(icon,null,Modifier.size(19.dp));Spacer(Modifier.width(7.dp))
            Text(label,fontSize=13.sp,fontWeight=FontWeight.SemiBold,maxLines=1,overflow=TextOverflow.Ellipsis,modifier=Modifier.weight(1f,fill=false))
        }
    }
}

@Composable private fun ImportGuidanceChip(guidance:ImportGuidance) {
    val go=guidance.tone==ImportGuidanceTone.Go
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(if(go)Lime.copy(alpha=0.45f) else Bone)
        .padding(horizontal=12.dp,vertical=10.dp).semantics(mergeDescendants=true){liveRegion=LiveRegionMode.Polite},
        verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(10.dp)) {
        Icon(if(go)Icons.Rounded.CheckCircle else Icons.Rounded.Smartphone,null,Modifier.size(18.dp),tint=Ink)
        Text(guidance.text,fontSize=13.sp,lineHeight=18.sp,fontWeight=FontWeight.Medium,color=Ink,modifier=Modifier.weight(1f))
    }
}

@Composable private fun CreateScreen(resolver:MediaResolver,imports:ImportCoordinator,store:TakeStore,version:Int,url:String,onURL:(String)->Unit,
    onSource:(MediaSource)->Unit,onSettings:()->Unit,onOpenSaved:(ImportedVideo)->Unit,
    onEdit:(ReactionDraft)->Unit,onError:(String)->Unit) {
    val context=LocalContext.current
    val files=remember{ImportedVideoFiles(File(context.filesDir,"imports"))}
    val drafts=remember{DraftStore(context)}
    val scope=rememberCoroutineScope()
    val job by imports.state.collectAsState()
    var recent by remember{mutableStateOf<List<HomeRecentVideo>>(emptyList())}
    var recentVersion by remember{mutableIntStateOf(0)}
    LaunchedEffect(version,job?.id,job?.status,recentVersion){recent=withContext(Dispatchers.IO){homeRecentVideos(files,drafts,store,VideoShelf.Imported)}}
    val loading=job?.active==true
    val phase=if(loading)if(job?.status==ImportStatus.Loading)MediaLoadingPhase.Loading else MediaLoadingPhase.Downloading else null
    val status=job?.status
    // After the download the last step has no percentage, so a moving bar shows it is still working.
    val finishing=status==ImportStatus.Loading
    val guidance=remember(status){ImportGuidanceCopy.guidance(status)}
    val importer=rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) {uri->uri?.let {
        runCatching{context.contentResolver.takePersistableUriPermission(it,Intent.FLAG_GRANT_READ_URI_PERMISSION)}
        if(context.contentResolver.getType(it)?.startsWith("image/")==true)onSource(MediaSource(it,"Your photo",true))
        else {
            val title=runCatching{context.contentResolver.query(it,arrayOf(OpenableColumns.DISPLAY_NAME),null,null,null)?.use{cursor->if(cursor.moveToFirst())cursor.getString(0)else null}}.getOrNull()?:"Your video"
            imports.start(it.toString(),true,resolver.baseUrl,title)
        }
    }}
    fun downloadLink(){imports.start(url,false,resolver.baseUrl)}
    LazyColumn(Modifier.fillMaxSize(),contentPadding=PaddingValues(start=24.dp,end=24.dp,bottom=18.dp),verticalArrangement=Arrangement.spacedBy(24.dp)) {
        item {
            Row(Modifier.fillMaxWidth().padding(top=12.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.SpaceBetween) {
                Row(verticalAlignment=Alignment.CenterVertically) {
                    Image(painterResource(R.drawable.recordpov_mark),null,Modifier.size(40.dp),contentScale=ContentScale.Fit)
                    Spacer(Modifier.width(10.dp))
                    Column(verticalArrangement=Arrangement.spacedBy(1.dp)) {
                        Text("RecordPOV",fontSize=27.sp,fontWeight=FontWeight.Bold,lineHeight=30.sp)
                        Text("recordpov.app",fontSize=11.sp,color=Muted)
                    }
                }
                IconButton(onClick=onSettings,modifier=Modifier.size(44.dp)){Icon(Icons.Rounded.Tune,"Settings",tint=Ink)}
            }
        }
        item {
            Surface(shape=RoundedCornerShape(20.dp),color=Color.White,border=BorderStroke(1.dp,Rule)) {
                Column(Modifier.padding(20.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) {
                    Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(9.dp)) {
                        Icon(Icons.Rounded.Link,null,Modifier.size(22.dp));Text("Add a video",fontSize=19.sp,fontWeight=FontWeight.Bold)
                    }
                    OutlinedTextField(url,onURL,placeholder={Text("Paste a video link",fontSize=15.sp)},modifier=Modifier.fillMaxWidth(),singleLine=true,
                        shape=RoundedCornerShape(12.dp),keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Uri),
                        trailingIcon={IconButton(modifier=Modifier.size(44.dp),enabled=!loading,onClick={
                            val clipboard=context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            clipboard.primaryClip?.getItemAt(0)?.coerceToText(context)?.toString()?.let(onURL)
                        }){Icon(Icons.Rounded.ContentPaste,"Paste link",Modifier.size(20.dp))}},
                        enabled=!loading,colors=OutlinedTextFieldDefaults.colors(unfocusedBorderColor=Rule))
                    Text("Instagram  ·  YouTube  ·  TikTok  ·  X",fontSize=12.sp,color=Muted)
                    Column(verticalArrangement=Arrangement.spacedBy(10.dp)) {
                        Button(onClick=::downloadLink,enabled=!loading&&LinkIdentity.key(url)!=null,shape=RoundedCornerShape(12.dp),modifier=Modifier.fillMaxWidth().height(48.dp),
                            colors=ButtonDefaults.buttonColors(containerColor=Lime,contentColor=Ink,disabledContainerColor=if(loading)Lime else Rule,disabledContentColor=if(loading)Ink else Muted)) {
                            if(loading){CircularProgressIndicator(Modifier.size(19.dp),strokeWidth=2.dp,color=Ink);Spacer(Modifier.width(10.dp))}
                            Text(phase?.buttonTitle?:"Download & open video",fontWeight=FontWeight.SemiBold,maxLines=1,overflow=TextOverflow.Ellipsis)
                        }
                        // The status fades out when the import finishes instead of vanishing at once.
                        AnimatedVisibility(visible=loading,enter=fadeIn(tween(300)),exit=fadeOut(tween(300)),label="Import status") {
                            Column(verticalArrangement=Arrangement.spacedBy(10.dp)) {
                                AnimatedVisibility(visible=finishing,enter=fadeIn(tween(250)),exit=fadeOut(tween(250)),label="Finishing bar") {
                                    LinearProgressIndicator(Modifier.fillMaxWidth().height(4.dp).clip(CircleShape)
                                        .semantics{contentDescription="Finishing your video"},color=Ink,trackColor=Ink.copy(alpha=0.12f))
                                }
                                Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
                                    Spacer(Modifier.weight(1f))
                                    TextButton(onClick={job?.takeIf{it.active}?.let{MediaImportService.cancel(context,it.id)}},modifier=Modifier.heightIn(min=48.dp)){Text("Cancel import")}
                                }
                                Crossfade(targetState=guidance,modifier=Modifier.fillMaxWidth(),animationSpec=tween(250),label="Import guidance") {value->
                                    value?.let{ImportGuidanceChip(it)}
                                }
                            }
                        }
                        job?.message?.takeIf{!loading&&job?.status!=ImportStatus.Ready}?.let{Text(it,fontSize=12.sp,lineHeight=17.sp,color=MaterialTheme.colorScheme.error)}
                    }
                    Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                        HorizontalDivider(Modifier.weight(1f),color=Rule)
                        Text("or",fontSize=12.sp,color=Muted)
                        HorizontalDivider(Modifier.weight(1f),color=Rule)
                    }
                    OutlinedButton(onClick={importer.launch(arrayOf("video/*","image/*"))},enabled=!loading,
                        modifier=Modifier.fillMaxWidth().height(48.dp),shape=RoundedCornerShape(12.dp),border=BorderStroke(1.dp,Rule),
                        colors=ButtonDefaults.outlinedButtonColors(contentColor=Ink)) {
                        Icon(Icons.Rounded.AddPhotoAlternate,null,Modifier.size(20.dp));Spacer(Modifier.width(9.dp))
                        Text("Upload video or photo",fontWeight=FontWeight.SemiBold)
                    }
                }
            }
        }
        item {Text("Recent",fontSize=21.sp,fontWeight=FontWeight.Bold)}
        if(recent.isEmpty())item {
            Text("Videos you import appear here.",fontSize=14.sp,color=Muted,modifier=Modifier.padding(bottom=12.dp))
        }
        items(recent.chunked(2),key={row->row.first().key}){row->
            Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                row.forEach {video->HomeRecentCard(video,Modifier.weight(1f),onDelete={scope.launch{
                    try {
                        withContext(Dispatchers.IO){
                            video.imported?.let{files.delete(it.id)}?:video.draft?.let{drafts.delete(it.id)}?:video.saved?.let{store.delete(it.file)}
                        }
                        video.imported?.let{imports.forgetReady(it.id)}
                        recentVersion++
                    }catch(e:CancellationException){throw e}
                    catch(e:Exception){onError("This video could not be deleted. Please try again.")}
                }}) {
                    video.imported?.let(onOpenSaved)?:video.draft?.let(onEdit)?:video.saved?.let{saved->
                        imports.deferOpening()
                        runCatching{store.play(saved.file)}.onFailure{onError("No video player is available on this device.")}
                    }
                }}
                if(row.size==1)Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable private fun LibraryScreen(store:TakeStore,version:Int,shelf:VideoShelf,onShelf:(VideoShelf)->Unit,onCreate:()->Unit,onEdit:(ReactionDraft)->Unit,onImport:(ImportedVideo)->Unit,onError:(String)->Unit) {
    val context=LocalContext.current
    val drafts=remember{DraftStore(context)}
    val importedFiles=remember{ImportedVideoFiles(File(context.filesDir,"imports"))}
    var refresh by remember{mutableIntStateOf(0)}
    var videos by remember{mutableStateOf<List<HomeRecentVideo>>(emptyList())}
    var loadedShelf by remember{mutableStateOf<VideoShelf?>(null)}
    val scope=rememberCoroutineScope()
    LaunchedEffect(version,refresh,shelf){val requested=shelf;videos=withContext(Dispatchers.IO){homeRecentVideos(importedFiles,drafts,store,requested)};loadedShelf=requested}
    // Hide the previous shelf's items immediately while the new shelf loads.
    val shown=videos.filter{shelf.accepts(it)}
    LazyColumn(Modifier.fillMaxSize(),contentPadding=PaddingValues(24.dp),verticalArrangement=Arrangement.spacedBy(14.dp)) {
        item {Text("My videos",fontSize=32.sp,fontWeight=FontWeight.Bold,modifier=Modifier.padding(top=12.dp,bottom=10.dp))}
        item {
            Surface(shape=RoundedCornerShape(16.dp),color=Color.White,border=BorderStroke(1.dp,Rule)) {
                Row(Modifier.fillMaxWidth().padding(4.dp).selectableGroup(),horizontalArrangement=Arrangement.spacedBy(4.dp)) {
                    GlassTab("Saved videos",Icons.Rounded.VideoLibrary,shelf==VideoShelf.Saved,Modifier.weight(1f)){onShelf(VideoShelf.Saved)}
                    GlassTab("Imported videos",Icons.Rounded.Download,shelf==VideoShelf.Imported,Modifier.weight(1f)){onShelf(VideoShelf.Imported)}
                }
            }
        }
        if(loadedShelf==shelf&&shown.isEmpty())item {
            Column(Modifier.fillMaxWidth().padding(vertical=40.dp),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(16.dp)) {
                Text(if(shelf==VideoShelf.Saved)"No saved videos yet" else "No imported videos yet",fontSize=20.sp,fontWeight=FontWeight.Bold)
                Text(if(shelf==VideoShelf.Saved)"Your saved videos and unfinished edits appear here." else "Videos you import appear here.",fontSize=14.sp,color=Muted,textAlign=TextAlign.Center)
                Button(onClick=onCreate,shape=RoundedCornerShape(12.dp),modifier=Modifier.height(48.dp)){Text("Add a video")}
            }
        }
        items(shown.chunked(2),key={it.first().key}){row->
            Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                row.forEach{video->HomeRecentCard(video,Modifier.weight(1f),
                    onShare=video.saved?.let{saved->{
                        runCatching{store.share(saved.file)}.onFailure{onError("This video could not be shared. Please try again.")};Unit
                    }},
                    onSave=video.saved?.takeUnless{store.isSavedToGallery(it.file)}?.let{saved->{scope.launch{
                        try{store.saveToPhotos(saved.file);refresh++;onError("Saved to Gallery.")}
                        catch(e:CancellationException){throw e}
                        catch(e:Exception){onError("Gallery save failed. Your app copy is safe.")}
                    };Unit}},
                    onDelete={scope.launch{
                        try {
                            withContext(Dispatchers.IO){
                                video.imported?.let{importedFiles.delete(it.id)}?:video.draft?.let{drafts.delete(it.id)}?:video.saved?.let{store.delete(it.file)}
                            }
                            video.imported?.let{ImportCoordinator.get(context).forgetReady(it.id)}
                            refresh++
                        }catch(e:CancellationException){throw e}
                        catch(e:Exception){onError("This video could not be deleted. Please try again.")}
                    }}) {
                    video.imported?.let(onImport)?:video.draft?.let(onEdit)?:video.saved?.let{saved->
                        ImportCoordinator.get(context).deferOpening()
                        runCatching{store.play(saved.file)}.onFailure{onError("No video player is available on this device.")}
                    }
                }}
                if(row.size==1)Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable fun StylePicker(selected:PipStyle?,enabled:Boolean=true,onSelect:(PipStyle)->Unit) {
    Row(Modifier.fillMaxWidth().height(44.dp).clip(RoundedCornerShape(12.dp)).background(Color.White)
        .padding(3.dp),horizontalArrangement=Arrangement.spacedBy(3.dp)) {
        PipStyle.entries.forEach {style ->
            Surface(onClick={onSelect(style)},enabled=enabled,modifier=Modifier.weight(1f).fillMaxHeight().semantics{this.selected=selected==style;role=Role.RadioButton},shape=RoundedCornerShape(9.dp),
                color=if(selected==style) Ink else Color.White,contentColor=if(selected==style) Lime else Ink,
                border=null) {
                Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(4.dp,Alignment.CenterHorizontally)) {
                    Icon(when(style){PipStyle.Rounded->Icons.Rounded.CropPortrait;PipStyle.Circle->Icons.Rounded.Circle;PipStyle.Square->Icons.Rounded.Square;PipStyle.Cutout->Icons.Rounded.Person},null,Modifier.size(14.dp))
                    Text(style.label,fontSize=11.sp,fontWeight=FontWeight.SemiBold)
                }
            }
        }
    }
}

/** Full screen and Stage show the whole camera, so only Camera and Cutout change how it looks. */
@Composable fun FullCameraStylePicker(cutout:Boolean,enabled:Boolean=true,onSelect:(Boolean)->Unit) {
    Row(Modifier.fillMaxWidth().height(44.dp).clip(RoundedCornerShape(12.dp)).background(Color.White)
        .padding(3.dp),horizontalArrangement=Arrangement.spacedBy(3.dp)) {
        listOf(false,true).forEach {option ->
            val chosen=cutout==option
            Surface(onClick={onSelect(option)},enabled=enabled,modifier=Modifier.weight(1f).fillMaxHeight().semantics{selected=chosen;role=Role.RadioButton},shape=RoundedCornerShape(9.dp),
                color=if(chosen) Ink else Color.White,contentColor=if(chosen) Lime else Ink,
                border=null) {
                Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(4.dp,Alignment.CenterHorizontally)) {
                    Icon(if(option)Icons.Rounded.Person else Icons.Rounded.Videocam,null,Modifier.size(14.dp))
                    Text(if(option)PipStyle.Cutout.label else "Camera",fontSize=11.sp,fontWeight=FontWeight.SemiBold)
                }
            }
        }
    }
}
