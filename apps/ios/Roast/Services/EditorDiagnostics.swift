#if DEBUG
import AVFoundation
import Foundation

/// Opt-in synthetic file test. It never configures an audio session, opens a
/// capture device, asks for permissions, or touches the app/Photos take library.
@MainActor
enum EditorDiagnostics {
    private static var hasRun = false

    static func run() async {
        guard !hasRun else { return }
        hasRun = true
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EditorTest", isDirectory: true)
        let output = folder.appendingPathComponent("mixed.mp4")
        let reportURL = folder.appendingPathComponent("EditorDiagnostic.json")
        let started = ProcessInfo.processInfo.systemUptime
        var report: [String: Any] = [
            "runIdentifier": ProcessInfo.processInfo.environment["ROAST_DIAGNOSTIC_RUN_ID"] ?? UUID().uuidString,
            "timestamp": ISO8601DateFormatter().string(from: .now),
            "phase": "starting", "passed": false,
            "syntheticInputsOnly": true, "cameraEnabled": false, "microphoneEnabled": false,
            "photosEnabled": false, "speechEnabled": false, "audioSessionActivated": false,
            "expectedDuration": 2.25,
            "expectedAmplitudes": ["440": 0.10, "880": 0.15, "1320": 0.05],
            "outputFileName": "mixed.mp4"
        ]
        func writeReport() {
            report["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - started
            guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? data.write(to: reportURL, options: .atomic)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: output)
            writeReport()
            report["phase"] = "validatingInputs"
            writeReport()
            let capture = folder.appendingPathComponent("capture.mov")
            let source = folder.appendingPathComponent("source.m4a")
            let music = folder.appendingPathComponent("music.wav")
            var inputSizes: [String: Int64] = [:]
            for url in [capture, source, music] {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
                    throw ProbeFailure("Missing synthetic input: \(url.lastPathComponent)")
                }
                inputSizes[url.lastPathComponent] = size.int64Value
            }
            report["inputBytes"] = inputSizes
            let draft = RecordingDraft(id: UUID(), videoURL: capture, microphoneURL: capture,
                                      sourceAudioURL: source, duration: 3, title: "Synthetic editor diagnostic")
            var edits = TakeEdits(duration: 3)
            edits.voiceCleanupEnabled = false
            edits.trimStart = 0.25
            edits.trimEnd = 2.75
            edits.cuts = [EditInterval(start: 1, end: 1.25)]
            edits.microphoneVolume = 0.5
            edits.sourceVolume = 0.75
            edits.musicURL = music
            edits.musicVolume = 0.25
            edits.captionsEnabled = false
            report["phase"] = "buildingComposition"
            writeReport()
            let composed = try await EditorExporter.composition(draft: draft, edits: edits)
            let inputAudioTracks = try await composed.asset.loadTracks(withMediaType: .audio).count
            report["compositionAudioTrackCount"] = inputAudioTracks
            report["compositionDuration"] = composed.timeline.duration
            report["retainedSourceAssetCount"] = composed.retainedAssets.count
            report["phase"] = "exporting"
            writeReport()
            let exported = try await EditorExporter.export(draft: draft, edits: edits)
            try FileManager.default.moveItem(at: exported, to: output)
            report["outputURL"] = output.absoluteString
            report["phase"] = "inspectingExport"
            writeReport()
            let asset = AVURLAsset(url: output)
            defer { withExtendedLifetime(asset) {} }
            let duration = try await asset.load(.duration).seconds
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            report["duration"] = duration
            report["audioTrackCount"] = audioTracks.count
            report["videoTrackCount"] = videoTracks.count
            report["outputBytes"] = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value
            let decoded = try await Task.detached(priority: .userInitiated) { try await decode(output) }.value
            let windows: [[String: Any]] = [0.15, 1.25].map { start in
                let samples = decoded.window(start: start, duration: 0.8)
                let amplitudes = Dictionary(uniqueKeysWithValues: [440, 880, 1320].map {
                    (String($0), amplitude(samples, frequency: Double($0)))
                })
                let rms = sqrt(samples.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, samples.count)))
                let tonalPower = amplitudes.values.reduce(0) { $0 + $1 * $1 / 2 }
                return ["start": start, "duration": 0.8, "amplitudes": amplitudes,
                        "rms": rms, "unexplainedRMS": sqrt(max(0, rms * rms - tonalPower))]
            }
            report["sampleRate"] = 48_000
            report["decodedSampleCount"] = decoded.samples.count
            report["measurements"] = windows
            var checks: [String: Bool] = [
                "threeIsolatedCompositionTracks": inputAudioTracks == 3,
                "oneExportedAudioTrack": audioTracks.count == 1,
                "oneExportedVideoTrack": videoTracks.count == 1,
                "trimAndCutDuration": duration.isFinite && abs(duration - 2.25) <= 0.05,
                "decodedDuration": abs(Double(decoded.samples.count) / 48_000 - 2.25) <= 0.06
            ]
            for (index, window) in windows.enumerated() {
                let values = window["amplitudes"] as! [String: Double]
                checks["window\(index)MicrophoneGain"] = abs((values["440"] ?? 0) - 0.10) <= 0.025
                checks["window\(index)SourceGain"] = abs((values["880"] ?? 0) - 0.15) <= 0.025
                checks["window\(index)MusicGainAndLoop"] = abs((values["1320"] ?? 0) - 0.05) <= 0.02
                checks["window\(index)NoUnexpectedAudio"] = (window["unexplainedRMS"] as? Double ?? 1) <= 0.025
            }
            report["checks"] = checks
            let passed = checks.values.allSatisfy { $0 }
            report["passed"] = passed
            report["phase"] = passed ? "complete" : "failed"
            if !passed { report["error"] = "Failed checks: " + checks.filter { !$0.value }.map(\.key).sorted().joined(separator: ", ") }
        } catch {
            let error = error as NSError
            report["phase"] = "failed"
            report["error"] = error.localizedDescription
            report["errorDomain"] = error.domain
            report["errorCode"] = error.code
        }
        writeReport()
    }

    private struct ProbeFailure: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }

    private struct PCM {
        let samples: [Float]
        func window(start: Double, duration: Double) -> ArraySlice<Float> {
            let lower = min(samples.count, max(0, Int(start * 48_000)))
            let upper = min(samples.count, lower + Int(duration * 48_000))
            return samples[lower..<upper]
        }
    }

    nonisolated private static func decode(_ url: URL) async throws -> PCM {
        let asset = AVURLAsset(url: url)
        defer { withExtendedLifetime(asset) {} }
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ProbeFailure("The exported synthetic video has no audio track.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ProbeFailure("PCM decoding couldn’t start.") }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            var values = [Float](repeating: 0, count: count)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw ProbeFailure("PCM samples couldn’t be read.") }
            let position = Int((CMSampleBufferGetPresentationTimeStamp(buffer).seconds * 48_000).rounded())
            let start = max(0, position)
            let skip = max(0, -position)
            guard skip < values.count else { continue }
            let end = start + values.count - skip
            guard end <= 48_000 * 20 else { throw ProbeFailure("Unexpectedly long synthetic output.") }
            if samples.count < end { samples.append(contentsOf: repeatElement(0, count: end - samples.count)) }
            samples.replaceSubrange(start..<end, with: values[skip...])
        }
        guard reader.status == .completed, !samples.isEmpty else {
            throw reader.error ?? ProbeFailure("PCM decoding didn’t complete.")
        }
        return PCM(samples: samples)
    }

    private static func amplitude(_ samples: ArraySlice<Float>, frequency: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        var real = 0.0
        var imaginary = 0.0
        for (index, value) in samples.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(index) / 48_000
            real += Double(value) * cos(phase)
            imaginary += Double(value) * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(samples.count)
    }
}
#endif
