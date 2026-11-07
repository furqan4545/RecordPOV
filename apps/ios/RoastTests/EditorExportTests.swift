import AVFoundation
import CoreGraphics
import XCTest
@testable import Roast

final class EditorExportTests: XCTestCase {
    @MainActor func testReportedValidTrimAndNonzeroStartBothExportWithAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RoastReportedTrim-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let duration = 28.266666666666666
        let voice = directory.appendingPathComponent("voice.caf")
        let original = directory.appendingPathComponent("original.caf")
        let capture = directory.appendingPathComponent("capture.mov")
        try AudioSignalFixtures.writeTone(to: voice, frequency: 440, duration: duration)
        try AudioSignalFixtures.writeTone(to: original, frequency: 880, duration: duration)
        try await AudioSignalFixtures.writeVideo(to: capture, duration: duration)
        let draft = RecordingDraft(id: UUID(), videoURL: capture, microphoneURL: voice,
            sourceAudioURL: original, duration: duration, title: "Trim regression")
        for start in [0.0, 12.355] {
            var edits = TakeEdits(duration: duration)
            edits.voiceCleanupEnabled = false
            edits.trimStart = start
            edits.trimEnd = 18.522541308403014
            let result = try await EditorExporter.export(draft: draft, edits: edits)
            let actualDuration = try await AVURLAsset(url: result).load(.duration).seconds
            XCTAssertEqual(actualDuration, edits.trimEnd - start, accuracy: 0.04)
            let audio = try await AudioSignalFixtures.decode(result)
            XCTAssertEqual(audio.amplitude(at: 440, start: 0.2, duration: 0.2), 0.15, accuracy: 0.025)
            XCTAssertEqual(audio.amplitude(at: 880, start: 0.2, duration: 0.2), 0.1875, accuracy: 0.025)
        }
    }

    @MainActor func testMicrophoneMOVIsExtractedToAudioFileBeforeSpeech() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RoastCaptionContainer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let voice = directory.appendingPathComponent("voice.caf")
        let capture = directory.appendingPathComponent("capture.mov")
        try AudioSignalFixtures.writeTone(to: voice, frequency: 440, duration: 1)
        try await AudioSignalFixtures.writeVideo(to: capture, duration: 1, embeddedAudio: voice)
        let prepared = try await MicrophoneCaptioner.prepareMicrophoneAudio(from: capture)
        defer { try? FileManager.default.removeItem(at: prepared.url) }
        XCTAssertEqual(prepared.url.pathExtension, "m4a")
        let file = try AVAudioFile(forReading: prepared.url)
        XCTAssertGreaterThan(file.length, 0)
        let videoTracks = try await AVURLAsset(url: prepared.url).loadTracks(withMediaType: .video)
        XCTAssertTrue(videoTracks.isEmpty)
        let decoded = try await AudioSignalFixtures.decode(prepared.url)
        XCTAssertEqual(decoded.amplitude(at: 440, start: 0.1, duration: 0.3), 0.25, accuracy: 0.025)
        XCTAssertEqual(prepared.offset, 0, accuracy: 0.03)
    }

    @MainActor func testRealMP4UsesIsolatedGainsCutsAndBurnedCaptions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RoastEditorSignal-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let microphone = directory.appendingPathComponent("microphone.caf")
        let source = directory.appendingPathComponent("source.caf")
        let music = directory.appendingPathComponent("music.caf")
        let unwanted = directory.appendingPathComponent("embedded.caf")
        try AudioSignalFixtures.writeTone(to: microphone, frequency: 440, duration: 2)
        try AudioSignalFixtures.writeTone(to: source, frequency: 880, duration: 2)
        try AudioSignalFixtures.writeTone(to: music, frequency: 1760, duration: 0.5)
        try AudioSignalFixtures.writeTone(to: unwanted, frequency: 1320, duration: 2)
        let capture = directory.appendingPathComponent("capture.mov")
        try await AudioSignalFixtures.writeVideo(to: capture, duration: 2, embeddedAudio: unwanted)
        let draft = RecordingDraft(id: UUID(), videoURL: capture, microphoneURL: microphone,
            sourceAudioURL: source, duration: 2, title: "Synthetic signal")
        var edits = TakeEdits(duration: 2)
        edits.voiceCleanupEnabled = false
        edits.trimStart = 0.2
        edits.trimEnd = 1.8
        edits.cuts = [EditInterval(start: 0.6, end: 1)]
        edits.microphoneVolume = 0.4
        edits.sourceVolume = 1.2
        edits.musicURL = music
        edits.musicVolume = 0.2
        edits.captions = [TakeCaption(start: 0.25, end: 0.55, text: "My voice")]

        var preview: EditorComposition? = try await EditorExporter.composition(draft: draft, edits: edits)
        weak var retainedMusic: AVURLAsset?
        retainedMusic = preview?.retainedAssets.last
        let previewItem = preview!.playerItem()
        preview = nil
        XCTAssertNotNil(retainedMusic, "The player item must own source assets after the builder returns")
        XCTAssertNotNil(previewItem.videoComposition, "Preview uses the same caption renderer as export")
        defer { withExtendedLifetime(previewItem) {} }
        let output = try await EditorExporter.export(draft: draft, edits: edits)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1.2, accuracy: 0.06)
        let audio = try await AudioSignalFixtures.decode(output)
        for start in [0.08, 0.75] {
            XCTAssertEqual(audio.amplitude(at: 440, start: start, duration: 0.2), 0.10, accuracy: 0.025)
            XCTAssertEqual(audio.amplitude(at: 880, start: start, duration: 0.2), 0.30, accuracy: 0.035)
            XCTAssertEqual(audio.amplitude(at: 1760, start: start, duration: 0.2), 0.05, accuracy: 0.02)
            XCTAssertLessThan(audio.amplitude(at: 1320, start: start, duration: 0.2), 0.015,
                              "Audio embedded in videoURL must never leak into the explicit stem mix")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let captioned = try await generator.image(at: CMTime(seconds: 0.15, preferredTimescale: 600)).image
        let plain = try await generator.image(at: CMTime(seconds: 0.8, preferredTimescale: 600)).image
        XCTAssertGreaterThan(abs(brightness(captioned) - brightness(plain)), 0.015,
                             "Captions must change actual exported pixels, not only the editor UI")

        edits.microphoneVolume = 0
        edits.sourceVolume = 0
        edits.musicVolume = 1
        edits.captionsEnabled = false
        let musicOnlyURL = try await EditorExporter.export(draft: draft, edits: edits)
        let musicOnly = try await AudioSignalFixtures.decode(musicOnlyURL)
        XCTAssertLessThan(musicOnly.amplitude(at: 440, start: 0.7, duration: 0.2), 0.015)
        XCTAssertLessThan(musicOnly.amplitude(at: 880, start: 0.7, duration: 0.2), 0.015)
        XCTAssertEqual(musicOnly.amplitude(at: 1760, start: 0.7, duration: 0.2), 0.25, accuracy: 0.035)
    }

    @MainActor func testMissingMicrophoneNeverFallsBackToEmbeddedVideoAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RoastEditorSilent-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let embedded = directory.appendingPathComponent("embedded.caf")
        try AudioSignalFixtures.writeTone(to: embedded, frequency: 440, duration: 1)
        let capture = directory.appendingPathComponent("capture.mov")
        try await AudioSignalFixtures.writeVideo(to: capture, duration: 1, embeddedAudio: embedded)
        let draft = RecordingDraft(id: UUID(), videoURL: capture, microphoneURL: nil,
                                   sourceAudioURL: nil, duration: 1, title: "Silent")
        let output = try await EditorExporter.export(draft: draft, edits: TakeEdits(duration: 1))
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        XCTAssertTrue(tracks.isEmpty)
    }

    private func brightness(_ image: CGImage) -> Double {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Double(Int(bytes[0]) + Int(bytes[1]) + Int(bytes[2])) / (3 * 255)
    }
}
