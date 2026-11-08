import CoreTransferable
import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

enum PiPStyle: String, CaseIterable, Codable, Identifiable {
    case rounded, circle, square, cutout

    var id: String { rawValue }
    var label: String {
        switch self {
        case .rounded: "Rounded"
        case .circle: "Circle"
        case .square: "Square"
        case .cutout: "Cutout"
        }
    }
    var symbol: String {
        switch self {
        case .rounded: "rectangle.portrait"
        case .circle: "circle"
        case .square: "square"
        case .cutout: "person.crop.rectangle"
        }
    }
}

enum StudioLayout: String, CaseIterable, Codable, Identifiable {
    case pip, split, cameraMain
    var id: String { rawValue }
    var label: String {
        switch self { case .pip: "Camera"; case .split: "Split"; case .cameraMain: "You on Stage" }
    }
    var shortLabel: String {
        switch self { case .pip: "Camera"; case .split: "Split"; case .cameraMain: "Stage" }
    }
    var symbol: String {
        switch self { case .pip: "rectangle.on.rectangle"; case .split: "rectangle.split.1x2"; case .cameraMain: "person.crop.rectangle" }
    }
}

struct SourceOverlayTransform: Equatable, Codable {
    var x: Double = 0.76
    var y: Double = 0.23
    var scale: Double = 1
    var rotation: Double = 0
}

struct PiPTransform: Equatable, Codable {
    /// The owner's chosen starting size: about 47% of the video's width.
    static let defaultScale = 1.4
    var x: Double = 0.74
    var y: Double = 0.75
    var scale: Double = PiPTransform.defaultScale
    var rotation: Double = 0
    var style: PiPStyle = .cutout
    var framingScale: Double = 1
    var isFullScreen: Bool = false
    var layout: StudioLayout = .pip
    var splitRatio: Double = 0.7
    var sourceOverlay = SourceOverlayTransform()
    static var defaultTransform: Self { Self() }
}

extension PiPTransform {
    private enum CodingKeys: String, CodingKey { case x, y, scale, rotation, style, framingScale, isFullScreen, layout, splitRatio, sourceOverlay }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        x = try values.decodeIfPresent(Double.self, forKey: .x) ?? 0.74
        y = try values.decodeIfPresent(Double.self, forKey: .y) ?? 0.75
        scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? PiPTransform.defaultScale
        rotation = try values.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        style = try values.decodeIfPresent(PiPStyle.self, forKey: .style) ?? .cutout
        framingScale = try values.decodeIfPresent(Double.self, forKey: .framingScale) ?? 1
        isFullScreen = try values.decodeIfPresent(Bool.self, forKey: .isFullScreen) ?? false
        layout = try values.decodeIfPresent(StudioLayout.self, forKey: .layout) ?? .pip
        splitRatio = try values.decodeIfPresent(Double.self, forKey: .splitRatio) ?? 0.7
        sourceOverlay = try values.decodeIfPresent(SourceOverlayTransform.self, forKey: .sourceOverlay) ?? SourceOverlayTransform()
    }
}

struct StudioLaunch: Identifiable {
    enum Source {
        case video(URL, String)
        case image(UIImage, String)
    }
    let id = UUID()
    let source: Source
}

struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RoastImports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: target)
            return Self(url: target)
        }
    }
}

struct SavedTake: Identifiable, Codable, Equatable {
    let id: UUID
    let fileName: String
    let title: String
    let createdAt: Date
    let duration: TimeInterval
    let kind: String
    var photoAssetIdentifier: String? = nil
    /// The editing draft this video was saved from, kept so Re-edit can reopen it.
    var draftID: UUID? = nil

    var fileURL: URL { TakeLibrary.directory.appendingPathComponent(fileName) }
    var formattedDuration: String { duration.minuteSecond }
    var displayKind: String {
        switch kind {
        case "Roast": "Video"
        default: kind
        }
    }
}

