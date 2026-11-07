import AVFoundation
import CoreMedia
import Foundation

/// Converts a downloaded original that the phone cannot play directly into
/// H.264 + AAC-LC, reading with AVAssetReader and writing with AVAssetWriter.
/// Streams that already meet the direct rules are copied without re-encoding.
enum OnDeviceConverter {
    struct SourceCodecs: Sendable {
        let video: FourCharCode?
        let audio: FourCharCode?
    }

    /// The actual codecs of the downloaded files (a muxed file, or separate video + audio files).
    static func sourceCodecs(assets: [DirectMediaAsset], files: [URL]) async throws -> SourceCodecs {
        let (videoFile, audioFile) = try sources(assets: assets, files: files)
        let videoAsset = AVURLAsset(url: videoFile)
        let audioAsset = audioFile.map { AVURLAsset(url: $0) } ?? videoAsset
        defer { withExtendedLifetime((videoAsset, audioAsset)) {} }
        let video = try await videoAsset.loadTracks(withMediaType: .video).first
        let audio = try await audioAsset.loadTracks(withMediaType: .audio).first
        let videoType = try await video?.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
        // HE-AAC can report the plain AAC subtype at its core layer; name it by its format list.
        let audioType = try await audio?.load(.formatDescriptions).first.map { description in
            let subtype = CMFormatDescriptionGetMediaSubType(description)
            return subtype == kAudioFormatMPEG4AAC && !DirectVideoPreparer.isAACLC(description) ? kAudioFormatMPEG4AAC_HE : subtype
        }
        return SourceCodecs(video: videoType, audio: audioType)
    }

    /// H.264 target bitrate derived from the source data rate, so quality matches without bloating size.
    static func targetBitrate(sourceBitsPerSecond: Double, codec: SourceVideoCodec, width: Int, height: Int) -> Int {
        let factor: Double
        switch codec {
        case .vp9, .av1: factor = 1.6
        case .hevc: factor = 1.3
        case .h264, .unknown: factor = 1
        }
        let shortSide = min(width, height)
        let range: ClosedRange<Double> = shortSide <= 720 ? 1_500_000...8_000_000
            : shortSide <= 1080 ? 3_000_000...12_000_000 : 12_000_000...40_000_000
        let wanted = sourceBitsPerSecond.isFinite ? max(0, sourceBitsPerSecond) * factor : 0
        return Int(min(max(wanted, range.lowerBound), range.upperBound).rounded())
    }

