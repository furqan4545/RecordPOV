import AVFoundation
import CoreVideo
import Foundation

struct DecodedAudio {
    let samples: [Float]
    let sampleRate: Double

    func rms(start: Double = 0, duration: Double? = nil) -> Double {
        let values = window(start: start, duration: duration)
        guard !values.isEmpty else { return 0 }
        return sqrt(values.reduce(0) { $0 + Double($1 * $1) } / Double(values.count))
    }

    func amplitude(at frequency: Double, start: Double = 0, duration: Double? = nil) -> Double {
        let values = window(start: start, duration: duration)
        guard !values.isEmpty else { return 0 }
        var real = 0.0
        var imaginary = 0.0
        for (index, value) in values.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
            real += Double(value) * cos(phase)
            imaginary += Double(value) * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(values.count)
    }

    private func window(start: Double, duration: Double?) -> ArraySlice<Float> {
        let lower = min(samples.count, max(0, Int(start * sampleRate)))
        let upper = min(samples.count, max(lower, duration.map { lower + Int($0 * sampleRate) } ?? samples.count))
        return samples[lower..<upper]
    }
}

enum AudioSignalFixtures {
    static func writeTone(to url: URL, frequency: Double, amplitude: Float = 0.25,
                          duration: Double, sampleRate: Double = 48_000) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let count = AVAudioFrameCount(duration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for index in 0..<Int(count) {
            buffer.floatChannelData![0][index] = amplitude * Float(sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
        try file.write(from: buffer)
    }

    static func decode(_ url: URL) async throws -> DecodedAudio {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw FixtureError.noAudio }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? FixtureError.read }
        var result: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            var values = [Float](repeating: 0, count: count)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw FixtureError.read }
            let position = Int((CMSampleBufferGetPresentationTimeStamp(buffer).seconds * 48_000).rounded())
            let start = max(0, position)
            let skip = max(0, -position)
            guard skip < values.count else { continue }
            let end = start + values.count - skip
            if result.count < end { result.append(contentsOf: repeatElement(0, count: end - result.count)) }
            result.replaceSubrange(start..<end, with: values[skip...])
        }
        guard reader.status == .completed else { throw reader.error ?? FixtureError.read }
        return DecodedAudio(samples: result, sampleRate: 48_000)
    }

    static func writeVideo(to url: URL, duration: Double, embeddedAudio: URL? = nil) async throws {
        let raw = url.deletingLastPathComponent().appendingPathComponent("raw-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: raw) }
        let writer = try AVAssetWriter(outputURL: raw, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 96
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 96
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.write }
        writer.startSession(atSourceTime: .zero)
        var optional: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 96, kCVPixelFormatType_32BGRA, nil, &optional)
        guard let pixels = optional else { throw FixtureError.write }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            memset(base, 100, CVPixelBufferGetDataSize(pixels))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<max(1, Int((duration * 30).rounded())) {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? FixtureError.write }
                try await Task.sleep(for: .milliseconds(1))
            }
            guard adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? FixtureError.write
            }
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FixtureError.write }
        guard let embeddedAudio else { try FileManager.default.copyItem(at: raw, to: url); return }
        let source = AVURLAsset(url: raw)
        let tone = AVURLAsset(url: embeddedAudio)
        defer { withExtendedLifetime((source, tone)) {} }
        let composed = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        let video = try await source.loadTracks(withMediaType: .video).first!
        let audio = try await tone.loadTracks(withMediaType: .audio).first!
        try composed.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: video, at: .zero)
        try composed.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: audio, at: .zero)
        let exporter = AVAssetExportSession(asset: composed, presetName: AVAssetExportPresetHighestQuality)!
        try await exporter.export(to: url, as: .mov)
    }

    private enum FixtureError: Error { case noAudio, read, write }
}
