import Foundation

enum MediaServiceSettings {
    static let hostedAddress = "https://api.recordpov.app"
    static let addressKey = "resolverAddress"
    static let hostedMigrationKey = "resolverHostedEndpointMigrationV1"

    /// Explicit build overrides remain available for development and custom hosts.
    static func defaultAddress(configured: String?) -> String {
        guard let configured,
              let url = URL(string: configured),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return hostedAddress }
        return configured
    }

    /// Runs before AppStorage reads the endpoint. Only the old shipped origins
    /// are migrated; completing this once preserves later local development edits.
    @discardableResult
    static func migrateLegacyDefaultIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: hostedMigrationKey) else { return false }
        let shouldMigrate = defaults.string(forKey: addressKey).map(isLegacyDefault) ?? false
        if shouldMigrate { defaults.set(hostedAddress, forKey: addressKey) }
        defaults.set(true, forKey: hostedMigrationKey)
        return shouldMigrate
    }

    private static func isLegacyDefault(_ address: String) -> Bool {
        guard let components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "http", components.port == 8787,
              let host = components.host?.lowercased(),
              ["192.168.200.160", "127.0.0.1", "localhost"].contains(host),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              ["", "/"].contains(components.percentEncodedPath) else { return false }
        return true
    }
}
