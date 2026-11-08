package studio.roast.app

import android.content.Context
import android.graphics.BlurMaskFilter
import androidx.annotation.DrawableRes
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.IosShare
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.NorthEast
import androidx.compose.material.icons.rounded.PhotoCamera
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Remembers, in the app's existing preferences, that the first-launch onboarding was finished. */
internal class OnboardingPreference(context:Context) {
    private val preferences=context.getSharedPreferences("roast",Context.MODE_PRIVATE)
    var finished:Boolean
        get()=preferences.getBoolean(OnboardingCopy.FINISHED_KEY,false)
        set(value){preferences.edit().putBoolean(OnboardingCopy.FINISHED_KEY,value).apply()}
}

/** First launch only: a welcome, then four screens showing how RecordPOV works (port of iOS OnboardingView).
 *  Start on the last screen calls [onFinish]; Create then shows and the flow never appears again. */
@Composable internal fun OnboardingScreen(onFinish:()->Unit) {
    val pager=rememberPagerState(pageCount={OnboardingCopy.pageCount})
    val scope=rememberCoroutineScope()
    val page=pager.currentPage
    Column(Modifier.fillMaxSize().background(Bone).statusBarsPadding().navigationBarsPadding().padding(bottom=16.dp)) {
        HorizontalPager(pager,Modifier.fillMaxWidth().weight(1f)) {index ->
            if(index==0)WelcomePage()
            else StepPage(index,OnboardingCopy.steps[index-1]) {
                when(index){1->PasteArt();2->CameraArt();3->RecordArt();else->ShareArt()}
            }
        }
        PageDots(OnboardingCopy.pageCount,page,Modifier.align(Alignment.CenterHorizontally).padding(top=10.dp,bottom=16.dp))
        OnboardingButton(OnboardingCopy.buttonTitle(page),Modifier.padding(horizontal=22.dp)) {
            if(page<OnboardingCopy.lastPage)scope.launch{pager.animateScrollToPage(page+1,animationSpec=tween(300,easing=EaseInOut))}
            else onFinish()
        }
    }
}

// Pages

