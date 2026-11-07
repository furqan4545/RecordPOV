import Darwin
import Foundation
import Network
import UIKit

/// Foreground, job-scoped TCP forwarding. TLS stays end-to-end in yt-dlp;
/// every phone connection is pinned to a locally validated public DNS answer.
final class YouTubePhoneTransport: @unchecked Sendable {
    private final class Stream {
        let id: UInt32
        var connection: NWConnection?
        var connectionID = UUID()
        var addresses: [String] = []
        var addressIndex = 0
        var dnsOperation: Operation?
        var connectTimer: DispatchSourceTimer?
        var connected = false
        var receivePending = false
        var readEnded = false
        var writeEndRequested = false
        var writeEnded = false
        var writing = false
        var writes: [Data] = []
        var toServer = YouTubeRelayCredit()
        var fromServer = YouTubeRelayCredit()
        init(id: UInt32) { self.id = id }
    }
    private struct Outgoing {
        let message: URLSessionWebSocketTask.Message
        let bytes: Int
    }

    private let queue = DispatchQueue(label: "app.roast.youtube-relay", qos: .userInitiated)
    private let dnsQueue: OperationQueue = {
        let result = OperationQueue()
        result.name = "app.roast.youtube-relay-dns"
        result.maxConcurrentOperationCount = 2
        result.qualityOfService = .userInitiated
        return result
    }()
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let lifetime: TimeInterval
    private let foregroundLease: UUID
    private var backgroundObserver: NSObjectProtocol?
    private var readyTimer: DispatchSourceTimer?
    private var expiryTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?
    private var pendingPing: UUID?
    private var ready = false
    private var started = false
    private var closed = false
    private var terminalError: Error?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var failureContinuation: CheckedContinuation<Void, Error>?
    private var streams: [UInt32: Stream] = [:]
    private var usedIDs: Set<UInt32> = []
    private var retiredReceiveCredit: [UInt32: YouTubeRelayCredit] = [:]
    private var outgoing: [Outgoing] = []
    private var outgoingBytes = 0
    private var sending = false
    private var sessionBytes = 0