    /// Converts into the same staging folder DirectVideoPreparer uses, validates the
    /// output with the same rules, and returns the published file. `progress` gets
    /// 0...1 by video presentation time. Cancelling the task deletes the partial output.
    /// The partial output is named per job, so a conversion retried after the app was
    /// killed overwrites it instead of leaving another large file behind.
    static func partialOutput(jobID: UUID, directory: URL? = nil) -> URL {
        (directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SourceVideos", isDirectory: true))
            .appendingPathComponent(".\(jobID.uuidString).converting.mp4")
    }
    static func removePartialOutput(jobID: UUID, directory: URL? = nil) {
        try? FileManager.default.removeItem(at: partialOutput(jobID: jobID, directory: directory))
    }

    static func convert(assets: [DirectMediaAsset], files: [URL], expected: DirectMediaExpectation, jobID: UUID,
                        directory: URL? = nil, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        DeviceVideoCapabilities.registerSupplementalDecoders()
        let (videoFile, audioFile) = try sources(assets: assets, files: files)
        let videoAsset = AVURLAsset(url: videoFile)
        let audioAsset = audioFile.map { AVURLAsset(url: $0) } ?? videoAsset
        defer { withExtendedLifetime((videoAsset, audioAsset)) {} }
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else { throw DirectImportError.incompatible }
        let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first
        if audioFile != nil, audioTrack == nil { throw DirectImportError.incompatible }

        let videoRange = try await videoTrack.load(.timeRange)
        let duration = videoRange.duration.seconds
        guard duration.isFinite, duration > 0 else { throw DirectImportError.incompatible }
        let descriptions = try await videoTrack.load(.formatDescriptions)
        guard let videoFormat = descriptions.first else { throw DirectImportError.incompatible }
        let size = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let fps = Double(try await videoTrack.load(.nominalFrameRate))
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0 else { throw DirectImportError.incompatible }
        let identity = abs(transform.a - 1) < 0.001 && abs(transform.d - 1) < 0.001 && abs(transform.b) < 0.001 && abs(transform.c) < 0.001
        let copyVideo = descriptions.allSatisfy { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 } &&
            identity && fps > 0 && fps <= 60.1 && width % 2 == 0 && height % 2 == 0 &&
            max(width, height) <= 3840 && min(width, height) <= 2160

        var audioRange: CMTimeRange?
        var audioFormat: CMFormatDescription?
        var copyAudio = false
        var channels = 2, sampleRate = 44_100.0
        if let audioTrack {
            audioRange = try await audioTrack.load(.timeRange)
            let audioDescriptions = try await audioTrack.load(.formatDescriptions)
            guard let first = audioDescriptions.first else { throw DirectImportError.incompatible }
            audioFormat = first
            copyAudio = audioDescriptions.allSatisfy { description in
                guard DirectVideoPreparer.isAACLC(description),
                      let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return false }
                return (1...2).contains(stream.pointee.mChannelsPerFrame) && (8000...48000).contains(stream.pointee.mSampleRate)
            }
            // HE-AAC's first stream description can be its core layer (half rate, mono for v2).
            let decoded = CMAudioFormatDescriptionGetRichestDecodableFormat(first).map { $0.pointee.mASBD }
                ?? CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee
            if let stream = decoded {
                channels = stream.mChannelsPerFrame == 1 ? 1 : 2
                if stream.mSampleRate > 0 { sampleRate = min(stream.mSampleRate, 48_000) }
            }
        }

        let (_, published) = try DirectVideoPreparer.stagingFiles(directory: directory)
        let target = partialOutput(jobID: jobID, directory: directory)
        try? FileManager.default.removeItem(at: target)
        let writer = try AVAssetWriter(outputURL: target, fileType: .mp4)
        let videoReader = try AVAssetReader(asset: videoAsset)
        let audioReader = audioFile == nil ? videoReader : try AVAssetReader(asset: audioAsset)

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: copyVideo ? nil :
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        videoOutput.alwaysCopiesSampleData = false
        let videoInput: AVAssetWriterInput
        if copyVideo {
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        } else {
            var rate = Double(try await videoTrack.load(.estimatedDataRate))
            if !(rate > 0) { rate = Double(try await videoTrack.load(.totalSampleDataLength)) * 8 / duration }
            // Fragmented MP4 can report neither; a video-only file's size is its video data.
            if !(rate > 0), audioFile != nil,
               let bytes = (try? FileManager.default.attributesOfItem(atPath: videoFile.path)[.size] as? NSNumber)?.doubleValue {
                rate = bytes * 8 / duration
            }
            let codec = DeviceVideoCapabilities.codec(of: CMFormatDescriptionGetMediaSubType(videoFormat))
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: targetBitrate(sourceBitsPerSecond: rate, codec: codec, width: width, height: height),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0
            ]
            if fps > 0 {
                compression[AVVideoExpectedSourceFrameRateKey] = fps
                compression[AVVideoMaxKeyFrameIntervalKey] = max(1, Int((fps * 2).rounded()))
            }
            let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width,
                                           AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: compression]
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw DirectImportError.incompatible }
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        }
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard videoReader.canAdd(videoOutput), writer.canAdd(videoInput) else { throw DirectImportError.incompatible }
        videoReader.add(videoOutput); writer.add(videoInput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack, let audioFormat {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
            let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: copyAudio ? nil : [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels, AVChannelLayoutKey: layoutData
            ])
            output.alwaysCopiesSampleData = false
            let input: AVAssetWriterInput
            if copyAudio {
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            } else {
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels == 1 ? 96_000 : 128_000,
                    AVChannelLayoutKey: layoutData]
                guard writer.canApply(outputSettings: settings, forMediaType: .audio) else { throw DirectImportError.incompatible }
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            }
            input.expectsMediaDataInRealTime = false
            guard audioReader.canAdd(output), writer.canAdd(input) else { throw DirectImportError.incompatible }
            audioReader.add(output); writer.add(input)
            audioOutput = output; audioInput = input
        }

        let videoQueue = DispatchQueue(label: "app.recordpov.convert.video")
        let audioQueue = DispatchQueue(label: "app.recordpov.convert.audio")
        let videoPump = Pump()
        let audioPump = Pump()
        let pumps = audioInput == nil ? [videoPump] : [videoPump, audioPump]
        let stopAll: @Sendable (Error) -> Void = { error in for pump in pumps { pump.finish(.failure(error)) } }
        do {
            guard videoReader.startReading(), audioReader === videoReader || audioReader.startReading() else {
                throw videoReader.error ?? audioReader.error ?? DirectImportError.incompatible
            }
            guard writer.startWriting() else { throw writer.error ?? DirectImportError.incompatible }
            writer.startSession(atSourceTime: audioRange.map { CMTimeMinimum(videoRange.start, $0.start) } ?? videoRange.start)
            let reported = ReportedProgress()
            feed(videoInput, from: videoOutput, reader: videoReader, writer: writer, queue: videoQueue, pump: videoPump, stopAll: stopAll) { sample in
                let time = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), videoRange.start).seconds
                guard time.isFinite else { return }
                let fraction = min(1, max(0, time / duration))
                if reported.advance(to: fraction) { progress(fraction) }
            }
            if let audioInput, let audioOutput {
                feed(audioInput, from: audioOutput, reader: audioReader, writer: writer, queue: audioQueue, pump: audioPump, stopAll: stopAll, observe: nil)
            }
            // A writer that fails while an input is not ready never calls the pumps again.
            let watched = WatchedWriter(writer)
            let watchdog = Task {
                while !Task.isCancelled {
                    if watched.writer.status == .failed { stopAll(watched.writer.error ?? DirectImportError.incompatible); return }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            defer { watchdog.cancel() }
            try await withTaskCancellationHandler {
                for pump in pumps { try await pump.wait() }
            } onCancel: { stopAll(CancellationError()) }
            try Task.checkCancellation()
            guard videoReader.status == .completed, audioReader.status == .completed else {
                throw videoReader.error ?? audioReader.error ?? DirectImportError.incompatible
            }
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? DirectImportError.incompatible }
            try Task.checkCancellation()
        } catch {
            stopAll(error)
            // Let any in-flight sample callback return before tearing the reader and writer down.
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                videoQueue.async { audioQueue.async { done.resume() } }
            }
            videoReader.cancelReading(); audioReader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        progress(1)
        return try await DirectVideoPreparer.publishConverted(target, as: published, expected: expected)
    }

    private static func sources(assets: [DirectMediaAsset], files: [URL]) throws -> (video: URL, audio: URL?) {
        guard assets.count == files.count else { throw DirectImportError.invalidDelivery }
        if assets.count == 1, assets[0].role == "muxed" { return (files[0], nil) }
        guard assets.count == 2, let video = assets.firstIndex(where: { $0.role == "video" }),
              let audio = assets.firstIndex(where: { $0.role == "audio" }) else { throw DirectImportError.invalidDelivery }
        return (files[video], files[audio])
    }

    private static func feed(_ input: AVAssetWriterInput, from output: AVAssetReaderOutput, reader: AVAssetReader,
                             writer: AVAssetWriter, queue: DispatchQueue, pump: Pump,
                             stopAll: @escaping @Sendable (Error) -> Void, observe: ((CMSampleBuffer) -> Void)?) {
        input.requestMediaDataWhenReady(on: queue) {
            while !pump.isDone, input.isReadyForMoreMediaData {
                guard let sample = output.copyNextSampleBuffer() else {
                    // A shared muxed reader stays .reading until its other output is drained too.
                    if reader.status == .failed { stopAll(reader.error ?? DirectImportError.incompatible) }
                    else {
                        input.markAsFinished()
                        pump.finish(.success(()))
                    }
                    return
                }
                observe?(sample)
                guard input.append(sample) else { stopAll(writer.error ?? DirectImportError.incompatible); return }
            }
        }
    }

    /// One finished or failed stream; resumable once, from any thread.
    private final class Pump: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Void, Error>?
        private var waiter: CheckedContinuation<Void, Error>?
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
        func finish(_ value: Result<Void, Error>) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = value
            let waiting = waiter; waiter = nil
            lock.unlock()
            waiting?.resume(with: value)
        }
        func wait() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(with: result); return }
                waiter = continuation
                lock.unlock()
            }
        }
    }

    /// The writer's status and error are read-only properties, safe to poll from the watchdog.
    private final class WatchedWriter: @unchecked Sendable {
        let writer: AVAssetWriter
        init(_ writer: AVAssetWriter) { self.writer = writer }
    }

    /// Reports whole percents only; touched from the video queue alone.
    private final class ReportedProgress: @unchecked Sendable {
        private var percent = -1
        func advance(to fraction: Double) -> Bool {
            let next = Int((fraction * 100).rounded(.down))
            guard next > percent else { return false }
            percent = next
            return true
        }
    }
}
