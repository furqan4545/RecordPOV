import Accelerate
import AVFoundation
import CryptoKit
import Foundation

enum VoiceCleanup {
    /// A new cache version is required whenever the signal processing changes.
    static let version = "gentle-hp70-stft-v1"
    private static let processor = VoiceCleanupProcessor()

    static func process(microphoneURL: URL) async throws -> URL {
        try await processor.process(microphoneURL: microphoneURL)
    }
}

enum VoiceCleanupError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "Voice cleanup couldn’t finish. Your original voice is safe. Turn off Clean voice to use it."
    }
}

/// Coalesces preview/export requests. Cancellation stops a job once its last
/// waiter leaves; partially written files never become cache entries.
actor VoiceCleanupProcessor {
    private struct Job {
        let id: UUID
        let task: Task<URL, Error>
        var waiters: Set<UUID>
    }
    private let directory: URL
    private var jobs: [String: Job] = [:]

    init(cacheDirectory: URL? = nil) {
        directory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceCleanup", isDirectory: true)
    }

    func process(microphoneURL: URL) async throws -> URL {
        try Task.checkCancellation()
        guard microphoneURL.isFileURL else { throw VoiceCleanupError.unavailable }
        let key = try cacheKey(microphoneURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("voice-\(key).caf")
        if validCache(output) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: output.path)
            return output
        }
        if FileManager.default.fileExists(atPath: output.path) { try? FileManager.default.removeItem(at: output) }
        let waiter = UUID()
        let job: Job
        if var existing = jobs[key] {
            existing.waiters.insert(waiter)
            jobs[key] = existing
            job = existing
        } else {
            let task = Task.detached(priority: .userInitiated) {
                try await VoiceCleanupPipeline.run(input: microphoneURL, output: output)
                return output
            }
            job = Job(id: UUID(), task: task, waiters: [waiter])
            jobs[key] = job
        }
        defer { release(key: key, jobID: job.id, waiter: waiter) }
        return try await withTaskCancellationHandler {
            let result = try await job.task.value
            try Task.checkCancellation()
            prune(keeping: result)
            return result
        } onCancel: {
            Task { await self.release(key: key, jobID: job.id, waiter: waiter) }
        }
    }

    private func release(key: String, jobID: UUID, waiter: UUID) {
        guard var job = jobs[key], job.id == jobID else { return }
        job.waiters.remove(waiter)
        if job.waiters.isEmpty { jobs[key] = nil; job.task.cancel() }
        else { jobs[key] = job }
    }

    private func cacheKey(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw VoiceCleanupError.unavailable }
        let identity = [VoiceCleanup.version, url.standardizedFileURL.path,
            String(describing: attributes[.systemNumber]), String(describing: attributes[.systemFileNumber]),
            String(describing: attributes[.size]),
            String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)].joined(separator: "|")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func validCache(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0 && file.processingFormat.channelCount == 1 && file.processingFormat.sampleRate == 48_000
    }

    private func prune(keeping current: URL) {
        let entries = ((try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: .skipsHiddenFiles)) ?? [])
            .filter { $0.pathExtension == "caf" && $0.lastPathComponent.hasPrefix("voice-") }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]))) }
            .sorted { ($0.1?.contentModificationDate ?? .distantPast) > ($1.1?.contentModificationDate ?? .distantPast) }
        var bytes = 0
        for (index, entry) in entries.enumerated() {
            bytes += entry.1?.fileSize ?? 0
            if entry.0.standardizedFileURL != current.standardizedFileURL && (index >= 6 || bytes > 384 * 1024 * 1024) {
                try? FileManager.default.removeItem(at: entry.0)
            }
        }
    }
}

private enum VoiceCleanupPipeline {
    static let sampleRate = 48_000.0
    static let frameSize = 2_048
    static let hop = 512