@Composable private fun WelcomePage() {
    Column(Modifier.fillMaxSize().padding(horizontal=22.dp)) {
        Row(Modifier.padding(top=8.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(10.dp)) {
            Image(painterResource(R.drawable.recordpov_mark),null,Modifier.size(30.dp),contentScale=ContentScale.Fit)
            Text("RecordPOV",fontSize=22.sp,fontWeight=FontWeight.Bold)
        }
        ReactionVideo(Modifier.weight(1f).padding(top=18.dp).fillMaxWidth().clip(RoundedCornerShape(26.dp)).clearAndSetSemantics{})
        Text(OnboardingCopy.WELCOME_TITLE,fontSize=34.sp,lineHeight=40.sp,fontWeight=FontWeight.Bold,
            modifier=Modifier.padding(top=22.dp).semantics{heading()})
        Text(OnboardingCopy.WELCOME_TEXT,fontSize=17.sp,lineHeight=23.sp,color=Muted,modifier=Modifier.padding(top=8.dp))
    }
}

@Composable private fun StepPage(number:Int,step:OnboardingStep,art:@Composable ()->Unit) {
    Column(Modifier.fillMaxSize().padding(horizontal=22.dp)) {
        Text(OnboardingCopy.stepLabel(number),fontSize=12.sp,fontWeight=FontWeight.SemiBold,fontFamily=FontFamily.Monospace,
            color=Muted,modifier=Modifier.padding(top=10.dp))
        Box(Modifier.weight(1f).padding(top=12.dp).fillMaxWidth().clearAndSetSemantics{}){art()}
        Text(step.title,fontSize=30.sp,lineHeight=36.sp,fontWeight=FontWeight.Bold,modifier=Modifier.padding(top=22.dp).semantics{heading()})
        Text(step.text,fontSize=17.sp,lineHeight=23.sp,color=Muted,modifier=Modifier.padding(top=8.dp))
    }
}

// Step art

private val OnboardingCard=Color(red=0.90f,green=0.89f,blue=0.85f)
private val RecordRed=Color(0xFFFF3B30)

/** Step 1: the video you copied, the link field and where links can come from. */
@Composable private fun PasteArt() {
    Column(Modifier.fillMaxSize().background(OnboardingCard,RoundedCornerShape(26.dp)).padding(14.dp),
        horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(14.dp)) {
        val video=painterResource(R.drawable.onboarding_video)
        Box(Modifier.weight(1f).fillMaxWidth(),contentAlignment=Alignment.Center) {
            Box(Modifier.aspectRatio(video.intrinsicSize.width/video.intrinsicSize.height,matchHeightConstraintsFirst=true)
                .clip(RoundedCornerShape(16.dp))) {
                Image(video,null,Modifier.fillMaxSize(),contentScale=ContentScale.Crop)
                PlatformTile(VideoPlatform.Instagram,32.dp,Modifier.align(Alignment.TopStart).padding(10.dp))
            }
        }
        Row(Modifier.fillMaxWidth().height(52.dp).background(Color.White,RoundedCornerShape(14.dp)).padding(horizontal=14.dp),
            verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(10.dp)) {
            Icon(Icons.Rounded.Link,null,Modifier.size(22.dp),tint=Muted)
            Text("instagram.com/reel/C9x…",fontSize=15.sp,color=Muted,maxLines=1,overflow=TextOverflow.Ellipsis,modifier=Modifier.weight(1f))
            Spacer(Modifier.width(4.dp))
            Box(Modifier.height(32.dp).background(Lime,CircleShape).padding(horizontal=14.dp),contentAlignment=Alignment.Center) {
                Text("Paste",fontSize=13.sp,fontWeight=FontWeight.SemiBold,color=Ink)
            }
        }
        Row(Modifier.padding(vertical=4.dp),horizontalArrangement=Arrangement.spacedBy(14.dp)) {
            VideoPlatform.entries.forEach{PlatformTile(it,46.dp)}
        }
    }
}

/** Step 2: you with your room behind you, then a sweep removes the background. */
@Composable private fun CameraArt() {
    Column(Modifier.fillMaxSize().background(Ink,RoundedCornerShape(26.dp)).padding(horizontal=14.dp),
        horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(14.dp)) {
        Row(Modifier.padding(top=16.dp),horizontalArrangement=Arrangement.spacedBy(14.dp)) {
            LimeCircle(Icons.Rounded.PhotoCamera,50.dp,22.dp)
            LimeCircle(Icons.Rounded.Mic,50.dp,22.dp)
        }
        Box(Modifier.weight(1f).fillMaxWidth(),contentAlignment=Alignment.Center) {
            BackgroundRemovalDemo(Modifier.aspectRatio(3f/4f,matchHeightConstraintsFirst=true).clip(RoundedCornerShape(18.dp)))
        }
        Row(Modifier.padding(bottom=16.dp).height(34.dp).background(Color.White.copy(alpha=.12f),CircleShape).padding(horizontal=14.dp),
            verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Rounded.AutoAwesome,null,Modifier.size(16.dp),tint=Color.White)
            Text("Background removed on your phone",fontSize=13.sp,fontWeight=FontWeight.SemiBold,color=Color.White,
                maxLines=1,overflow=TextOverflow.Ellipsis,modifier=Modifier.weight(1f,fill=false))
        }
    }
}

/** The same photo twice, lined up: with its real background, then cut out. A lime line sweeps across to show
 *  the background coming off, then it loops. With animations turned off it shows only the cutout. */
