import AVFoundation
import XCTest
@testable import Roast

final class VoiceCleanupTimingTests: XCTestCase {
    func testMicrophoneTrackOffsetStaysAsLeadingSilenceInCleanedPCM() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = try await microphoneMovie(in: folder, duration: 1.2,
            placements: [(start: 0.2, duration: 1.0)])
        let original = AVURLAsset(url: input)
        defer { withExtendedLifetime(original) {} }
        let originalTracks = try await original.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(originalTracks.first)
        let range = try await track.load(.timeRange)
        // MOV includes its leading empty edit in track.timeRange. Passthrough
        // output timestamps apply that edit; zero-sample edit markers precede it.
        let reader = try AVAssetReader(asset: original)
        let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(samples)
        XCTAssertTrue(reader.startReading())
        var firstStoredBuffer: CMSampleBuffer?
        while let buffer = samples.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(buffer) > 0 {
                firstStoredBuffer = buffer
                break
            }
        }
        let firstBuffer = try XCTUnwrap(firstStoredBuffer)
        XCTAssertEqual(CMSampleBufferGetOutputPresentationTimeStamp(firstBuffer).seconds, 0.2,
                       accuracy: 1.0 / 48_000)
        reader.cancelReading()
        XCTAssertEqual(range.end.seconds, 1.2, accuracy: 1.0 / 48_000)

        let output = try await VoiceCleanup.process(microphoneURL: input)
        defer { try? FileManager.default.removeItem(at: output) }
        let cleaned = try await AudioSignalFixtures.decode(output)
        XCTAssertEqual(Double(cleaned.samples.count) / cleaned.sampleRate, 1.2, accuracy: 1.0 / 48_000)
        XCTAssertLessThan(cleaned.rms(start: 0, duration: 0.15), 0.000_001,
                          "Cleanup must not move the voice forward into its host-clock gap.")
        XCTAssertGreaterThan(cleaned.rms(start: 0.3, duration: 0.7), 0.02)
        let firstSignal = try XCTUnwrap(cleaned.samples.firstIndex { abs($0) > 0.001 })
        XCTAssertEqual(Double(firstSignal) / cleaned.sampleRate, 0.2, accuracy: 0.025,
                       "Filtering may soften an edge but must preserve its original clock position.")
    }

    func testInternalAndTrailingMicrophoneGapsSurviveCleanupWithoutConcatenation() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = try await microphoneMovie(in: folder, duration: 1.4,
            placements: [(start: 0.2, duration: 0.4), (start: 0.9, duration: 0.4)])
        let baseline = try await AudioSignalFixtures.decode(input)
        XCTAssertLessThan(baseline.rms(start: 0.67, duration: 0.16), 0.000_001)
        XCTAssertGreaterThan(baseline.rms(start: 1.0, duration: 0.2), 0.1)

        let output = try await VoiceCleanup.process(microphoneURL: input)
        defer { try? FileManager.default.removeItem(at: output) }
        let cleaned = try await AudioSignalFixtures.decode(output)
        XCTAssertEqual(Double(cleaned.samples.count) / cleaned.sampleRate, 1.4, accuracy: 1.0 / 48_000)
        XCTAssertLessThan(cleaned.rms(start: 0, duration: 0.15), 0.000_001)
        XCTAssertGreaterThan(cleaned.rms(start: 0.3, duration: 0.2), 0.02)
        XCTAssertLessThan(cleaned.rms(start: 0.67, duration: 0.16), 0.000_1,
                          "A decoder must insert a missing PCM interval, rather than concatenate buffers.")
        XCTAssertGreaterThan(cleaned.rms(start: 1.0, duration: 0.2), 0.02)
        XCTAssertLessThan(cleaned.rms(start: 1.36, duration: 0.035), 0.000_1)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceCleanupTiming-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// PCM in a MOV edit list makes the offset explicit and avoids AAC priming
    /// assumptions. The synthetic video fixes the asset's complete clock range.
    private func microphoneMovie(in folder: URL, duration: Double,
                                 placements: [(start: Double, duration: Double)]) async throws -> URL {
        let toneURL = folder.appendingPathComponent("tone.caf")
        let videoURL = folder.appendingPathComponent("video.mov")
        let output = folder.appendingPathComponent("offset-microphone.mov")
        try AudioSignalFixtures.writeTone(to: toneURL, frequency: 660, duration: 1)
        try await AudioSignalFixtures.writeVideo(to: videoURL, duration: duration)
        let videoAsset = AVURLAsset(url: videoURL)
        let toneAsset = AVURLAsset(url: toneURL)
        defer { withExtendedLifetime((videoAsset, toneAsset)) {} }
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let toneTracks = try await toneAsset.loadTracks(withMediaType: .audio)
        let video = try XCTUnwrap(videoTracks.first)
        let tone = try XCTUnwrap(toneTracks.first)
        let composition = AVMutableComposition()
        let visual = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid))
        try visual.insertTimeRange(CMTimeRange(start: .zero,
            duration: CMTime(seconds: duration, preferredTimescale: 48_000)), of: video, at: .zero)
        let audio = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid))
        for placement in placements {
            try audio.insertTimeRange(CMTimeRange(start: .zero,
                duration: CMTime(seconds: placement.duration, preferredTimescale: 48_000)),
                of: tone, at: CMTime(seconds: placement.start, preferredTimescale: 48_000))
        }
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition,
                                                        presetName: AVAssetExportPresetPassthrough))
        try await exporter.export(to: output, as: .mov)
        return output
    }
}
