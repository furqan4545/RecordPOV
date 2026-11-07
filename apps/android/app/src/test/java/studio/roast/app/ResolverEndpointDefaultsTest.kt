package studio.roast.app

import org.junit.Assert.assertEquals
import org.junit.Test

class ResolverEndpointDefaultsTest {
    @Test fun freshInstallsUseThePublicHttpsService() {
        assertEquals("https://api.recordpov.app",ResolverEndpointDefaults.afterMigration(null,false))
        assertEquals("https://api.recordpov.app",ResolverEndpointDefaults.afterMigration("  ",false))
    }
    @Test fun knownEmulatorAndMacDefaultsMigrateOnce() {
        for(address in listOf("http://10.0.2.2:8787","http://192.168.200.160:8787"," HTTP://10.0.2.2:8787/ ","http://192.168.200.160:8787/"))
            assertEquals(ResolverEndpointDefaults.PUBLIC,ResolverEndpointDefaults.afterMigration(address,false))
    }
    @Test fun intentionalPublicAddressesArePreservedExactly() {
        for(address in listOf("https://custom.example/CaseSensitivePath/","https://api.recordpov.app","https://custom.example:9443"))
            assertEquals(address,ResolverEndpointDefaults.afterMigration(address,false))
    }
    @Test fun differentPrivateHostsPortsAndPathsArePreserved() {
        for(address in listOf("http://192.168.1.100:8787","http://192.168.200.160:9000","http://10.0.2.2:8787/custom","http://localhost:8787","http://127.0.0.1:8787"))
            assertEquals(address,ResolverEndpointDefaults.afterMigration(address,false))
    }
    @Test fun intentionalHttpsOnAFormerLocalHostIsNotAnOldHttpDefault() {
        val address="https://192.168.200.160:8787"
        assertEquals(address,ResolverEndpointDefaults.afterMigration(address,false))
    }
    @Test fun completedMigrationPreservesFutureLocalDevelopmentChoices() {
        for(address in listOf("http://10.0.2.2:8787","http://192.168.200.160:8787"))
            assertEquals(address,ResolverEndpointDefaults.afterMigration(address,true))
    }
    @Test fun repeatedLaunchKeepsTheMigratedPublicAddress() {
        val migrated=ResolverEndpointDefaults.afterMigration("http://10.0.2.2:8787",false)
        assertEquals(migrated,ResolverEndpointDefaults.afterMigration(migrated,true))
    }
}