@Composable private fun BackgroundRemovalDemo(modifier:Modifier) {
    val motion=homeMotionEnabled()
    val removed=remember{Animatable(0f)}
    LaunchedEffect(motion) {
        if(!motion){removed.snapTo(1f);return@LaunchedEffect}
        removed.snapTo(0f)
        while(true) {
            delay(1200)
            removed.animateTo(1f,tween(1600,easing=EaseInOut))
            delay(1400)
            removed.animateTo(0f,tween(1200,easing=EaseInOut))
        }
    }
    val density=LocalDensity.current
    val glow=remember(density){android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
        color=Lime.copy(alpha=.8f).toArgb()
        maskFilter=BlurMaskFilter(with(density){6.dp.toPx()},BlurMaskFilter.Blur.NORMAL)
    }}
    Box(modifier.background(Color.White.copy(alpha=.06f))) {
        Image(painterResource(R.drawable.onboarding_me),null,contentScale=ContentScale.Crop,
            modifier=Modifier.fillMaxSize().drawWithContent{clipRect(left=size.width*removed.value){this@drawWithContent.drawContent()}})
        Image(painterResource(R.drawable.onboarding_me_cutout),null,contentScale=ContentScale.Crop,
            modifier=Modifier.fillMaxSize().drawWithContent{clipRect(right=size.width*removed.value){this@drawWithContent.drawContent()}})
        Canvas(Modifier.fillMaxSize()) {
            val x=(size.width+8.dp.toPx())*removed.value-5.dp.toPx()
            val width=3.dp.toPx()
            drawIntoCanvas{it.nativeCanvas.drawRect(x,0f,x+width,size.height,glow)}
            drawRect(Lime,Offset(x,0f),Size(width,size.height))
        }
    }
}

/** Step 3: recording a reaction on top of the video. */
@Composable private fun RecordArt() {
    Column(Modifier.fillMaxSize().background(Ink,RoundedCornerShape(26.dp)).padding(14.dp),
        horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(14.dp)) {
        Box(Modifier.weight(1f).fillMaxWidth().clip(RoundedCornerShape(18.dp))) {
            ReactionVideo(Modifier.fillMaxSize())
            Row(Modifier.padding(12.dp).height(28.dp).background(Color.Black.copy(alpha=.55f),CircleShape).padding(horizontal=10.dp),
                verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(8.dp).background(RecordRed,CircleShape))
                Text("REC 0:07",fontSize=12.sp,fontWeight=FontWeight.Bold,fontFamily=FontFamily.Monospace,color=Color.White)
            }
        }
        Box(Modifier.size(62.dp).border(3.dp,Color.White,CircleShape),contentAlignment=Alignment.Center) {
            Box(Modifier.size(48.dp).background(Lime,CircleShape))
        }
    }
}

/** Step 4: the finished video, ready to share. */
@Composable private fun ShareArt() {
    Column(Modifier.fillMaxSize().background(Ink,RoundedCornerShape(26.dp)).padding(14.dp),
        horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(14.dp)) {
        Box(Modifier.weight(1f).fillMaxWidth().clip(RoundedCornerShape(18.dp))) {
            ReactionVideo(Modifier.fillMaxSize())
            Row(Modifier.padding(12.dp).height(30.dp).background(Color.Black.copy(alpha=.55f),CircleShape).padding(horizontal=12.dp),
                verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Rounded.CheckCircle,null,Modifier.size(16.dp),tint=Color.White)
                Text("Exported",fontSize=13.sp,fontWeight=FontWeight.SemiBold,color=Color.White)
            }
        }
        Row(horizontalArrangement=Arrangement.spacedBy(10.dp)) {
            LimeCircle(Icons.Rounded.IosShare,44.dp,20.dp)
            listOf(VideoPlatform.Instagram,VideoPlatform.TikTok,VideoPlatform.YouTube,VideoPlatform.X).forEach{PlatformTile(it,44.dp,onDark=true)}
        }
    }
}

// Shared pieces

/** The example vertical video with you on top, background removed, over the bottom-right corner,
 *  the way a Cutout reaction looks in Studio. Callers clip it. */
