import AVFoundation
import CoreImage
import ReplayKit

/// ReplayKit delivers the selected screen after the user approves the system broadcast picker.
/// The extension saves a screen-only source; the app adds the camera reaction afterward.
final class SampleHandler: RPBroadcastSampleHandler {
    private let queue = DispatchQueue(label: "app.roast.broadcast.writer")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var destinationURL: URL?
    private var firstTimestamp: CMTime?
    private var lastFrameTime = CMTime.invalid
    private var outputSize = CGSize(width: 720, height: 1280)
    private var paused = false
    private var writerFailure: Error?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let identifier = Bundle.main.object(forInfoDictionaryKey: "RoastAppGroupIdentifier") as? String ?? "group.com.roast.app"
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            finishBroadcastWithError(NSError(domain: "Roast", code: 1, userInfo: [NSLocalizedDescriptionKey: "Screen recording isn’t available. Update RecordPOV and try again."]))
            return
        }
        let folder = group.appendingPathComponent("ScreenTakes", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)"
            outputURL = folder.appendingPathComponent(name + ".pending")
            destinationURL = folder.appendingPathComponent(name + ".mp4")
        } catch { finishBroadcastWithError(error) }
    }

    override func broadcastPaused() { queue.sync { paused = true } }
    override func broadcastResumed() { queue.sync { paused = false } }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        queue.sync {
            guard !paused, writerFailure == nil else { return }
            do {
                if sampleBufferType == .video { try appendVideo(sampleBuffer) }
                else if sampleBufferType == .audioApp,
                        let writer, writer.status == .writing,
                        let audioInput, audioInput.isReadyForMoreMediaData,
                        let start = firstTimestamp,
                        CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), start) >= 0 {
                    if !audioInput.append(sampleBuffer), writer.status == .failed {
                        throw writer.error ?? CocoaError(.fileWriteUnknown)
                    }
                }
            } catch {
                writerFailure = error
                finishBroadcastWithError(error)
            }
        }
    }

    private func prepare(_ buffer: CVPixelBuffer, timestamp: CMTime) throws {
        guard let outputURL else { throw CocoaError(.fileNoSuchFile) }
        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        let factor = min(720 / min(width, height), 1280 / max(width, height))
        outputSize = CGSize(width: max(2, floor(width * factor / 2) * 2),
                            height: max(2, floor(height * factor / 2) * 2))
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width), AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000,
                                              AVVideoExpectedSourceFrameRateKey: 30]
        ])
        video.expectsMediaDataInRealTime = true
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000
        ])
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), writer.canAdd(audio) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(video)
        writer.add(audio)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: timestamp)
        self.writer = writer
        videoInput = video
        audioInput = audio
        firstTimestamp = timestamp
    }

    private func appendVideo(_ sample: CMSampleBuffer) throws {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        if lastFrameTime.isValid, CMTimeSubtract(time, lastFrameTime).seconds < 1 / 30.0 { return }
        if writer == nil { try prepare(buffer, timestamp: time) }
        guard let writer, writer.status == .writing,
              let videoInput, videoInput.isReadyForMoreMediaData,
              let adaptor, let pool = adaptor.pixelBufferPool else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let target = pixelBuffer else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(outputSize.width / image.extent.width, outputSize.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (outputSize.width - image.extent.width * scale) / 2,
                                               y: (outputSize.height - image.extent.height * scale) / 2))
        let bounds = CGRect(origin: .zero, size: outputSize)
        let result = scaled.composited(over: CIImage(color: .black).cropped(to: bounds))
        context.render(result, to: target, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        guard adaptor.append(target, withPresentationTime: time) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        lastFrameTime = time
    }

    override func broadcastFinished() {
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { [self] in
            guard let writer, writer.status == .writing else { semaphore.signal(); return }
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            writer.finishWriting { [self] in
                if writer.status == .completed, let outputURL, let destinationURL {
                    try? FileManager.default.moveItem(at: outputURL, to: destinationURL)
                } else if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + 12)
    }
}

