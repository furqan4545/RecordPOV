package studio.roast.app

import java.util.Locale

object ResolverEndpointDefaults {
    const val PUBLIC="https://api.recordpov.app"
    const val MIGRATION_KEY="recordpov-public-endpoint-v1"
    private val formerDefaults=setOf("http://10.0.2.2:8787","http://192.168.200.160:8787")

    /** Compare former defaults without normalizing an intentional custom address. */
    fun afterMigration(stored:String?,completed:Boolean):String {
        val existing=stored?.takeIf{it.isNotBlank()}?:return PUBLIC
        if(completed)return existing
        val comparable=existing.trim().trimEnd('/').lowercase(Locale.ROOT)
        return if(comparable in formerDefaults)PUBLIC else existing
    }
}