extension TimeInterval {
    var minuteSecond: String {
        guard isFinite else { return "0:00" }
        let seconds = max(0, Int(self))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

@MainActor @Observable
final class TakeLibrary {
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Takes", isDirectory: true)
    }
    private let storageDirectory: URL
    private let photoSaver: any PhotoLibrarySaving
    private let draftStore: DraftStore
    private var indexURL: URL { storageDirectory.appendingPathComponent("index.json") }
    private(set) var takes: [SavedTake] = []
    var errorMessage: String?
    private var photoSaveTasks: [UUID: Task<Void, Error>] = [:]
    private var photoSaveErrors: [UUID: String] = [:]

    init(directory: URL = TakeLibrary.directory, photoSaver: (any PhotoLibrarySaving)? = nil,
         draftStore: DraftStore = DraftStore()) {
        storageDirectory = directory
        self.photoSaver = photoSaver ?? PhotoLibrarySaver()
        self.draftStore = draftStore
        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let stored = try JSONDecoder().decode([SavedTake].self, from: Data(contentsOf: indexURL))
                takes = stored.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
                for index in takes.indices where takes[index].photoAssetIdentifier == nil {
                    if let receipt = try? Data(contentsOf: photoReceiptURL(for: takes[index].id)),
                       let identifier = try? JSONDecoder().decode(String.self, from: receipt), !identifier.isEmpty {
                        takes[index].photoAssetIdentifier = identifier
                    }
                }
            }
        } catch { errorMessage = "Your saved videos couldn’t be loaded. \(error.localizedDescription)" }
    }

    @discardableResult
    func add(url: URL, title: String, duration: TimeInterval, kind: String = "Video", draftID: UUID? = nil) throws -> SavedTake {
        let target: URL
        if url.deletingLastPathComponent().standardizedFileURL == storageDirectory.standardizedFileURL {
            target = url
        } else {
            target = storageDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
            try FileManager.default.copyItem(at: url, to: target)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let take = SavedTake(id: UUID(), fileName: target.lastPathComponent,
                             title: title.isEmpty ? "Untitled video" : title,
                             createdAt: .now, duration: duration, kind: kind, draftID: draftID)
        takes.insert(take, at: 0)
        do { try persist() }
        catch { takes.removeAll { $0.id == take.id }; throw error }
        return take
    }

    func delete(_ take: SavedTake) throws {
        guard !isSavingToPhotos(take) else { throw PhotoSaveError.saveInProgress }
        try FileManager.default.removeItem(at: fileURL(for: take))
        takes.removeAll { $0.id == take.id }
        try persist()
        try? FileManager.default.removeItem(at: photoReceiptURL(for: take.id))
        photoSaveErrors[take.id] = nil
        // Its draft goes too, unless another saved video still comes from it.
        if let draftID = take.draftID, !takes.contains(where: { $0.draftID == draftID }) {
            try? draftStore.delete(id: draftID)
        }
    }

    func isSavedToPhotos(_ take: SavedTake) -> Bool {
        takes.first { $0.id == take.id }?.photoAssetIdentifier != nil
    }

    func isSavingToPhotos(_ take: SavedTake) -> Bool {
        photoSaveTasks[take.id] != nil
    }

    func photoSaveError(for take: SavedTake) -> String? {
        photoSaveErrors[take.id]
    }

    /// Coalesces auto-save and retry calls, including callers holding an old take snapshot.
    func saveToPhotos(_ take: SavedTake) async throws {
        if isSavedToPhotos(take) { return }
        if let task = photoSaveTasks[take.id] { return try await task.value }
        guard let current = takes.first(where: { $0.id == take.id }) else {
            throw PhotoSaveError.videoUnavailable
        }

        photoSaveErrors[take.id] = nil
        let task = Task { @MainActor in
            do {
                let identifier = try await self.photoSaver.saveVideo(at: self.fileURL(for: current))
                try self.recordPhotoSave(identifier: identifier, for: current.id)
            } catch {
                self.photoSaveErrors[current.id] = error.localizedDescription
                throw error
            }
        }
        photoSaveTasks[take.id] = task
        defer { photoSaveTasks[take.id] = nil }
        try await task.value
    }

    private func fileURL(for take: SavedTake) -> URL {
        storageDirectory.appendingPathComponent(take.fileName)
    }

    private func photoReceiptURL(for id: UUID) -> URL {
        storageDirectory.appendingPathComponent(".photos", isDirectory: true)
            .appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func recordPhotoSave(identifier: String, for id: UUID) throws {
        guard let index = takes.firstIndex(where: { $0.id == id }) else { return }
        // Keep this marker even if storage fails: retrying must not create another asset.
        takes[index].photoAssetIdentifier = identifier
        let receiptURL = photoReceiptURL(for: id)
        let receiptSaved: Bool
        do {
            try FileManager.default.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(identifier).write(to: receiptURL, options: .atomic)
            receiptSaved = true
        } catch { receiptSaved = false }

        do { try persist() }
        catch {
            // A separate receipt preserves idempotency if only index.json couldn't be updated.
            if !receiptSaved { throw PhotoSaveError.statusCouldNotBeStored }
        }
    }

    private func persist() throws {
        try JSONEncoder().encode(takes).write(to: indexURL, options: .atomic)
    }
}