@Composable private fun ReactionVideo(modifier:Modifier) {
    BoxWithConstraints(modifier) {
        Image(painterResource(R.drawable.onboarding_video),null,Modifier.fillMaxSize(),contentScale=ContentScale.Crop)
        val cutout=painterResource(R.drawable.onboarding_me_cutout)
        Image(cutout,null,contentScale=ContentScale.Fit,modifier=Modifier.align(Alignment.BottomEnd).offset(x=maxWidth*0.025f)
            .height(maxHeight*0.46f).aspectRatio(cutout.intrinsicSize.width/cutout.intrinsicSize.height))
    }
}

@Composable private fun LimeCircle(icon:ImageVector,size:Dp,iconSize:Dp) {
    Box(Modifier.size(size).background(Lime,CircleShape),contentAlignment=Alignment.Center) {
        Icon(icon,null,Modifier.size(iconSize),tint=Ink)
    }
}

/** Simple Icons glyphs, the same SVGs as the iOS Brand* assets. */
private enum class VideoPlatform(@DrawableRes val glyph:Int) {
    Instagram(R.drawable.brand_instagram),YouTube(R.drawable.brand_youtube),TikTok(R.drawable.brand_tiktok),X(R.drawable.brand_x)
}

private val InstagramColors=listOf(Color(red=0.996f,green=0.855f,blue=0.459f),Color(red=0.980f,green=0.494f,blue=0.118f),
    Color(red=0.839f,green=0.161f,blue=0.463f),Color(red=0.588f,green=0.184f,blue=0.749f),Color(red=0.310f,green=0.357f,blue=0.835f))

/** A platform's own glyph on its own colours, like its app icon. */
@Composable private fun PlatformTile(platform:VideoPlatform,size:Dp,modifier:Modifier=Modifier,onDark:Boolean=false) {
    val shape=RoundedCornerShape(size*0.27f)
    val background=when(platform) {
        // Bottom-left to top-right, as on iOS.
        VideoPlatform.Instagram->Brush.linearGradient(InstagramColors,start=Offset(0f,Float.POSITIVE_INFINITY),end=Offset(Float.POSITIVE_INFINITY,0f))
        VideoPlatform.YouTube->SolidColor(Color.White)
        VideoPlatform.TikTok,VideoPlatform.X->SolidColor(Color.Black)
    }
    Box(modifier.size(size).background(background,shape).border(1.dp,if(onDark)Color.White.copy(alpha=.18f) else Ink.copy(alpha=.08f),shape)
        .padding(size*0.24f)) {
        Icon(painterResource(platform.glyph),null,Modifier.fillMaxSize(),tint=if(platform==VideoPlatform.YouTube)Color.Red else Color.White)
    }
}

@Composable private fun PageDots(count:Int,current:Int,modifier:Modifier) {
    Row(modifier.clearAndSetSemantics{contentDescription=OnboardingCopy.pageLabel(current)},horizontalArrangement=Arrangement.spacedBy(6.dp)) {
        repeat(count) {index ->
            val width by animateDpAsState(if(index==current)20.dp else 7.dp,tween(250,easing=EaseInOut),label="Page dot width")
            val color by animateColorAsState(if(index==current)Ink else Ink.copy(alpha=.18f),tween(250,easing=EaseInOut),label="Page dot color")
            Box(Modifier.size(width,7.dp).background(color,CircleShape))
        }
    }
}

/** The iOS PrimaryButton: lime, title on the left, an arrow on the right. */
@Composable private fun OnboardingButton(title:String,modifier:Modifier,onClick:()->Unit) {
    Button(onClick=onClick,modifier=modifier.fillMaxWidth().heightIn(min=48.dp),shape=RoundedCornerShape(14.dp),
        colors=ButtonDefaults.buttonColors(containerColor=Lime,contentColor=Ink),contentPadding=PaddingValues(horizontal=16.dp)) {
        Text(title,fontSize=15.sp,fontWeight=FontWeight.SemiBold)
        Spacer(Modifier.weight(1f))
        Icon(Icons.Rounded.NorthEast,null,Modifier.size(18.dp))
    }
}
