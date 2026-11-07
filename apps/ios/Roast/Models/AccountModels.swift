import Foundation

enum AccountProvider: String, Codable, CaseIterable, Sendable {
    case apple, google
    var label: String { self == .apple ? "Apple" : "Google" }
}

struct AccountUser: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let email: String
    var image: String?
}

struct AccountSession: Codable, Equatable, Sendable {
    let token: String
    var expiresAt: Date
    var user: AccountUser
    let provider: AccountProvider
    var isExpired: Bool { expiresAt <= .now }
}

struct AccountConfiguration: Decodable, Equatable, Sendable {
    struct Google: Decodable, Equatable, Sendable {
        let enabled: Bool
        var serverClientId: String?
        var iosClientId: String?
    }
    struct Apple: Decodable, Equatable, Sendable {
        let enabled: Bool
        var bundleId: String?
    }
    struct Providers: Decodable, Equatable, Sendable {
        let google: Google
        let apple: Apple
    }
    let version: Int
    let enabled: Bool
    let providers: Providers
}

struct AccountIdentity: Encodable, Sendable {
    let provider: AccountProvider
    let idToken: String
    var nonce: String?
    var name: String?
    var authorizationCode: String?
}

struct AccountSignInResponse: Decodable, Sendable {
    let token: String
    let expiresAt: Date
    let user: AccountUser

    func session(provider: AccountProvider) throws -> AccountSession {
        guard !token.isEmpty, token.utf8.count <= 4096, !user.id.isEmpty, expiresAt > .now else {
            throw AccountError.invalidResponse
        }
        return AccountSession(token: token, expiresAt: expiresAt, user: user, provider: provider)
    }
}

struct AccountSessionResponse: Decodable, Sendable {
    let expiresAt: Date
    let user: AccountUser
}

enum AccountError: LocalizedError {
    case unavailable, invalidResponse, storage, wrongAccount
    case server(status: Int, code: String, message: String)

    var requiresSignIn: Bool {
        if case .server(let status, _, _) = self { return status == 401 }
        return false
    }
    var requiresFreshSignIn: Bool {
        if case .server(_, let code, _) = self { return code == "REAUTHENTICATION_REQUIRED" }
        return false
    }
    var errorDescription: String? {
        switch self {
        case .unavailable: "Sign-in isn’t available right now. You can keep recording without an account."
        case .invalidResponse: "The account service returned an unexpected response. Try again."
        case .storage: "Your account couldn’t be saved securely on this device. Try again."
        case .wrongAccount: "Sign in with the same account before deleting it."
        case .server(_, _, let message): message
        }
    }
}

/// Runtime provider config is combined with what the signed app can actually open.
/// In particular, Google's redirect scheme cannot be added by a server response.
struct AccountAppConfiguration: Sendable {
    let bundleID: String
    let appleEnabled: Bool
    let urlSchemes: Set<String>

    static var current: Self {
        let bundle = Bundle.main
        let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        let apple = bundle.object(forInfoDictionaryKey: "RecordPOVAppleSignInEnabled") as? String
        return Self(bundleID: bundle.bundleIdentifier ?? "", appleEnabled: apple == "YES", urlSchemes: Set(schemes))
    }

    func supports(_ provider: AccountProvider, configuration: AccountConfiguration) -> Bool {
        guard configuration.version == 1, configuration.enabled else { return false }
        switch provider {
        case .apple:
            return appleEnabled && configuration.providers.apple.enabled
                && configuration.providers.apple.bundleId == bundleID
        case .google:
            guard configuration.providers.google.enabled,
                  let client = configuration.providers.google.iosClientId,
                  let server = configuration.providers.google.serverClientId,
                  Self.validGoogleClientID(client), Self.validGoogleClientID(server) else { return false }
            return urlSchemes.contains(client.split(separator: ".").reversed().joined(separator: "."))
        }
    }

    private static func validGoogleClientID(_ value: String) -> Bool {
        value.hasSuffix(".apps.googleusercontent.com") && value.utf8.count < 256
            && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._").contains($0) }
    }
}
