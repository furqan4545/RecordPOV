import Foundation
import XCTest
@testable import Roast

@MainActor
final class AccountServiceTests: XCTestCase {
    func testProviderButtonsRequireServerEnablementAndRegisteredGoogleRedirect() {
        let config = Self.configuration()
        let noScheme = AccountAppConfiguration(bundleID: "com.furqanali.roast", appleEnabled: true, urlSchemes: [])
        XCTAssertTrue(noScheme.supports(.apple, configuration: config))
        XCTAssertFalse(noScheme.supports(.google, configuration: config))
        XCTAssertTrue(Self.app.supports(.google, configuration: config))
        let wrongBundle = AccountAppConfiguration(bundleID: "another.app", appleEnabled: true, urlSchemes: [])
        XCTAssertFalse(wrongBundle.supports(.apple, configuration: config))
        let disabled = AccountConfiguration(version: 1, enabled: false, providers: config.providers)
        XCTAssertFalse(Self.app.supports(.google, configuration: disabled))
        XCTAssertFalse(Self.app.supports(.apple, configuration: disabled))
    }

    func testRestoredSessionRefreshesUserAndSlidingExpiryInSecureStore() async {
        let api = FakeAccountAPI()
        let store = MemoryAccountStore(session: Self.session())
        api.current = AccountSessionResponse(expiresAt: .now.addingTimeInterval(7200),
                                            user: AccountUser(id: "user-1", name: "Updated", email: "person@example.com"))
        let account = make(api, store)
        await account.load()
        XCTAssertEqual(account.session?.token, "test-bearer")
        XCTAssertEqual(account.session?.user.name, "Updated")
        XCTAssertEqual(store.session?.expiresAt, api.current.expiresAt)
        XCTAssertEqual(api.checkedTokens, ["test-bearer"])
    }

    func testExpiredAndServerRejectedSessionsAreRemoved() async {
        let api = FakeAccountAPI()
        let expired = MemoryAccountStore(session: Self.session(expiresAt: .now.addingTimeInterval(-1)))
        let first = make(api, expired)
        await first.load()
        XCTAssertNil(first.session)
        XCTAssertNil(expired.session)
        XCTAssertTrue(api.checkedTokens.isEmpty)

        let rejected = MemoryAccountStore(session: Self.session())
        api.sessionFailure = AccountError.server(status: 401, code: "UNAUTHORIZED", message: "Session ended")
        let second = make(api, rejected)
        await second.load()
        XCTAssertNil(second.session)
        XCTAssertNil(rejected.session)
        XCTAssertNil(second.errorMessage)
    }

    func testOfflineSessionCheckKeepsTheExistingSession() async {
        let api = FakeAccountAPI()
        api.sessionFailure = URLError(.notConnectedToInternet)
        let store = MemoryAccountStore(session: Self.session())
        let account = make(api, store)
        await account.load()
        XCTAssertEqual(account.session?.user.id, "user-1")
        XCTAssertNotNil(store.session)
        XCTAssertNotNil(account.errorMessage)
    }

    func testCancelDuringProviderAuthorizationNeverCreatesAServerSession() async {
        let api = FakeAccountAPI()
        let store = MemoryAccountStore()
        let identity = FakeAccountIdentity()
        identity.holdAuthorization = true
        let account = make(api, store, identity)
        await account.load()
        let task = Task { await account.signIn(with: .apple) }
        while identity.pending == nil { await Task.yield() }
        account.cancel()
        await task.value
        XCTAssertNil(account.session)
        XCTAssertNil(store.session)
        XCTAssertTrue(api.identities.isEmpty)
        XCTAssertNil(account.errorMessage)
        XCTAssertFalse(account.isWorking)
    }

    func testSignOutClearsSecureSessionEvenWhenServerIsOffline() async {
        let api = FakeAccountAPI()
        api.signOutFailure = URLError(.notConnectedToInternet)
        let store = MemoryAccountStore(session: Self.session())
        let identity = FakeAccountIdentity()
        let account = make(api, store, identity)
        await account.load()
        await account.signOut()
        XCTAssertNil(account.session)
        XCTAssertNil(store.session)
        XCTAssertEqual(api.signedOutTokens, ["test-bearer"])
        XCTAssertEqual(identity.signOutCount, 1)
        XCTAssertNil(account.errorMessage)
    }

    func testDeletionRequiresFreshSameAccountSignInAndUsesNewBearer() async {
        let api = FakeAccountAPI()
        let store = MemoryAccountStore(session: Self.session())
        let account = make(api, store)
        await account.load()
        api.deleteFailure = AccountError.server(status: 401, code: "REAUTHENTICATION_REQUIRED", message: "Sign in again")
        await account.deleteAccount()
        XCTAssertTrue(account.needsReauthentication)
        XCTAssertNotNil(store.session)
        XCTAssertEqual(account.availableProviders, [.apple])
        api.deleteFailure = nil
        await account.signIn(with: .apple)
        XCTAssertEqual(api.deletedTokens, ["test-bearer", "fresh-bearer"])
        XCTAssertNil(account.session)
        XCTAssertNil(store.session)
        XCTAssertFalse(account.needsReauthentication)
    }