    static func run(input: URL, output: URL) async throws {
        let folder = output.deletingLastPathComponent()
        let pcm = folder.appendingPathComponent(".\(UUID()).input.caf")
        let partial = folder.appendingPathComponent(".\(UUID()).output.caf")
        defer {
            for file in [pcm, partial] where FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        do {
            try await decodeMicrophone(input, to: pcm)
            try Task.checkCancellation()
            try filter(pcm, to: partial)
            try Task.checkCancellation()
            if !FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.moveItem(at: partial, to: output)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw VoiceCleanupError.unavailable }
    }

    /// AAC/MOV is decoded with its timestamps. Leading gaps, priming and the
    /// original recording clock survive conversion to mono PCM; no audio device.
    private static func decodeMicrophone(_ url: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: url)
        defer { withExtendedLifetime(asset) {} }
        guard let audio = try await asset.loadTracks(withMediaType: .audio).first else { throw VoiceCleanupError.unavailable }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw VoiceCleanupError.unavailable }
        let expectedFrames = Int64((duration * sampleRate).rounded())
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(decoded)
        guard reader.startReading() else { throw VoiceCleanupError.unavailable }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: destination, settings: format.settings)
        var highPass = HighPass70()
        var cursor: Int64 = 0
        func append(_ values: ArraySlice<Float>) throws {
            guard !values.isEmpty else { return }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))!
            buffer.frameLength = AVAudioFrameCount(values.count)
            let pointer = buffer.floatChannelData![0]
            for (index, value) in values.enumerated() { pointer[index] = highPass.process(value) }
            try file.write(from: buffer)
            cursor += Int64(values.count)
        }
        func silence(until end: Int64) throws {
            while cursor < end {
                try Task.checkCancellation()
                try append(Array(repeating: Float.zero, count: Int(min(8_192, end - cursor)))[...])
            }
        }
        while let buffer = decoded.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            var values = [Float](repeating: 0, count: count)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw VoiceCleanupError.unavailable }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard timestamp.isFinite else { throw VoiceCleanupError.unavailable }
            let start = Int64((timestamp * sampleRate).rounded())
            let skip = Int(max(0, cursor - start))
            guard skip < values.count, cursor < expectedFrames else { continue }
            try silence(until: min(expectedFrames, max(cursor, start)))
            let keptCount = min(values.count - skip, Int(max(0, expectedFrames - cursor)))
            if keptCount > 0 { try append(values[skip..<(skip + keptCount)]) }
        }
        guard reader.status == .completed else { throw reader.error ?? VoiceCleanupError.unavailable }
        try silence(until: expectedFrames)
        guard cursor > 0 else { throw VoiceCleanupError.unavailable }
    }

    /// Profile selection samples the entire file. Quiet broadband frames teach
    /// a conservative floor; spectral medians exclude sustained vowel peaks.
    private static func noiseProfile(_ input: AVAudioFile, fft: VoiceFFT, window: [Float]) throws -> [Float] {
        let count = min(128, max(1, Int(input.length) / frameSize))
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(frameSize))!
        var candidates: [(energy: Double, power: [Float])] = []
        for index in 0..<count {
            try Task.checkCancellation()
            input.framePosition = Int64(index) * max(0, input.length - Int64(frameSize)) / Int64(max(1, count - 1))
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(frameSize), input.length - input.framePosition)))
            var frame = [Float](repeating: 0, count: frameSize)
            let pointer = buffer.floatChannelData![0]
            var energy = 0.0
            for sample in 0..<Int(buffer.frameLength) {
                frame[sample] = pointer[sample] * window[sample]
                energy += Double(frame[sample] * frame[sample])
            }
            if energy > 1e-10 { candidates.append((energy, fft.forward(frame))) }
        }
        let bins = frameSize / 2 + 1
        // Sparse isolated sounds surrounded by digital silence are not a hiss
        // profile. Preserve those attacks instead of learning them as noise.
        guard candidates.count >= max(1, count / 2) else { return [Float](repeating: 0, count: bins) }
        let quiet = candidates.sorted { $0.energy < $1.energy }.prefix(max(1, candidates.count / 5))
        var mean = [Float](repeating: 0, count: bins)
        for candidate in quiet {
            for bin in 0..<bins { mean[bin] += candidate.power[bin] / Float(quiet.count) }
        }
        var floor = mean
        for bin in 0..<bins {
            let neighbors = mean[max(0, bin - 8)...min(bins - 1, bin + 8)].sorted()
            let broadband = neighbors[neighbors.count / 2]
            floor[bin] = max(0, min(mean[bin] * 0.85, broadband * 1.25))
        }
        floor[0] = 0
        return floor
    }

    /// Streaming weighted overlap-add: fixed-size rings, no whole-take float
    /// arrays. Analysis/synthesis windows normalize to unity at both endpoints.
    private static func filter(_ inputURL: URL, to outputURL: URL) throws {
        let input = try AVAudioFile(forReading: inputURL)
        let output = try AVAudioFile(forWriting: outputURL, settings: input.processingFormat.settings)
        let fft = try VoiceFFT(size: frameSize)
        let window = (0..<frameSize).map { Float(sqrt(max(0, 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(frameSize))))) }
        var floor = try noiseProfile(input, fft: fft, window: window)
        input.framePosition = 0
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(hop))!
        let writeBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(hop))!
        var ring = [Float](repeating: 0, count: frameSize)
        var sum = ring
        var weights = ring
        var gains = [Float](repeating: 1, count: floor.count)
        var position = -Int64(frameSize - hop)
        while position < input.length {
            try Task.checkCancellation()
            if input.framePosition < input.length {
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(hop), input.length - input.framePosition)))
            } else { buffer.frameLength = 0 }
            for sample in 0..<hop {
                ring[frameSize - hop + sample] = sample < Int(buffer.frameLength) ? buffer.floatChannelData![0][sample] : 0
            }
            let spectrum = fft.forward(zip(ring, window).map(*))
            var targets = gains
            for bin in 0..<floor.count {
                let power = max(1e-20, spectrum[bin])
                let frequency = Double(bin) * sampleRate / Double(frameSize)
                let minimum: Float = frequency < 1_500 ? 0.82 : 0.5
                let target = max(minimum, sqrt(max(0, 1 - 0.8 * floor[bin] / power)))
                // Suppression eases in; an emerging consonant/vowel is released
                // immediately. There is no hard gate or automatic gain boost.
                targets[bin] = target > gains[bin] ? target : gains[bin] * 0.85 + target * 0.15
                if floor[bin] > 0, power < floor[bin] * 1.5 { floor[bin] = floor[bin] * 0.999 + power * 0.001 }
            }
            for bin in 0..<gains.count {
                let smoothed = (targets[max(0, bin - 1)] + targets[bin] * 2 + targets[min(gains.count - 1, bin + 1)]) / 4
                let minimum: Float = Double(bin) * sampleRate / Double(frameSize) < 1_500 ? 0.82 : 0.5
                gains[bin] = max(minimum, spectrum[bin] > floor[bin] * 8 ? max(0.98, targets[bin]) : smoothed)
            }
            let restored = fft.inverse(gains: gains)
            for sample in 0..<frameSize {
                sum[sample] += restored[sample] * window[sample]
                weights[sample] += window[sample] * window[sample]
            }
            let lower = Int(max(0, -position))
            let upper = Int(min(Int64(hop), input.length - position))
            if upper > lower {
                writeBuffer.frameLength = AVAudioFrameCount(upper - lower)
                for sample in lower..<upper {
                    let value = sum[sample] / max(1e-12, weights[sample])
                    writeBuffer.floatChannelData![0][sample - lower] = value.isFinite ? max(-1, min(1, value)) : 0
                }
                try output.write(from: writeBuffer)
            }
            shift(&ring); shift(&sum); shift(&weights)
            position += Int64(hop)
        }
    }

    private static func shift(_ buffer: inout [Float]) {
        buffer.withUnsafeMutableBufferPointer { pointer in
            memmove(pointer.baseAddress!, pointer.baseAddress! + hop, (frameSize - hop) * MemoryLayout<Float>.size)
            (pointer.baseAddress! + frameSize - hop).update(repeating: 0, count: hop)
        }
    }
}

