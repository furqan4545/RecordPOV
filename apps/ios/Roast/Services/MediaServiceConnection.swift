import Darwin
import Foundation
import Network

enum MediaConnectionFailure: LocalizedError {
    case localNetworkDenied
    case unreachable

    var offersSettings: Bool {
        if case .localNetworkDenied = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .localNetworkDenied:
            return "Allow Local Network access for RecordPOV in Settings, then try again."
        case .unreachable:
            return "Keep your iPhone and Mac on the same Wi-Fi, and make sure the media service is running on your Mac."
        }
    }
}

enum MediaServiceConnection {
    /// Recognizes local address forms without DNS lookup or suffix guessing.
    static func isLocal(_ url: URL) -> Bool {
        guard var host = connectionHost(url)?.lowercased() else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        // A scope identifier is part of an IPv6 endpoint, not its address bytes.
        let address = String(host.split(separator: "%", maxSplits: 1).first ?? "")
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            return withUnsafeBytes(of: &ipv4) { localIPv4(Array($0)) }
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, address, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: &ipv6) { raw in
            let bytes = Array(raw)
            let loopback = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
            let uniqueLocal = bytes[0] & 0xfe == 0xfc
            let linkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
            let mappedIPv4 = bytes[0..<10].allSatisfy { $0 == 0 }
                && bytes[10] == 0xff && bytes[11] == 0xff
            return loopback || uniqueLocal || linkLocal
                || (mappedIPv4 && localIPv4(Array(bytes[12..<16])))
        }
    }

    /// Opens no HTTP request and changes no permission state itself. Network
    /// framework waits while iOS presents the local-network consent alert.
    static func waitUntilReachable(_ url: URL, timeout: TimeInterval = 12) async throws {
        try Task.checkCancellation()
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = connectionHost(url), !host.isEmpty,
              let port = NWEndpoint.Port(rawValue: UInt16(exactly: url.port ?? (scheme == "https" ? 443 : 80)) ?? 0),
              port.rawValue != 0, timeout.isFinite, timeout > 0 else {
            throw MediaConnectionFailure.unreachable
        }
        let attempt = LocalMediaConnectionAttempt(host: host, port: port, timeout: timeout)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                attempt.start(continuation)
            }
        } onCancel: {
            attempt.cancel()
        }
    }

    private static func connectionHost(_ url: URL) -> String? {
        guard var host = url.host(percentEncoded: false) else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        return host
    }

    private static func localIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        return bytes[0] == 10 || bytes[0] == 127
            || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 169 && bytes[1] == 254)
    }
}

/// All mutable state, including a cancellation arriving before start(), belongs
/// to this queue. finish() is the single continuation-resumption path.
private final class LocalMediaConnectionAttempt: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.roast.local-connection")
    private let host: String
    private let port: NWEndpoint.Port
    private let timeout: TimeInterval
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    init(host: String, port: NWEndpoint.Port, timeout: TimeInterval) {
        self.host = host
        self.port = port
        self.timeout = timeout
    }

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        queue.async { [self] in
            if let result = self.result {
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            let connection = NWConnection(host: NWEndpoint.Host(self.host), port: self.port, using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.timeout)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.finish(.failure(self.currentFailure))
            }
            self.timer = timer
            timer.resume()
            connection.start(queue: self.queue)
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private var currentFailure: MediaConnectionFailure {
        if connection?.currentPath?.unsatisfiedReason == .localNetworkDenied {
            return .localNetworkDenied
        }
        return .unreachable
    }

    private func handle(_ state: NWConnection.State) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard result == nil else { return }
        switch state {
        case .ready:
            finish(.success(()))
        case .waiting:
            // A first permission prompt can initially look exactly like a denial.
            // NWConnection retries automatically after consent; let the deadline
            // inspect the current path instead of caching a stale denied reason.
            break
        case .failed, .cancelled:
            finish(.failure(currentFailure))
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard self.result == nil else { return }
        self.result = result
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
