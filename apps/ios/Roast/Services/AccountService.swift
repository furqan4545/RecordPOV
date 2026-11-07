import Foundation
import Observation

@MainActor @Observable
final class AccountService {
    private(set) var session: AccountSession?
    private(set) var configuration: AccountConfiguration?
    private(set) var isWorking = false
    private(set) var hasLoaded = false
    private(set) var needsReauthentication = false
    var errorMessage: String?
    private(set) var statusMessage: String?

    private let api: any AccountServing
    private let store: any AccountSessionStoring
    private let identity: any AccountIdentityAuthorizing
    private let app: AccountAppConfiguration
    private var operation = UUID()

    init(api: any AccountServing = AccountAPI(), store: any AccountSessionStoring = AccountKeychain(),
         identity: (any AccountIdentityAuthorizing)? = nil, app: AccountAppConfiguration = .current) {
        self.api = api; self.store = store; self.identity = identity ?? NativeAccountIdentity(); self.app = app
    }

    var availableProviders: [AccountProvider] {
        guard let configuration else { return [] }
        return AccountProvider.allCases.filter {
            app.supports($0, configuration: configuration) && (!needsReauthentication || $0 == session?.provider)
        }
    }

    func load() async {
        guard !isWorking else { return }
        isWorking = true; errorMessage = nil
        let id = UUID(); operation = id
        defer { if operation == id { isWorking = false; hasLoaded = true } }
        do {
            if session == nil {
                let saved = try store.load()
                if saved?.isExpired == true { try store.clear() }
                else { session = saved }
            }
            let config = try await api.configuration()
            try Task.checkCancellation()
            guard operation == id else { return }
            configuration = config
            if let saved = session {
                do {
                    let current = try await api.session(token: saved.token)
                    try Task.checkCancellation()
                    guard operation == id else { return }
                    guard current.user.id == saved.user.id, current.expiresAt > .now else { throw AccountError.invalidResponse }
                    var updated = saved
                    updated.expiresAt = current.expiresAt; updated.user = current.user
                    try store.save(updated)
                    session = updated
                } catch {
                    guard operation == id, !Task.isCancelled else { return }
                    if (error as? AccountError)?.requiresSignIn == true {
                        try store.clear(); session = nil; needsReauthentication = false
                        statusMessage = "Your session ended. Sign in again when you’re ready."
                    } else { throw error }
                }
            }
        } catch {
            if operation == id, !Task.isCancelled, !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func signIn(with provider: AccountProvider) async {
        guard !isWorking, availableProviders.contains(provider), let configuration else { return }
        isWorking = true; errorMessage = nil; statusMessage = nil
        let id = UUID(); operation = id
        let deletingUserID = needsReauthentication ? session?.user.id : nil
        defer { if operation == id { isWorking = false } }
        do {
            let proof = try await identity.authorize(provider, configuration: configuration)
            try Task.checkCancellation()
            guard operation == id else { return }
            let response = try await api.signIn(proof)
            let fresh = try response.session(provider: provider)
            guard operation == id, !Task.isCancelled else {
                try? await api.signOut(token: fresh.token)
                return
            }
            if let deletingUserID, deletingUserID != fresh.user.id {
                try? await api.signOut(token: fresh.token)
                throw AccountError.wrongAccount
            }
            do { try store.save(fresh) }
            catch { try? await api.signOut(token: fresh.token); throw error }
            session = fresh
            if deletingUserID != nil { try await performDeletion(fresh, operation: id) }
            else { needsReauthentication = false; statusMessage = "You’re signed in." }
        } catch {
            guard operation == id, !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        guard !isWorking else { return }
        let token = session?.token
        isWorking = true; errorMessage = nil; statusMessage = nil
        let id = UUID(); operation = id
        defer { if operation == id { isWorking = false } }
        do {
            try store.clear()
            session = nil; needsReauthentication = false
            identity.signOut()
            statusMessage = "You’re signed out. Your videos and drafts are still on this device."
            if let token { try? await api.signOut(token: token) }
        } catch { if operation == id { errorMessage = error.localizedDescription } }
    }

    func deleteAccount() async {
        guard !isWorking, let session else { return }
        isWorking = true; errorMessage = nil; statusMessage = nil
        let id = UUID(); operation = id
        defer { if operation == id { isWorking = false } }
        do { try await performDeletion(session, operation: id) }
        catch {
            guard operation == id, !Task.isCancelled else { return }
            if (error as? AccountError)?.requiresFreshSignIn == true {
                needsReauthentication = true
                statusMessage = "Sign in again with \(session.provider.label) to confirm deletion."
            } else { errorMessage = error.localizedDescription }
        }
    }

    func cancelPendingDeletion() { needsReauthentication = false; errorMessage = nil; statusMessage = nil }

    func cancel() {
        operation = UUID()
        identity.cancel()
        isWorking = false
    }

    private func performDeletion(_ saved: AccountSession, operation id: UUID) async throws {
        try await api.deleteAccount(token: saved.token)
        guard operation == id else { return }
        try store.clear()
        session = nil; needsReauthentication = false
        identity.signOut()
        statusMessage = "Your account is deleted. Your videos and drafts are still on this device."
    }
}
