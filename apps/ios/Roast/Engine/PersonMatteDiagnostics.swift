#if DEBUG
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Benchmarks a public test fixture copied into Caches; never opens a camera/mic.
enum PersonMatteDiagnostics {
    static func run() async {
        await Task.detached(priority: .userInitiated) { runFixture() }.value
    }

    private static func runFixture() {
        let folder = ProcessInfo.processInfo.environment["ROAST_MATTE_DIAGNOSTIC_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var report: [String: Any] = [
            "runIdentifier": ProcessInfo.processInfo.environment["ROAST_DIAGNOSTIC_RUN_ID"] ?? UUID().uuidString,
            "timestamp": ISO8601DateFormatter().string(from: .now),
            "phase": "starting", "cameraEnabled": false, "microphoneEnabled": false,
        ]
        func writeReport() {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("PersonMatteDiagnostic.json"), options: .atomic)
            }
        }
        writeReport()
        do {
            guard let image = CIImage(contentsOf: folder.appendingPathComponent("PersonMatteFixture.jpg"),
                                      options: [.applyOrientationProperty: true]) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let width = Int(image.extent.width), height = Int(image.extent.height)
            var storage: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                      &storage) == kCVReturnSuccess, let buffer = storage else {
                throw StudioCaptureError.cannotCreateWriter
            }
            let context = CIContext(options: [.cacheIntermediates: false])
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            context.render(image, to: buffer, bounds: image.extent, colorSpace: colorSpace)
            let source = CIImage(cvPixelBuffer: buffer)
            let backdrop = CIImage(color: CIColor(red: 0.20, green: 0.29, blue: 0.38)).cropped(to: source.extent)
            let legacy = VNGeneratePersonSegmentationRequest()
            legacy.qualityLevel = .balanced
            legacy.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let legacySequence = VNSequenceRequestHandler()
            let improved = PersonMatteProcessor()
            var measurements: [[String: Any]] = []
            for method in ["balancedBefore", "accurateAfter"] {
                report["phase"] = method
                writeReport()
                var times: [Double] = []
                var lastImage: CGImage?
                var maskSize = CGSize.zero
                for iteration in 0..<12 {
                    let start = ProcessInfo.processInfo.systemUptime
                    let cutout: CIImage
                    if method == "accurateAfter" {
                        guard let result = try improved.cutout(from: buffer, revision: Int64(iteration)) else {
                            throw StudioCaptureError.emptyRecording
                        }
                        cutout = result
                        maskSize = improved.maskSize
                    } else {
                        try legacySequence.perform([legacy], on: buffer, orientation: .up)
                        guard let maskBuffer = legacy.results?.first?.pixelBuffer else {
                            throw StudioCaptureError.emptyRecording
                        }
                        let mask = CIImage(cvPixelBuffer: maskBuffer)
                        maskSize = mask.extent.size
                        let scale = max(source.extent.width / mask.extent.width,
                                        source.extent.height / mask.extent.height)
                        let oldMask = mask.transformed(by: .init(scaleX: scale, y: scale))
                            .transformed(by: .init(translationX: (source.extent.width - mask.extent.width * scale) / 2,
                                                  y: (source.extent.height - mask.extent.height * scale) / 2))
                        cutout = source.applyingFilter("CIBlendWithMask", parameters: [
                            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: source.extent),
                            kCIInputMaskImageKey: oldMask,
                        ])
                    }
                    // createCGImage completes GPU work so timings include rendering.
                    lastImage = context.createCGImage(cutout.composited(over: backdrop), from: source.extent,
                                                       format: .RGBA8, colorSpace: colorSpace)
                    guard lastImage != nil else { throw StudioCaptureError.emptyRecording }
                    if iteration >= 2 { times.append((ProcessInfo.processInfo.systemUptime - start) * 1000) }
                }
                if let lastImage {
                    let url = folder.appendingPathComponent("PersonMatte-\(method).png")
                    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    CGImageDestinationAddImage(destination, lastImage, nil)
                    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
                }
                let sorted = times.sorted()
                measurements.append([
                    "method": method, "maskWidth": maskSize.width, "maskHeight": maskSize.height,
                    "p50Milliseconds": sorted[sorted.count / 2], "p95Milliseconds": sorted.last ?? 0,
                    "samples": times.count,
                ])
            }
            report["measurements"] = measurements
            report["revision"] = improved.request.revision
            report["supportedRevisions"] = Array(VNGeneratePersonSegmentationRequest.supportedRevisions)
            report["outputPixelFormat"] = improved.request.outputPixelFormat
            report["inputWidth"] = width
            report["inputHeight"] = height
            report["thermalState"] = ProcessInfo.processInfo.thermalState.rawValue
            report["phase"] = "complete"
            report["passed"] = true
        } catch {
            report["phase"] = "failed"
            report["error"] = error.localizedDescription
            report["passed"] = false
        }
        writeReport()
    }
}
#endif
