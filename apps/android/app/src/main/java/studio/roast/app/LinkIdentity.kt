package studio.roast.app

import java.net.URI
import java.net.URLDecoder

/** Local identity comparison only: no network, tracking parameters, or playback-position changes. */
internal object LinkIdentity {
    fun key(value:String?):String?=runCatching {
        val input=value?.trim()?.takeIf{it.isNotBlank()&&it.length<=4096} ?: return null
        val uri=URI(input)
        if(uri.scheme!="https"||uri.rawUserInfo!=null||uri.port !in listOf(-1,443))return null
        val host=uri.host?.lowercase(java.util.Locale.ROOT) ?: return null
        val path=uri.path.orEmpty()
        when(host) {
            "youtu.be","www.youtu.be"->Regex("^/([A-Za-z0-9_-]{11})/?$").matchEntire(path)?.let{"youtube:${it.groupValues[1]}"}
            "youtube.com","www.youtube.com","m.youtube.com","music.youtube.com"->{
                val id=if(path=="/watch") {
                    val values=uri.rawQuery.orEmpty().split('&').mapNotNull {part->
                        val pair=part.split('=',limit=2)
                        if(URLDecoder.decode(pair[0],"UTF-8")=="v"&&pair.size==2)URLDecoder.decode(pair[1],"UTF-8")else null
                    }.distinct()
                    values.singleOrNull()
                } else Regex("^/(?:shorts|live|embed)/([A-Za-z0-9_-]{11})/?$").matchEntire(path)?.groupValues?.get(1)
                id?.takeIf{it.matches(Regex("[A-Za-z0-9_-]{11}"))}?.let{"youtube:$it"}
            }
            "instagram.com","www.instagram.com","m.instagram.com"->Regex("^/(?:reel|reels|p|tv)/([A-Za-z0-9_-]{3,64})/?$").matchEntire(path)?.let{"instagram:${it.groupValues[1]}"}
            "x.com","www.x.com","twitter.com","www.twitter.com","mobile.twitter.com"->Regex("^/(?:[A-Za-z0-9_]{1,30}/status|i/web/status)/([0-9]{5,30})/?$").matchEntire(path)?.let{"x:${it.groupValues[1]}"}
            // www.tiktok.com/t/<code> short links are followed on the phone by TikTokPhoneResolver, like vt./vm.
            "tiktok.com","www.tiktok.com","m.tiktok.com"->Regex("^/@[A-Za-z0-9_.]{1,50}/video/([0-9]{5,30})/?$").matchEntire(path)?.let{"tiktok:${it.groupValues[1]}"} ?: Regex("^/t/([A-Za-z0-9]{3,40})/?$").matchEntire(path)?.let{"tiktok-t:${it.groupValues[1]}"}
            "vm.tiktok.com","vt.tiktok.com"->Regex("^/([A-Za-z0-9]{3,40})/?$").matchEntire(path)?.let{"tiktok-short:${it.groupValues[1]}"}
            else->null
        }
    }.getOrNull()
    fun same(first:String?,second:String?):Boolean {
        if(first.isNullOrBlank()||second.isNullOrBlank())return false
        if(first.trim()==second.trim())return true
        return key(first)?.let{it==key(second)}?:false
    }
}

internal data class HomeVideoActions(val savedPrimary:Boolean,val primaryEnabled:Boolean,val showNewButton:Boolean,val newButtonBusy:Boolean)
internal object HomeVideoPolicy {
    fun actions(existing:ImportedVideo?,input:String,active:Boolean,activeInput:String?,activeLocal:Boolean,localRetry:Boolean=false):HomeVideoActions {
        val valid=LinkIdentity.key(input)!=null
        val different=existing!=null&&valid&&!LinkIdentity.same(input,existing.sourceUrl)&&!LinkIdentity.same(input,existing.requestedUrl)
        return HomeVideoActions(existing!=null,existing!=null||!active&&(valid||localRetry),different,
            different&&active&&!activeLocal&&LinkIdentity.same(input,activeInput))
    }
    fun shortName(title:String):String {
        val clean=title.replace(Regex("\\s+")," ").replace(Regex("\\.(mp4|mov|m4v)$",RegexOption.IGNORE_CASE),"").trim().ifBlank{"Saved video"}
        val count=clean.codePointCount(0,clean.length)
        return if(count<=28)clean else clean.substring(0,clean.offsetByCodePoints(0,27))+"…"
    }
}
