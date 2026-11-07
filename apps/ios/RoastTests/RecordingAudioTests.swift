import AVFoundation
import CoreImage
import XCTest
@testable import Roast

final class RecordingAudioTests: XCTestCase {
    func testTimelineKeepsPauseSeekAndSourceChangesSeparate() {
        let first = URL(fileURLWithPath: "/first.mov")
        let second = URL(fileURLWithPath: "/second.mov")
        var timeline = StudioSourceAudioTimeline()
        timeline.capture(url: first, sourceTime: 0, outputTime: 0, playing: true)
        timeline.capture(url: first, sourceTime: 1, outputTime: 1, playing: true)
        timeline.discontinuity()
        timeline.capture(url: first, sourceTime: 1, outputTime: 2, playing: true)
        timeline.capture(url: first, sourceTime: 1.5, outputTime: 2.5, playing: true)
        timeline.discontinuity()
        timeline.capture(url: first, sourceTime: 4, outputTime: 2.5, playing: true)
        timeline.capture(url: first, sourceTime: 4.5, outputTime: 3, playing: true)
        timeline.capture(url: second, sourceTime: 10, outputTime: 3, playing: true)
        timeline.capture(url: second, sourceTime: 10.5, outputTime: 3.5, playing: true)
        XCTAssertEqual(timeline.slices, [
            .init(url: first, sourceStart: 0, outputStart: 0, duration: 1),
            .init(url: first, sourceStart: 1, outputStart: 2, duration: 0.5),
            .init(url: first, sourceStart: 4, outputStart: 2.5, duration: 0.5),
            .init(url: second, sourceStart: 10, outputStart: 3, duration: 0.5),
        ])
    }

