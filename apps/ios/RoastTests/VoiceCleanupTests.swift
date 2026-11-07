import AVFoundation
import XCTest
@testable import Roast

final class VoiceCleanupTests: XCTestCase {
    func testGentleHissReductionKeepsImmediateSpeechAndOriginalBytes() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let microphone = folder.appendingPathComponent("voice.caf")
        var noise = TestNoise()
        try write(microphone, duration: 3) { time in
            let voice = time < 1 || time >= 2 ? 0.13 * sin(2 * .pi * 440 * time) : 0
            return Float(voice) + noise.next() * 0.025
        }
        let originalBytes = try Data(contentsOf: microphone)
        let raw = try await AudioSignalFixtures.decode(microphone)
        let cleanup = VoiceCleanupProcessor(cacheDirectory: folder.appendingPathComponent("cache"))
        let output = try await cleanup.process(microphoneURL: microphone)
        let cleaned = try await AudioSignalFixtures.decode(output)

        XCTAssertEqual(try Data(contentsOf: microphone), originalBytes)
        XCTAssertEqual(cleaned.samples.count, raw.samples.count)
        XCTAssertLessThan(cleaned.rms(start: 1.2, duration: 0.6), raw.rms(start: 1.2, duration: 0.6) * 0.85)
        for start in [0.05, 2.1] {
            XCTAssertGreaterThan(cleaned.amplitude(at: 440, start: start, duration: 0.5),
                                 raw.amplitude(at: 440, start: start, duration: 0.5) * 0.94,
                                 "Speech starts immediately; it must not be learned as an opening noise sample")
        }
    }

    func testSustainedVowelLikeToneIsNotLearnedAsNoise() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let microphone = folder.appendingPathComponent("vowel.caf")
        try AudioSignalFixtures.writeTone(to: microphone, frequency: 220, amplitude: 0.2, duration: 2)
        let cleanup = VoiceCleanupProcessor(cacheDirectory: folder.appendingPathComponent("cache"))
        let cleaned = try await AudioSignalFixtures.decode(cleanup.process(microphoneURL: microphone))
        XCTAssertGreaterThan(cleaned.amplitude(at: 220, start: 0.2, duration: 1.5), 0.188)
        XCTAssertLessThan(cleaned.amplitude(at: 220, start: 0.2, duration: 1.5), 0.205)
    }

    func testRumbleIsReducedWhileVoiceBandStaysAtItsChosenLevel() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let microphone = folder.appendingPathComponent("rumble.caf")
        try write(microphone, duration: 3) { time in
            Float(0.1 * sin(2 * .pi * 30 * time) + 0.1 * sin(2 * .pi * 440 * time))
        }
        let cleanup = VoiceCleanupProcessor(cacheDirectory: folder.appendingPathComponent("cache"))
        let cleaned = try await AudioSignalFixtures.decode(cleanup.process(microphoneURL: microphone))
        XCTAssertLessThan(cleaned.amplitude(at: 30, start: 0.3, duration: 2), 0.025)
        XCTAssertGreaterThan(cleaned.amplitude(at: 440, start: 0.3, duration: 2), 0.095)
    }

    func testSparseTransientsAndDigitalSilenceAreNotGatedOrShifted() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let microphone = folder.appendingPathComponent("transient.caf")
        var random = TestNoise()
        try write(microphone, duration: 2) { time in
            time >= 0.8 && time < 0.86 ? random.next() * 0.2 : 0
        }
        let raw = try await AudioSignalFixtures.decode(microphone)
        let cleanup = VoiceCleanupProcessor(cacheDirectory: folder.appendingPathComponent("cache"))
        let cleaned = try await AudioSignalFixtures.decode(cleanup.process(microphoneURL: microphone))
        XCTAssertEqual(cleaned.samples.count, raw.samples.count)
        XCTAssertLessThan(cleaned.rms(start: 0, duration: 0.7), 0.00001)
        XCTAssertLessThan(cleaned.rms(start: 1, duration: 0.8), 0.00001)
        XCTAssertGreaterThan(cleaned.rms(start: 0.8, duration: 0.06), raw.rms(start: 0.8, duration: 0.06) * 0.94)
        let firstSound = try XCTUnwrap(cleaned.samples.firstIndex { abs($0) > 0.001 })
        XCTAssertEqual(Double(firstSound) / cleaned.sampleRate, 0.8, accuracy: 0.002)
    }

    func testCacheTracksIdentityAndChangedInputWithoutChangingRawFile() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let microphone = folder.appendingPathComponent("cache-input.caf")
        let processor = VoiceCleanupProcessor(cacheDirectory: folder.appendingPathComponent("cache"))
        try AudioSignalFixtures.writeTone(to: microphone, frequency: 440, duration: 1)
        let first = try await processor.process(microphoneURL: microphone)
        let repeated = try await processor.process(microphoneURL: microphone)
        XCTAssertEqual(first, repeated)
        try AudioSignalFixtures.writeTone(to: microphone, frequency: 660, duration: 1.2)
        let changed = try await processor.process(microphoneURL: microphone)
        XCTAssertNotEqual(changed, first)
        let decoded = try await AudioSignalFixtures.decode(changed)
        XCTAssertGreaterThan(decoded.amplitude(at: 660, start: 0.1, duration: 0.8), 0.23)
    }

    func testCancellationRemovesPartialFilesAndKeepsRawMicrophone() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let microphone = folder.appendingPathComponent("long.caf")
        try AudioSignalFixtures.writeTone(to: microphone, frequency: 440, duration: 120)
        let cache = folder.appendingPathComponent("cache")
        let processor = VoiceCleanupProcessor(cacheDirectory: cache)
        let operation = Task { try await processor.process(microphoneURL: microphone) }
        for _ in 0..<200 {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
            if entries.contains(where: { $0.hasSuffix(".input.caf") }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled cleanup should not be committed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        XCTAssertTrue(remaining.isEmpty, "Partial cleanup files must be removed on cancellation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: microphone.path))
    }

    @MainActor func testEnabledExportCleansOnlyMicrophoneAndOffUsesOriginalStem() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let microphone = folder.appendingPathComponent("microphone.caf")
        let source = folder.appendingPathComponent("source.caf")
        let music = folder.appendingPathComponent("music.caf")
        let video = folder.appendingPathComponent("capture.mov")
        var random = TestNoise()
        try write(microphone, duration: 3) { time in
            Float(time < 1 || time >= 2 ? 0.12 * sin(2 * .pi * 440 * time) : 0) + random.next() * 0.025
        }
        try AudioSignalFixtures.writeTone(to: source, frequency: 880, amplitude: 0.2, duration: 3)
        try AudioSignalFixtures.writeTone(to: music, frequency: 1320, amplitude: 0.2, duration: 1)
        try await AudioSignalFixtures.writeVideo(to: video, duration: 3)
        let sourceBytes = try Data(contentsOf: source), musicBytes = try Data(contentsOf: music)
        let draft = RecordingDraft(id: UUID(), videoURL: video, microphoneURL: microphone,
            sourceAudioURL: source, duration: 3, title: "Synthetic voice cleanup")
        var edits = TakeEdits(duration: 3)
        edits.sourceVolume = 0.5
        edits.microphoneVolume = 1
        edits.musicURL = music
        edits.musicVolume = 0.25
        edits.voiceCleanupEnabled = true
        let cleanComposition = try await EditorExporter.composition(draft: draft, edits: edits)
        XCTAssertTrue(cleanComposition.retainedAssets.contains { $0.url != microphone && $0.url.pathExtension == "caf" })
        let cleanedURL = try await EditorExporter.export(draft: draft, edits: edits)
        let cleaned = try await AudioSignalFixtures.decode(cleanedURL)
        edits.voiceCleanupEnabled = false
        let rawComposition = try await EditorExporter.composition(draft: draft, edits: edits)
        XCTAssertTrue(rawComposition.retainedAssets.contains { $0.url == microphone })
        let rawURL = try await EditorExporter.export(draft: draft, edits: edits)
        let raw = try await AudioSignalFixtures.decode(rawURL)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: music), musicBytes)
        XCTAssertEqual(cleaned.samples.count, raw.samples.count)
        for frequency in [880.0, 1320.0] {
            XCTAssertEqual(cleaned.amplitude(at: frequency, start: 1.1, duration: 0.8),
                           raw.amplitude(at: frequency, start: 1.1, duration: 0.8), accuracy: 0.012)
        }
        XCTAssertGreaterThan(cleaned.amplitude(at: 440, start: 0.1, duration: 0.7), 0.11)
        let cleanResidual = residual(cleaned, start: 1.1, duration: 0.8)
        let rawResidual = residual(raw, start: 1.1, duration: 0.8)
        XCTAssertLessThan(cleanResidual, rawResidual * 0.9)
    }

    private func residual(_ audio: DecodedAudio, start: Double, duration: Double) -> Double {
        let rms = audio.rms(start: start, duration: duration)
        let tones = [880.0, 1320.0].reduce(0) {
            let amplitude = audio.amplitude(at: $1, start: start, duration: duration)
            return $0 + amplitude * amplitude / 2
        }
        return sqrt(max(0, rms * rms - tones))
    }

    private func temporaryDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RoastVoiceCleanupTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ url: URL, duration: Double, sample: (Double) -> Float) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let count = AVAudioFrameCount(duration * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for index in 0..<Int(count) { buffer.floatChannelData![0][index] = sample(Double(index) / 48_000) }
        try file.write(from: buffer)
    }
}

private struct TestNoise {
    private var state: UInt64 = 0xD1CE_BEEF_1234_5678
    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return Float(Int32(truncatingIfNeeded: state >> 32)) / 2_147_483_648
    }
}
