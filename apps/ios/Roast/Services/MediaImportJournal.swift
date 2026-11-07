import Foundation

enum MediaJournalRead<Value> {
    case missing
    case loaded(Value)
    case deferred
    case unreadable
}

/// A locked or corrupt journal is not evidence that its OS-owned tasks are
/// orphaned. In particular, callers must never prune on either result.
enum MediaImportJournal {
    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
    static func read<Value: Decodable>(_ type: Value.Type, from url: URL, protectedDataAvailable: Bool) -> MediaJournalRead<Value> {
        guard protectedDataAvailable else { return .deferred }
        do { return .loaded(try JSONDecoder().decode(type, from: Data(contentsOf: url))) }
        catch {
            let error = error as NSError
            if (error.domain == NSCocoaErrorDomain && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(error.code))
                || (error.domain == NSPOSIXErrorDomain && error.code == 2) { return .missing }
            return .unreadable
        }
    }
}

enum MediaJournalError: LocalizedError {
    case protectedDataUnavailable, unreadable
    var errorDescription: String? {
        switch self {
        case .protectedDataUnavailable: "Unlock your iPhone to resume the download."
        case .unreadable: "The previous download couldn’t be restored. Cancel it before starting another."
        }
    }
}