    func testSourceStemContainsSeekedTonesAndSilenceDuringPauses() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let changing = folder.appendingPathComponent("changing.caf")
        try writeChangingTone(to: changing)
        let other = folder.appendingPathComponent("other.caf")
        try AudioSignalFixtures.writeTone(to: other, frequency: 660, duration: 1)
        let stem = try await RecordingAudioComposer.exportSourceAudio([
            .init(url: changing, sourceStart: 0, outputStart: 0, duration: 0.5),
            .init(url: changing, sourceStart: 1.2, outputStart: 1, duration: 0.5),
            .init(url: other, sourceStart: 0, outputStart: 2, duration: 0.4),
        ], duration: 3, to: folder.appendingPathComponent("source.m4a"))
        let decoded = try await AudioSignalFixtures.decode(XCTUnwrap(stem))
        XCTAssertGreaterThan(decoded.amplitude(at: 330, start: 0.1, duration: 0.3), 0.18)
        XCTAssertGreaterThan(decoded.amplitude(at: 990, start: 1.1, duration: 0.3), 0.18)
        XCTAssertGreaterThan(decoded.amplitude(at: 660, start: 2.1, duration: 0.2), 0.18)
        XCTAssertLessThan(decoded.rms(start: 0.65, duration: 0.2), 0.005)
        XCTAssertLessThan(decoded.rms(start: 1.65, duration: 0.2), 0.005)
        XCTAssertLessThan(decoded.rms(start: 2.65, duration: 0.2), 0.005)
        let assetDuration = try await AVURLAsset(url: XCTUnwrap(stem)).load(.duration).seconds
        XCTAssertEqual(assetDuration, 3, accuracy: 0.04)
    }

    func testDraftStemsAndActualMixContainIndependentSignalsAndGains() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let microphone = folder.appendingPathComponent("mic.caf")
        let source = folder.appendingPathComponent("original.caf")
        try AudioSignalFixtures.writeTone(to: microphone, frequency: 440, amplitude: 0.2, duration: 2)
        try AudioSignalFixtures.writeTone(to: source, frequency: 880, amplitude: 0.2, duration: 2)
        let capture = folder.appendingPathComponent("capture.mov")
        try await AudioSignalFixtures.writeVideo(to: capture, duration: 2, embeddedAudio: microphone)
        let draft = try await RecordingAudioComposer.makeDraft(captureURL: capture, duration: 2,
            title: "Synthetic signal", sourceAudio: [.init(url: source, sourceStart: 0, outputStart: 0, duration: 2)],
            microphoneRequired: true, directory: folder.appendingPathComponent("draft"))
        let mic = try await AudioSignalFixtures.decode(XCTUnwrap(draft.microphoneURL))
        let original = try await AudioSignalFixtures.decode(XCTUnwrap(draft.sourceAudioURL))
        XCTAssertGreaterThan(mic.amplitude(at: 440, start: 0.2, duration: 1), 0.17)
        XCTAssertLessThan(mic.amplitude(at: 880, start: 0.2, duration: 1), 0.01)
        XCTAssertGreaterThan(original.amplitude(at: 880, start: 0.2, duration: 1), 0.17)
        XCTAssertLessThan(original.amplitude(at: 440, start: 0.2, duration: 1), 0.01)
        let mixed = try await RecordingAudioComposer.exportMixed(draft, to: folder.appendingPathComponent("mix.mp4"),
                                                                  microphoneGain: 0.5, sourceGain: 0.75)
        let signal = try await AudioSignalFixtures.decode(mixed)
        XCTAssertEqual(signal.amplitude(at: 440, start: 0.2, duration: 1), 0.1, accuracy: 0.025)
        XCTAssertEqual(signal.amplitude(at: 880, start: 0.2, duration: 1), 0.15, accuracy: 0.025)
        let changed = try await RecordingAudioComposer.exportMixed(draft, to: folder.appendingPathComponent("changed.mp4"),
                                                                    microphoneGain: 0, sourceGain: 0.25)
        let changedSignal = try await AudioSignalFixtures.decode(changed)
        XCTAssertLessThan(changedSignal.amplitude(at: 440, start: 0.2, duration: 1), 0.005)
        XCTAssertEqual(changedSignal.amplitude(at: 880, start: 0.2, duration: 1), 0.05, accuracy: 0.015)
    }

    func testMissingMicrophoneFailsButSilentOriginalIsValid() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = folder.appendingPathComponent("silent.mov")
        try await AudioSignalFixtures.writeVideo(to: capture, duration: 0.4)
        do {
            _ = try await RecordingAudioComposer.makeDraft(captureURL: capture, duration: 0.4, title: "Missing mic",
                sourceAudio: [], microphoneRequired: true, directory: folder.appendingPathComponent("required"))
            XCTFail("Missing requested microphone audio must be surfaced.")
        } catch { XCTAssertTrue(error is RecordingDraftError) }
        let draft = try await RecordingAudioComposer.makeDraft(captureURL: capture, duration: 0.4, title: "Silent source",
            sourceAudio: [.init(url: capture, sourceStart: 0, outputStart: 0, duration: 0.4)],
            microphoneRequired: false, directory: folder.appendingPathComponent("optional"))
        XCTAssertNil(draft.sourceAudioURL)
    }

    func testActualRecorderCapturesInjectedMicrophoneSignalWithItsTimestamp() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tone = folder.appendingPathComponent("microphone.caf")
        try AudioSignalFixtures.writeTone(to: tone, frequency: 440, amplitude: 0.2, duration: 0.6)
        let queue = DispatchQueue(label: "roast.synthetic.microphone")
        let recorder = try queue.sync { try StudioAssetRecorder(url: folder.appendingPathComponent("recorded.mov"),
                                                               microphone: true, callbackQueue: queue) }
        let context = CIContext()
        let frame = CIImage(color: .red).cropped(to: StudioFramePipeline.canvas)
        try queue.sync {
            try recorder.start()
            recorder.appendVideo(frame, at: 0, context: context, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        let asset = AVURLAsset(url: tone)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        while let sample = output.copyNextSampleBuffer() {
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                presentationTimeStamp: recorder.hostStart + CMTime(seconds: 0.2, preferredTimescale: 48_000)
                    + CMSampleBufferGetPresentationTimeStamp(sample), decodeTimeStamp: .invalid)
            var shifted: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &shifted), noErr)
            let buffer = try XCTUnwrap(shifted)
            XCTAssertTrue(queue.sync { recorder.appendAudio(buffer) })
        }
        queue.sync { recorder.appendVideo(frame, at: 0.9, context: context, colorSpace: CGColorSpaceCreateDeviceRGB()) }
        let result: StudioCaptureResult = try await withCheckedThrowingContinuation { continuation in
            queue.async { recorder.finish(at: 1) { continuation.resume(with: $0) } }
        }
        let decoded = try await AudioSignalFixtures.decode(result.url)
        XCTAssertLessThan(decoded.rms(start: 0, duration: 0.15), 0.005)
        XCTAssertGreaterThan(decoded.amplitude(at: 440, start: 0.3, duration: 0.3), 0.17)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeChangingTone(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        buffer.frameLength = 96_000
        for index in 0..<96_000 {
            let frequency = index < 48_000 ? 330.0 : 990.0
            buffer.floatChannelData![0][index] = 0.25 * Float(sin(2 * .pi * frequency * Double(index) / 48_000))
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }
}
