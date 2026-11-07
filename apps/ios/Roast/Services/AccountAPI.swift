import Foundation

protocol AccountServing {
    func configuration() async throws -> AccountConfiguration
    func signIn(_ identity: AccountIdentity) async throws -> AccountSignInResponse
    func session(token: String) async throws -> AccountSessionResponse
    func signOut(token: String) async throws
    func deleteAccount(token: String) async throws
}

struct AccountAPI: AccountServing {
    // Account credentials always go to our HTTPS account service, independently
    // of any custom video resolver address the user has entered.
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = URL(string: "https://api.recordpov.app")!, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration, delegate: AccountRedirectGuard(), delegateQueue: nil)
        }
    }

    func configuration() async throws -> AccountConfiguration {
        try await decoded("config", method: "GET")
    }
    func signIn(_ identity: AccountIdentity) async throws -> AccountSignInResponse {
        try await decoded("sign-in", method: "POST", body: JSONEncoder().encode(identity))
    }
    func session(token: String) async throws -> AccountSessionResponse {
        try await decoded("session", method: "GET", token: token)
    }
    func signOut(token: String) async throws { _ = try await request("sign-out", method: "POST", token: token) }
    func deleteAccount(token: String) async throws { _ = try await request("account", method: "DELETE", token: token) }

    private func decoded<T: Decodable>(_ path: String, method: String, token: String? = nil, body: Data? = nil) async throws -> T {
        let data = try await request(path, method: method, token: token, body: body)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO8601 date")
        }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw AccountError.invalidResponse }
    }

    private func request(_ path: String, method: String, token: String? = nil, body: Data? = nil) async throws -> Data {
        guard baseURL.scheme == "https", baseURL.user == nil, baseURL.password == nil else { throw AccountError.unavailable }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/auth/\(path)"))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, data.count <= 128 * 1024 else { throw AccountError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            struct Envelope: Decodable { struct Failure: Decodable { let code: String; let message: String }; let error: Failure }
            let failure = try? JSONDecoder().decode(Envelope.self, from: data).error
            throw AccountError.server(status: http.statusCode, code: failure?.code ?? "REQUEST_FAILED",
                                      message: failure?.message ?? "The account service couldn’t be reached. Try again.")
        }
        return data
    }
}

private final class AccountRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
