import Foundation
import XCTest
@testable import Roast

final class MediaServiceSettingsTests: XCTestCase {
    func testMissingOrInvalidBuildConfigurationDefaultsToHostedHTTPS() {
        for configured in [nil, "", "$(ROAST_MEDIA_SERVICE_URL)", "not a URL", "file:///tmp/service",
                           "https://user:password@example.com"] as [String?] {
            XCTAssertEqual(MediaServiceSettings.defaultAddress(configured: configured), "https://api.recordpov.app")
        }
    }

    func testExplicitPublicAndDevelopmentBuildOverridesArePreserved() {
        for configured in ["https://media.example.com", "https://media.example.com/custom", "http://127.0.0.1:8787"] {
            XCTAssertEqual(MediaServiceSettings.defaultAddress(configured: configured), configured)
        }
    }

    func testEachKnownLegacyOriginMigratesAndRecordsCompletion() {
        for host in ["192.168.200.160", "127.0.0.1", "localhost", "LOCALHOST"] {
            for path in ["", "/"] {
                withDefaults { defaults in
                    defaults.set("http://\(host):8787\(path)", forKey: MediaServiceSettings.addressKey)
                    XCTAssertTrue(MediaServiceSettings.migrateLegacyDefaultIfNeeded(defaults: defaults))
                    XCTAssertEqual(defaults.string(forKey: MediaServiceSettings.addressKey), MediaServiceSettings.hostedAddress)
                    XCTAssertTrue(defaults.bool(forKey: MediaServiceSettings.hostedMigrationKey))
                }
            }
        }
    }

    func testCustomOriginsAndPathsAreNotMistakenForLegacyDefaults() {
        for address in ["https://media.example.com", "https://api.recordpov.app",
                        "http://192.168.200.161:8787", "http://192.168.1.10:8787", "http://127.0.0.2:8787",
                        "http://localhost:9000", "https://localhost:8787", "http://localhost:8787/custom",
                        "http://localhost:8787?environment=dev", "http://localhost:8787#dev",
                        "http://localhost.evil.example:8787", "http://192.168.200.160.evil.example:8787",
                        "http://user:password@localhost:8787"] {
            withDefaults { defaults in
                defaults.set(address, forKey: MediaServiceSettings.addressKey)
                XCTAssertFalse(MediaServiceSettings.migrateLegacyDefaultIfNeeded(defaults: defaults), address)
                XCTAssertEqual(defaults.string(forKey: MediaServiceSettings.addressKey), address)
                XCTAssertTrue(defaults.bool(forKey: MediaServiceSettings.hostedMigrationKey))
            }
        }
    }

    func testFreshInstallMarksMigrationWithoutCreatingACustomAddress() {
        withDefaults { defaults in
            XCTAssertFalse(MediaServiceSettings.migrateLegacyDefaultIfNeeded(defaults: defaults))
            XCTAssertNil(defaults.object(forKey: MediaServiceSettings.addressKey))
            XCTAssertTrue(defaults.bool(forKey: MediaServiceSettings.hostedMigrationKey))
        }
    }

    func testLaterIntentionalLocalAddressIsNotMigratedAgain() {
        withDefaults { defaults in
            defaults.set("http://192.168.200.160:8787", forKey: MediaServiceSettings.addressKey)
            XCTAssertTrue(MediaServiceSettings.migrateLegacyDefaultIfNeeded(defaults: defaults))
            defaults.set("http://localhost:8787", forKey: MediaServiceSettings.addressKey)
            XCTAssertFalse(MediaServiceSettings.migrateLegacyDefaultIfNeeded(defaults: defaults))
            XCTAssertEqual(defaults.string(forKey: MediaServiceSettings.addressKey), "http://localhost:8787")
        }
    }

    func testCustomPublicAddressAlsoCompletesTheOneTimeMigration() {
        withDefaults { defaults in
            defaults.set("https://custom.example.com", forKey: MediaServiceSettings.addressKey)
            XCTAssertFalse(MediaServiceSettings.migrateLegacyDefaultIfNeeded(defaults: defaults))
            defaults.set("http://127.0.0.1:8787", forKey: MediaServiceSettings.addressKey)
            XCTAssertFalse(MediaServiceSettings.migrateLegacyDefaultIfNeeded(defaults: defaults))
            XCTAssertEqual(defaults.string(forKey: MediaServiceSettings.addressKey), "http://127.0.0.1:8787")
        }
    }

    func testMigrationLeavesDraftAndOtherPreferencesUntouched() {
        withDefaults { defaults in
            let sentinel = Data([0, 1, 2, 254, 255])
            defaults.set(sentinel, forKey: "draftRecoverySentinel")
            defaults.set(5, forKey: "recordingCountdownSeconds")
            defaults.set("http://127.0.0.1:8787", forKey: MediaServiceSettings.addressKey)
            MediaServiceSettings.migrateLegacyDefaultIfNeeded(defaults: defaults)
            XCTAssertEqual(defaults.data(forKey: "draftRecoverySentinel"), sentinel)
            XCTAssertEqual(defaults.integer(forKey: "recordingCountdownSeconds"), 5)
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "MediaServiceSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }
}
