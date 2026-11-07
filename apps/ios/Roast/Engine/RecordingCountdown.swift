import Foundation

/// Invalidates suspended permission/setup work without allowing an older
/// completion to clear a newer attempt.
struct RecordingStartGate {
    private var activeID: UUID?

    mutating func begin() -> UUID? {
        guard activeID == nil else { return nil }
        let id = UUID()
        activeID = id
        return id
    }

    func isCurrent(_ id: UUID) -> Bool { activeID == id }
    mutating func cancel() { activeID = nil }
    mutating func finish(_ id: UUID) {
        if activeID == id { activeID = nil }
    }
}

enum RecordingCountdown {
    static func seconds(_ requested: Int) -> Int {
        [0, 3, 5, 10].contains(requested) ? requested : 3
    }

    /// Sleeping is injectable so tests can advance time without waiting or
    /// touching camera/microphone permissions. Every displayed number lasts a second.
    @MainActor
    static func run(seconds requested: Int,
                    tick: (Int) -> Void,
                    wait: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws {
        let count = seconds(requested)
        guard count > 0 else { try Task.checkCancellation(); return }
        for remaining in stride(from: count, through: 1, by: -1) {
            try Task.checkCancellation()
            tick(remaining)
            try await wait(.seconds(1))
        }
        try Task.checkCancellation()
    }
}