    private init(ticket: YouTubePhoneSessionTicket, lifetime: TimeInterval, foregroundLease: UUID) {
        self.lifetime = lifetime
        self.foregroundLease = foregroundLease
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration, delegate: YouTubeServiceRedirectGuard(), delegateQueue: nil)
        var request = URLRequest(url: ticket.socketUrl)
        request.setValue(ticket.token, forHTTPHeaderField: "X-YouTube-Session-Token")
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = YouTubeRelayPolicy.maximumFrame
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.close() }
    }

    deinit {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        readyTimer?.cancel()
        expiryTimer?.cancel()
        pingTimer?.cancel()
        dnsQueue.cancelAllOperations()
        for stream in streams.values { stream.connection?.cancel(); stream.connectTimer?.cancel() }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        let lease = foregroundLease
        Task { @MainActor in YouTubeRelayForegroundLease.release(lease) }
    }

    @MainActor
    static func connect(ticket: YouTubePhoneSessionTicket, api: URL) async throws -> YouTubePhoneTransport {
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState != .background else { throw CancellationError() }
        let lifetime = try ticket.validate(api: api)
        let transport = YouTubePhoneTransport(ticket: ticket, lifetime: lifetime,
                                             foregroundLease: YouTubeRelayForegroundLease.acquire())
        do { try await transport.waitUntilReady(); return transport }
        catch { transport.close(); throw error }
    }

    /// A companion task races this with the resolve request, so a lost peer
    /// cancels HTTP/worker work immediately instead of waiting for its timeout.
    func waitForFailure() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    if self.closed { continuation.resume(throwing: self.terminalError ?? CancellationError()) }
                    else if self.failureContinuation != nil { continuation.resume(throwing: YouTubeRelayError.invalidProtocol) }
                    else { self.failureContinuation = continuation }
                }
            }
        } onCancel: { self.close() }
    }

    func close() { queue.async { self.finish(CancellationError()) } }

    private func waitUntilReady() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    guard !self.closed, !self.started else {
                        continuation.resume(throwing: self.terminalError ?? CancellationError()); return
                    }
                    self.started = true
                    self.readyContinuation = continuation
                    self.readyTimer = self.timer(after: min(20, self.lifetime)) { [weak self] in
                        self?.finish(YouTubeRelayError.connectionFailed)
                    }
                    self.expiryTimer = self.timer(after: self.lifetime) { [weak self] in self?.finish(YouTubeRelayError.expired) }
                    self.socket.resume()
                    self.receiveNext()
                }
            }
        } onCancel: { self.close() }
    }

    private func receiveNext() {
        guard !closed else { return }
        socket.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                do {
                    let message = try result.get()
                    switch message {
                    case .string(let text):
                        guard text.utf8.count <= 8192 else { throw YouTubeRelayError.invalidProtocol }
                        try self.account(text.utf8.count)
                        try self.handle(JSONDecoder().decode(YouTubeRelayControl.self, from: Data(text.utf8)))
                    case .data(let data):
                        try self.account(data.count)
                        let frame = try YouTubeRelayFrame.decode(data)
                        try self.handleData(id: frame.id, payload: frame.payload)
                    @unknown default: throw YouTubeRelayError.invalidProtocol
                    }
                    self.receiveNext()
                } catch { self.finish(error is YouTubeRelayError ? error : YouTubeRelayError.connectionFailed) }
            }
        }
    }

    private func handle(_ control: YouTubeRelayControl) throws {
        if control.type == "ready" {
            guard !ready, control.version == 1 else { throw YouTubeRelayError.invalidProtocol }
            ready = true
            cancelTimer(&readyTimer)
            let continuation = readyContinuation
            readyContinuation = nil
            continuation?.resume()
            startHeartbeat()
            return
        }
        guard ready, let id = control.id, id > 0 else { throw YouTubeRelayError.invalidProtocol }
        switch control.type {
        case "open":
            guard streams.count < 8, usedIDs.count < 4096, !usedIDs.contains(id),
                  let rawHost = control.host, let port = control.port,
                  let host = YouTubeRelayPolicy.allowedHost(rawHost, port: port) else { throw YouTubeRelayError.rejectedDestination }
            usedIDs.insert(id)
            let stream = Stream(id: id)
            streams[id] = stream
            stream.connectTimer = timer(after: 12) { [weak self, weak stream] in
                guard let self, let stream, !stream.connected else { return }
                self.failStream(stream)
            }
            resolve(host, for: stream)
        case "ack":
            guard let bytes = control.bytes else { throw YouTubeRelayError.invalidProtocol }
            guard let stream = streams[id] else { try requireRetired(id); return }
            try stream.toServer.acknowledge(bytes)
            receiveTCP(stream)
            retireIfFinished(stream)
        case "end":
            guard let stream = streams[id] else { try requireRetired(id); return }
            guard stream.connected, !stream.writeEndRequested else { throw YouTubeRelayError.invalidProtocol }
            stream.writeEndRequested = true
            writeTCP(stream)
        case "close":
            guard let stream = streams[id] else { try requireRetired(id); return }
            removeStream(stream)
        default: throw YouTubeRelayError.invalidProtocol
        }
    }

    private func requireRetired(_ id: UInt32) throws {
        // In-flight data/acks can cross a stream close. Never reuse that id.
        guard usedIDs.contains(id) else { throw YouTubeRelayError.invalidProtocol }
    }

    private func handleData(id: UInt32, payload: Data) throws {
        guard ready else { throw YouTubeRelayError.invalidProtocol }
        guard let stream = streams[id] else {
            guard var credit = retiredReceiveCredit[id] else { throw YouTubeRelayError.invalidProtocol }
            // Crossed frames are allowed only within the old granted window.
            try credit.consume(payload.count)
            retiredReceiveCredit[id] = credit
            return
        }
        guard stream.connected, !stream.writeEndRequested, stream.writes.count < 256 else { throw YouTubeRelayError.invalidProtocol }
        try stream.fromServer.consume(payload.count)
        stream.writes.append(payload)
        writeTCP(stream)
    }

    private func resolve(_ host: String, for stream: Stream) {
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self, operation?.isCancelled == false else { return }
            let result = Result { try Self.publicAddresses(host) }
            self.queue.async {
                guard !self.closed, self.streams[stream.id] === stream, !stream.connected else { return }
                stream.dnsOperation = nil
                switch result {
                case .success(let addresses): stream.addresses = addresses; self.connectTCP(stream)
                case .failure: self.failStream(stream)
                }
            }
        }
        stream.dnsOperation = operation
        dnsQueue.addOperation(operation)
    }

    private static func publicAddresses(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        hints.ai_flags = AI_ADDRCONFIG
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { throw YouTubeRelayError.connectionFailed }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let node = current {
            let info = node.pointee
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(info.ai_addr, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
                throw YouTubeRelayError.rejectedDestination
            }
            let address = String(cString: buffer)
            guard YouTubeRelayPolicy.isPublicAddress(address) else { throw YouTubeRelayError.rejectedDestination }
            if !addresses.contains(address), addresses.count < 16 { addresses.append(address) }
            current = info.ai_next
        }
        guard !addresses.isEmpty else { throw YouTubeRelayError.connectionFailed }
        // Interleave families so a missing route does not delay the other family.
        var v4 = addresses.filter { !$0.contains(":") }, v6 = addresses.filter { $0.contains(":") }
        var result: [String] = []
        let firstIsV6 = addresses[0].contains(":")
        while !v4.isEmpty || !v6.isEmpty {
            if firstIsV6 { if !v6.isEmpty { result.append(v6.removeFirst()) }; if !v4.isEmpty { result.append(v4.removeFirst()) } }
            else { if !v4.isEmpty { result.append(v4.removeFirst()) }; if !v6.isEmpty { result.append(v6.removeFirst()) } }
        }
        return result
    }

    private func connectTCP(_ stream: Stream) {
        guard !closed, streams[stream.id] === stream else { return }
        stream.connection?.stateUpdateHandler = nil
        stream.connection?.cancel()
        guard stream.addressIndex < stream.addresses.count else { failStream(stream); return }
        let address = stream.addresses[stream.addressIndex]
        stream.addressIndex += 1
        let attempt = UUID()
        stream.connectionID = attempt
        let connection = NWConnection(host: NWEndpoint.Host(address), port: 443, using: .tcp)
        stream.connection = connection
        connection.stateUpdateHandler = { [weak self, weak stream] state in
            guard let self, let stream, !self.closed, self.streams[stream.id] === stream, stream.connectionID == attempt else { return }
            switch state {
            case .ready:
                stream.connected = true
                self.cancelTimer(&stream.connectTimer)
                self.enqueue(control: YouTubeRelayControl(type: "opened", id: stream.id))
                self.receiveTCP(stream)
            case .failed, .waiting:
                if !stream.connected { self.connectTCP(stream) } else { self.failStream(stream) }
            case .cancelled:
                if stream.connected { self.failStream(stream) }
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [weak self, weak stream] in
            guard let self, let stream, !self.closed, self.streams[stream.id] === stream,
                  !stream.connected, stream.connectionID == attempt else { return }
            self.connectTCP(stream)
        }
    }

    private func receiveTCP(_ stream: Stream) {
        guard !closed, streams[stream.id] === stream, stream.connected, !stream.receivePending,
              !stream.readEnded, stream.toServer.available > 0, let connection = stream.connection else { return }
        stream.receivePending = true
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: min(YouTubeRelayPolicy.maximumPayload, stream.toServer.available)) { [weak self, weak stream] data, _, complete, error in
            guard let self, let stream, !self.closed, self.streams[stream.id] === stream else { return }
            stream.receivePending = false
            do {
                if let data, !data.isEmpty {
                    try stream.toServer.consume(data.count)
                    self.enqueue(message: .data(try YouTubeRelayFrame.encode(id: stream.id, payload: data)))
                }
                if error != nil { self.failStream(stream); return }
                if complete {
                    stream.readEnded = true
                    self.enqueue(control: YouTubeRelayControl(type: "end", id: stream.id))
                    self.retireIfFinished(stream)
                } else { self.receiveTCP(stream) }
            } catch { self.finish(error) }
        }
    }

    private func writeTCP(_ stream: Stream) {
        guard !closed, streams[stream.id] === stream, stream.connected, !stream.writing,
              let connection = stream.connection else { return }
        if !stream.writes.isEmpty {
            let data = stream.writes.removeFirst()
            stream.writing = true
            connection.send(content: data, completion: .contentProcessed { [weak self, weak stream] error in
                guard let self, let stream, !self.closed, self.streams[stream.id] === stream else { return }
                stream.writing = false
                guard error == nil else { self.failStream(stream); return }
                do {
                    try stream.fromServer.acknowledge(data.count)
                    self.enqueue(control: YouTubeRelayControl(type: "ack", id: stream.id, bytes: data.count))
                    self.writeTCP(stream)
                } catch { self.finish(error) }
            })
        } else if stream.writeEndRequested, !stream.writeEnded {
            stream.writing = true
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { [weak self, weak stream] error in
                    guard let self, let stream, !self.closed, self.streams[stream.id] === stream else { return }
                    stream.writing = false
                    guard error == nil else { self.failStream(stream); return }
                    stream.writeEnded = true
                    self.retireIfFinished(stream)
                })
        }
    }

    private func retireIfFinished(_ stream: Stream) {
        if stream.readEnded, stream.writeEnded, !stream.writing, stream.writes.isEmpty,
           stream.toServer.available == YouTubeRelayPolicy.window {
            enqueue(control: YouTubeRelayControl(type: "close", id: stream.id))
            removeStream(stream)
        }
    }

    private func failStream(_ stream: Stream) {
        guard streams[stream.id] === stream else { return }
        enqueue(control: YouTubeRelayControl(type: "error", id: stream.id, message: "Connection failed"))
        removeStream(stream)
    }

    private func removeStream(_ stream: Stream) {
        retiredReceiveCredit[stream.id] = stream.fromServer
        streams[stream.id] = nil
        stream.dnsOperation?.cancel()
        cancelTimer(&stream.connectTimer)
        stream.connection?.stateUpdateHandler = nil
        stream.connection?.cancel()
        stream.connection = nil
        stream.writes.removeAll()
    }

    private func enqueue(control: YouTubeRelayControl) {
        do {
            let data = try JSONEncoder().encode(control)
            guard let text = String(data: data, encoding: .utf8) else { throw YouTubeRelayError.invalidProtocol }
            enqueue(message: .string(text))
        } catch { finish(error) }
    }

    private func enqueue(message: URLSessionWebSocketTask.Message) {
        guard !closed else { return }
        let bytes: Int
        switch message { case .data(let data): bytes = data.count; case .string(let text): bytes = text.utf8.count; @unknown default: finish(YouTubeRelayError.invalidProtocol); return }
        do {
            try account(bytes)
            guard outgoingBytes <= 2_621_440 - bytes, outgoing.count < 4096 else { throw YouTubeRelayError.limitExceeded }
            outgoing.append(Outgoing(message: message, bytes: bytes))
            outgoingBytes += bytes
            sendNext()
        } catch { finish(error) }
    }

    private func sendNext() {
        guard !closed, !sending, !outgoing.isEmpty else { return }
        sending = true
        let item = outgoing.removeFirst()
        socket.send(item.message) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                self.sending = false
                self.outgoingBytes -= item.bytes
                if error != nil { self.finish(YouTubeRelayError.connectionFailed) }
                else { self.sendNext() }
            }
        }
    }

    private func account(_ bytes: Int) throws {
        guard bytes >= 0, bytes <= YouTubeRelayPolicy.maximumSessionBytes - sessionBytes else { throw YouTubeRelayError.limitExceeded }
        sessionBytes += bytes
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self, !self.closed, self.pendingPing == nil else { return }
            let ping = UUID()
            self.pendingPing = ping
            self.socket.sendPing { [weak self] error in
                self?.queue.async {
                    guard let self, !self.closed, self.pendingPing == ping else { return }
                    self.pendingPing = nil
                    if error != nil { self.finish(YouTubeRelayError.connectionFailed) }
                }
            }
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, !self.closed, self.pendingPing == ping else { return }
                self.finish(YouTubeRelayError.connectionFailed)
            }
        }
        pingTimer = timer
        timer.resume()
    }

    private func timer(after seconds: TimeInterval, action: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: action)
        timer.resume()
        return timer
    }

    private func cancelTimer(_ timer: inout DispatchSourceTimer?) {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func finish(_ error: Error) {
        guard !closed else { return }
        closed = true
        terminalError = error
        cancelTimer(&readyTimer)
        cancelTimer(&expiryTimer)
        cancelTimer(&pingTimer)
        dnsQueue.cancelAllOperations()
        for stream in Array(streams.values) { removeStream(stream) }
        outgoing.removeAll()
        outgoingBytes = 0
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        backgroundObserver = nil
        let lease = foregroundLease
        Task { @MainActor in YouTubeRelayForegroundLease.release(lease) }
        let waitingReady = readyContinuation, waitingFailure = failureContinuation
        readyContinuation = nil
        failureContinuation = nil
        waitingReady?.resume(throwing: error)
        waitingFailure?.resume(throwing: error)
    }
}

/// Shared idle-timer lease; long server prepares also keep the screen awake so auto-lock does not suspend them.
@MainActor
enum YouTubeRelayForegroundLease {
    private static let manager = YouTubeRelayIdleLease(
        read: { UIApplication.shared.isIdleTimerDisabled }, write: { UIApplication.shared.isIdleTimerDisabled = $0 })
    static func acquire() -> UUID { manager.acquire() }
    static func release(_ id: UUID) { manager.release(id) }
}

/// Injectable idle-timer bookkeeping; tests never change the real device state.
@MainActor
final class YouTubeRelayIdleLease {
    private let read: () -> Bool
    private let write: (Bool) -> Void
    private var leases: Set<UUID> = []
    private var previous = false
    init(read: @escaping () -> Bool, write: @escaping (Bool) -> Void) {
        self.read = read
        self.write = write
    }
    func acquire() -> UUID {
        if leases.isEmpty { previous = read() }
        let id = UUID()
        leases.insert(id)
        write(true)
        return id
    }
    func release(_ id: UUID) {
        guard leases.remove(id) != nil, leases.isEmpty else { return }
        write(previous)
    }
}

/// A capability must never be forwarded to another endpoint by an HTTP redirect.
final class YouTubeServiceRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
