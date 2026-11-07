package studio.roast.app

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.PersonOutline
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun AccountSheet(accounts:RecordPovAccounts,onDismiss:()->Unit) {
    val context=LocalContext.current
    val state by accounts.state.collectAsState()
    var deleteConfirmation by remember{mutableStateOf(false)}
    LaunchedEffect(Unit){accounts.refresh()}
    ModalBottomSheet(onDismissRequest={if(state.deletingAfterSignIn)accounts.cancelDeletion();onDismiss()},containerColor=Bone) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal=24.dp).padding(bottom=32.dp),
            verticalArrangement=Arrangement.spacedBy(16.dp)) {
            Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
                Text("Account",fontSize=28.sp,fontWeight=FontWeight.Bold,modifier=Modifier.weight(1f))
                IconButton(onClick=accounts::refresh,enabled=!state.busy&&!state.loading,modifier=Modifier.size(44.dp)){
                    Icon(Icons.Rounded.Refresh,"Refresh account",Modifier.size(21.dp))
                }
            }
            Text("Sign-in is optional. Your videos and drafts stay on this phone.",color=Muted,fontSize=14.sp,lineHeight=20.sp)
            if(state.loading || state.busy)Row(horizontalArrangement=Arrangement.spacedBy(10.dp),verticalAlignment=Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(18.dp),strokeWidth=2.dp,color=Ink)
                Text(if(state.loading)"Restoring account…" else "Please wait…",fontSize=13.sp,color=Muted)
            }
            state.session?.let {session ->
                Surface(shape=RoundedCornerShape(16.dp),color=Color.White) {
                    Row(Modifier.padding(16.dp),horizontalArrangement=Arrangement.spacedBy(12.dp),verticalAlignment=Alignment.CenterVertically) {
                        Icon(Icons.Rounded.PersonOutline,null,Modifier.size(26.dp),tint=Ink)
                        Column(verticalArrangement=Arrangement.spacedBy(4.dp)) {
                            Text(session.user.name.ifBlank{session.user.email.ifBlank{"Signed in"}},fontWeight=FontWeight.SemiBold,fontSize=16.sp)
                            if(session.user.email.isNotBlank()&&session.user.email!=session.user.name)Text(session.user.email,color=Muted,fontSize=13.sp)
                        }
                    }
                }
            }
            state.message?.let{Text(it,fontSize=13.sp,lineHeight=19.sp,color=if(state.deletingAfterSignIn)Ink else Muted)}
            val showProviders=state.session==null || state.deletingAfterSignIn
            if(showProviders && !state.loading) {
                if(state.config?.googleClientId!=null) {
                    OutlinedButton(onClick={accounts.google(context)},enabled=!state.busy,modifier=Modifier.fillMaxWidth().height(48.dp),
                        shape=RoundedCornerShape(12.dp),border=BorderStroke(1.dp,Color(0xFF747775)),
                        colors=ButtonDefaults.outlinedButtonColors(containerColor=Color.White,contentColor=Color(0xFF1F1F1F))) {
                        Image(painterResource(R.drawable.google_g),null,Modifier.size(20.dp),contentScale=ContentScale.Fit)
                        Spacer(Modifier.width(10.dp));Text("Sign in with Google",fontSize=14.sp,fontWeight=FontWeight.Medium)
                    }
                }
                if(state.config?.appleCallback!=null) {
                    Button(onClick={accounts.apple(context)},enabled=!state.busy,modifier=Modifier.fillMaxWidth().height(48.dp)
                        .semantics{contentDescription="Sign in with Apple"},contentPadding=PaddingValues(0.dp),
                        shape=RoundedCornerShape(12.dp),colors=ButtonDefaults.buttonColors(containerColor=Color.Black,contentColor=Color.White)) {
                        Image(painterResource(R.drawable.apple_sign_in),null,Modifier.height(48.dp).widthIn(max=300.dp),contentScale=ContentScale.Fit)
                    }
                }
                if(state.config!=null && state.config?.available!=true)Text("Sign-in is being set up. You can keep recording.",fontSize=14.sp,lineHeight=20.sp,color=Muted)
                if(state.config==null && !state.busy)TextButton(onClick=accounts::refresh,modifier=Modifier.height(44.dp)){Text("Try again")}
            }
            if(state.applePending) {
                Text("Complete sign-in in your browser.",fontSize=13.sp,color=Muted)
                TextButton(onClick=accounts::cancelApple,enabled=!state.busy,modifier=Modifier.height(44.dp)){Text("Cancel sign-in")}
            }
            if(state.deletingAfterSignIn) {
                TextButton(onClick=accounts::cancelDeletion,enabled=!state.busy,modifier=Modifier.height(44.dp)){Text("Cancel deletion")}
            } else if(state.session!=null) {
                OutlinedButton(onClick=accounts::signOut,enabled=!state.busy,modifier=Modifier.fillMaxWidth().height(44.dp),shape=RoundedCornerShape(12.dp)) {Text("Sign out")}
                TextButton(onClick={deleteConfirmation=true},enabled=!state.busy,modifier=Modifier.height(44.dp),
                    colors=ButtonDefaults.textButtonColors(contentColor=MaterialTheme.colorScheme.error)) {Text("Delete account")}
            }
        }
    }
    if(deleteConfirmation)AlertDialog(onDismissRequest={deleteConfirmation=false},title={Text("Delete your account?")},
        text={Text("This removes your RecordPOV account. Your videos and drafts stay on this phone.")},
        confirmButton={TextButton(onClick={deleteConfirmation=false;accounts.deleteAccount()},colors=ButtonDefaults.textButtonColors(contentColor=MaterialTheme.colorScheme.error)){Text("Delete account")}},
        dismissButton={TextButton(onClick={deleteConfirmation=false}){Text("Cancel")}})
}