private struct HighPass70 {
    private var z1 = 0.0, z2 = 0.0
    private let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    init() {
        let omega = 2 * Double.pi * 70 / 48_000
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * sqrt(0.5))
        b0 = (1 + cosine) / (2 * (1 + alpha)); b1 = -(1 + cosine) / (1 + alpha); b2 = b0
        a1 = -2 * cosine / (1 + alpha); a2 = (1 - alpha) / (1 + alpha)
    }
    mutating func process(_ sample: Float) -> Float {
        let input = sample.isFinite ? Double(sample) : 0
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return Float(output)
    }
}

private final class VoiceFFT {
    private let setup: FFTSetup
    private let logarithm: vDSP_Length
    private let size: Int
    private var real: [Float]
    private var imaginary: [Float]
    init(size: Int) throws {
        self.size = size
        logarithm = vDSP_Length(log2(Double(size)))
        guard let setup = vDSP_create_fftsetup(logarithm, FFTRadix(kFFTRadix2)) else { throw VoiceCleanupError.unavailable }
        self.setup = setup
        real = [Float](repeating: 0, count: size)
        imaginary = real
    }
    deinit { vDSP_destroy_fftsetup(setup) }
    func forward(_ samples: [Float]) -> [Float] {
        real = samples
        imaginary.withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress!, 1, vDSP_Length(size)) }
        transform(direction: FFTDirection(FFT_FORWARD))
        return (0...size / 2).map { real[$0] * real[$0] + imaginary[$0] * imaginary[$0] }
    }
    func inverse(gains: [Float]) -> [Float] {
        for bin in 0..<size {
            let gain = gains[bin <= size / 2 ? bin : size - bin]
            real[bin] *= gain; imaginary[bin] *= gain
        }
        transform(direction: FFTDirection(FFT_INVERSE))
        return real.map { $0 / Float(size) }
    }
    private func transform(direction: FFTDirection) {
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, logarithm, direction)
            }
        }
    }
}