    func testWrongAccountDuringDeletionNeverDeletesThatAccount() async {
        let api = FakeAccountAPI()
        let store = MemoryAccountStore(session: Self.session())
        let account = make(api, store)
        await account.load()
        api.deleteFailure = AccountError.server(status: 401, code: "REAUTHENTICATION_REQUIRED", message: "Sign in again")
        await account.deleteAccount()
        api.signInUserID = "someone-else"
        await account.signIn(with: .apple)
        XCTAssertEqual(api.deletedTokens, ["test-bearer"])
        XCTAssertEqual(api.signedOutTokens, ["fresh-bearer"])
        XCTAssertEqual(store.session?.user.id, "user-1")
        XCTAssertEqual(account.session?.user.id, "user-1")
        XCTAssertEqual(account.errorMessage, AccountError.wrongAccount.localizedDescription)
    }

    func testAppleRevocationFailureRetainsAccountAndSecureSession() async {
        let api = FakeAccountAPI()
        let store = MemoryAccountStore(session: Self.session())
        let account = make(api, store)
        await account.load()
        api.deleteFailure = AccountError.server(status: 503, code: "APPLE_REVOCATION_FAILED", message: "Try again later")
        await account.deleteAccount()
        XCTAssertNotNil(account.session)
        XCTAssertNotNil(store.session)
        XCTAssertEqual(account.errorMessage, "Try again later")
    }

    func testFailedKeychainWriteRevokesNewSessionAndDoesNotSignIn() async {
        let api = FakeAccountAPI()
        let store = MemoryAccountStore()
        let account = make(api, store)
        await account.load()
        store.failSave = true
        await account.signIn(with: .apple)
        XCTAssertNil(account.session)
        XCTAssertNil(store.session)
        XCTAssertEqual(api.signedOutTokens, ["fresh-bearer"])
        XCTAssertNotNil(account.errorMessage)
    }

    private func make(_ api: FakeAccountAPI, _ store: MemoryAccountStore,
                      _ identity: FakeAccountIdentity? = nil) -> AccountService {
        AccountService(api: api, store: store, identity: identity ?? FakeAccountIdentity(), app: Self.app)
    }

    private static let app = AccountAppConfiguration(bundleID: "com.furqanali.roast", appleEnabled: true,
                                                     urlSchemes: ["com.googleusercontent.apps.123-ios"])
    fileprivate static func configuration() -> AccountConfiguration {
        AccountConfiguration(version: 1, enabled: true, providers: .init(
            google: .init(enabled: true, serverClientId: "123-web.apps.googleusercontent.com", iosClientId: "123-ios.apps.googleusercontent.com"),
            apple: .init(enabled: true, bundleId: "com.furqanali.roast")))
    }
    fileprivate static func session(expiresAt: Date = .now.addingTimeInterval(3600)) -> AccountSession {
        AccountSession(token: "test-bearer", expiresAt: expiresAt,
                       user: AccountUser(id: "user-1", name: "Person", email: "person@example.com"), provider: .apple)
    }
}

private final class MemoryAccountStore: AccountSessionStoring {
    var session: AccountSession?
    var failSave = false
    init(session: AccountSession? = nil) { self.session = session }
    func load() throws -> AccountSession? { session }
    func save(_ session: AccountSession) throws { if failSave { throw AccountError.storage }; self.session = session }
    func clear() throws { session = nil }
}

@MainActor private final class FakeAccountIdentity: AccountIdentityAuthorizing {
    var holdAuthorization = false
    var pending: CheckedContinuation<AccountIdentity, Error>?
    var signOutCount = 0
    func authorize(_ provider: AccountProvider, configuration: AccountConfiguration) async throws -> AccountIdentity {
        if holdAuthorization { return try await withCheckedThrowingContinuation { pending = $0 } }
        return AccountIdentity(provider: provider, idToken: "synthetic-id-token", nonce: "synthetic-nonce", authorizationCode: "synthetic-code")
    }
    func signOut() { signOutCount += 1 }
    func cancel() { pending?.resume(throwing: CancellationError()); pending = nil }
}

@MainActor private final class FakeAccountAPI: AccountServing {
    var current = AccountSessionResponse(expiresAt: .now.addingTimeInterval(3600), user: AccountServiceTests.session().user)
    var sessionFailure: Error?
    var signOutFailure: Error?
    var deleteFailure: Error?
    var signInUserID = "user-1"
    var checkedTokens: [String] = []
    var signedOutTokens: [String] = []
    var deletedTokens: [String] = []
    var identities: [AccountIdentity] = []
    func configuration() async throws -> AccountConfiguration { AccountServiceTests.configuration() }
    func signIn(_ identity: AccountIdentity) async throws -> AccountSignInResponse {
        identities.append(identity)
        return AccountSignInResponse(token: "fresh-bearer", expiresAt: .now.addingTimeInterval(3600),
                                     user: AccountUser(id: signInUserID, name: "Person", email: "person@example.com"))
    }
    func session(token: String) async throws -> AccountSessionResponse {
        checkedTokens.append(token)
        if let sessionFailure { throw sessionFailure }
        return current
    }
    func signOut(token: String) async throws {
        signedOutTokens.append(token)
        if let signOutFailure { throw signOutFailure }
    }
    func deleteAccount(token: String) async throws {
        deletedTokens.append(token)
        if let deleteFailure { throw deleteFailure }
    }
}
