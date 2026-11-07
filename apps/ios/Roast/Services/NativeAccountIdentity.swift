import AuthenticationServices
import CryptoKit
import Security
import UIKit
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

@MainActor
protocol AccountIdentityAuthorizing {
    func authorize(_ provider: AccountProvider, configuration: AccountConfiguration) async throws -> AccountIdentity
    func signOut()
    func cancel()
}

@MainActor
final class NativeAccountIdentity: AccountIdentityAuthorizing {
    private var apple: AppleAccountAuthorization?

    func authorize(_ provider: AccountProvider, configuration: AccountConfiguration) async throws -> AccountIdentity {
        guard let presenter = Self.presenter(), let window = presenter.view.window else { throw AccountError.unavailable }
        switch provider {
        case .apple:
            let flow = AppleAccountAuthorization(window: window)
            apple = flow
            defer { apple = nil }
            return try await flow.authorize()
        case .google:
            #if canImport(GoogleSignIn)
            guard let client = configuration.providers.google.iosClientId,
                  let server = configuration.providers.google.serverClientId else { throw AccountError.unavailable }
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: client, serverClientID: server)
            do {
                let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
                try Task.checkCancellation()
                guard let token = result.user.idToken?.tokenString, !token.isEmpty else { throw AccountError.invalidResponse }
                return AccountIdentity(provider: .google, idToken: token, name: result.user.profile?.name)
            } catch {
                let value = error as NSError
                if value.domain == kGIDSignInErrorDomain && value.code == -5 { throw CancellationError() }
                throw error
            }
            #else
            throw AccountError.unavailable
            #endif
        }
    }

    func signOut() {
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif
    }

    func cancel() { apple?.cancel() }

    static func handle(_ url: URL) -> Bool {
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.handle(url)
        #else
        false
        #endif
    }

    private static func presenter() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first(where: \.isKeyWindow)
        var current = window?.rootViewController
        while let next = current?.presentedViewController { current = next }
        if let navigation = current as? UINavigationController { current = navigation.visibleViewController }
        return current
    }
}

@MainActor
private final class AppleAccountAuthorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let window: UIWindow
    private var continuation: CheckedContinuation<AccountIdentity, Error>?
    private var controller: ASAuthorizationController?
    private var nonce = ""
    private var state = ""

    init(window: UIWindow) { self.window = window }

    func authorize() async throws -> AccountIdentity {
        nonce = try Self.randomValue()
        state = try Self.randomValue()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        request.state = state
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let controller = ASAuthorizationController(authorizationRequests: [request])
                self.controller = controller
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    func cancel() { finish(.failure(CancellationError())) }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { window }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              credential.state == state,
              let data = credential.identityToken, let token = String(data: data, encoding: .utf8), !token.isEmpty,
              let codeData = credential.authorizationCode, let code = String(data: codeData, encoding: .utf8), !code.isEmpty else {
            finish(.failure(AccountError.invalidResponse)); return
        }
        let name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }
        finish(.success(AccountIdentity(provider: .apple, idToken: token, nonce: nonce, name: name, authorizationCode: code)))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if (error as? ASAuthorizationError)?.code == .canceled { finish(.failure(CancellationError())) }
        else { finish(.failure(error)) }
    }

    private func finish(_ result: Result<AccountIdentity, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        controller = nil
        nonce = ""
        state = ""
        continuation.resume(with: result)
    }

    private static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AccountError.unavailable }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
