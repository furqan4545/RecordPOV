import Foundation
import Photos

@MainActor
protocol PhotoLibrarySaving {
    /// Returns the identifier only after Photos has committed the new video.
    func saveVideo(at fileURL: URL) async throws -> String
}

/// The small Photos boundary is injectable so tests never alter someone's library.
@MainActor
protocol PhotoLibraryWriting {
    var authorizationStatus: PHAuthorizationStatus { get }
    func requestAuthorization() async -> PHAuthorizationStatus
    func createVideo(at fileURL: URL) async throws -> String?
}

enum PhotoSaveError: LocalizedError, Equatable {
    case permissionDenied
    case permissionRestricted
    case videoUnavailable
    case creationFailed
    case statusCouldNotBeStored
    case saveInProgress

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Allow Photos access in Settings to save automatically. Your video is safe in My videos."
        case .permissionRestricted:
            "Photos access is restricted on this device. Your video is safe in My videos."
        case .videoUnavailable:
            "This video couldn’t be opened. Your other videos are still in My videos."
        case .creationFailed:
            "The video couldn’t be saved to Photos. Your video is safe in My videos. Try again."
        case .statusCouldNotBeStored:
            "Your video is in Photos, but its saved status couldn’t be stored in the app."
        case .saveInProgress:
            "This video is still saving to Photos. Try deleting it in a moment."
        }
    }
}

@MainActor
struct PhotoLibrarySaver: PhotoLibrarySaving {
    private let writer: any PhotoLibraryWriting

    init(writer: (any PhotoLibraryWriting)? = nil) {
        self.writer = writer ?? SystemPhotoLibraryWriter()
    }

    func saveVideo(at fileURL: URL) async throws -> String {
        guard fileURL.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw PhotoSaveError.videoUnavailable
        }

        var status = writer.authorizationStatus
        if status == .notDetermined { status = await writer.requestAuthorization() }
        switch status {
        case .authorized, .limited: break
        case .restricted: throw PhotoSaveError.permissionRestricted
        default: throw PhotoSaveError.permissionDenied
        }

        do {
            guard let identifier = try await writer.createVideo(at: fileURL), !identifier.isEmpty else {
                throw PhotoSaveError.creationFailed
            }
            return identifier
        } catch {
            throw PhotoSaveError.creationFailed
        }
    }
}

@MainActor
private struct SystemPhotoLibraryWriter: PhotoLibraryWriting {
    var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    func createVideo(at fileURL: URL) async throws -> String? {
        let creation = AssetCreationResult()
        return try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                // Photos can return nil without failing the surrounding transaction.
                guard let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL) else {
                    return
                }
                creation.identifier = request.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, error in
                if success {
                    continuation.resume(returning: creation.identifier)
                } else {
                    continuation.resume(throwing: error ?? PhotoSaveError.creationFailed)
                }
            }
        }
    }
}

/// Photos runs the change block before its completion handler on its own queues.
/// Locking also keeps the identifier transfer explicit under strict concurrency.
private final class AssetCreationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedIdentifier: String?

    var identifier: String? {
        get { lock.withLock { storedIdentifier } }
        set { lock.withLock { storedIdentifier = newValue } }
    }
}
