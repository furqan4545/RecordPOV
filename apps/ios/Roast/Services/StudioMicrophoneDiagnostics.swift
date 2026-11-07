#if DEBUG
import AVFoundation
import Foundation

/// An explicitly requested route check. No capture session, engine, input tap,
/// audio player, audio sample, or media file is created by this diagnostic.
@MainActor
enum StudioMicrophoneDiagnostics {
    static func run() async {
        guard ProcessInfo.processInfo.environment["ROAST_MICROPHONE_DIAGNOSTICS"] == "1" else { return }
        let controller = StudioMicrophoneSession()
        let before = controller.snapshot
        var report = Report(runID: ProcessInfo.processInfo.environment["ROAST_DIAGNOSTIC_RUN_ID"] ?? "",
            createdAt: ISO8601DateFormatter().string(from: Date()), before: before)
        // Do not request permission as part of a metadata-only check.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            report.error = "Microphone permission is not already authorized; no session was activated."
            write(report)
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try controller.configureForRecording()
            report.afterActivation = controller.snapshot
            report.afterRouteSettled = await controller.verifyEchoCancellation()
        } catch { report.error = error.localizedDescription }
        report.configurationErrors = controller.configurationErrors
        controller.stopMonitoring()
        var restorationErrors: [String] = []
        do { try session.setActive(false, options: .notifyOthersOnDeactivation) }
        catch { restorationErrors.append(error.localizedDescription) }
        do { try session.setPrefersEchoCancelledInput(before.prefersEchoCancellation) }
        catch { restorationErrors.append(error.localizedDescription) }
        do {
            try session.setCategory(AVAudioSession.Category(rawValue: before.category),
                                    mode: AVAudioSession.Mode(rawValue: before.mode),
                                    options: AVAudioSession.CategoryOptions(rawValue: before.categoryOptions))
        } catch { restorationErrors.append(error.localizedDescription) }
        report.configurationRestored = restorationErrors.isEmpty
        report.restorationError = restorationErrors.isEmpty ? nil : restorationErrors.joined(separator: "; ")
        write(report)
    }

    private struct Report: Encodable {
        let runID: String
        let createdAt: String
        let samplesCaptured = false
        let cameraEnabled = false
        let captureSessionCreated = false
        let audioEngineCreated = false
        let before: StudioMicrophoneSnapshot
        var afterActivation: StudioMicrophoneSnapshot?
        var afterRouteSettled: StudioMicrophoneSnapshot?
        var configurationErrors: [String] = []
        var error: String?
        var configurationRestored = false
        var restorationError: String?
    }

    private static func write(_ report: Report) {
        do {
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: folder.appendingPathComponent("MicrophoneSessionDiagnostic.json"),
                                             options: .atomic)
        } catch {
            print("ROAST_MICROPHONE_DIAGNOSTICS failed to save metadata: \(error.localizedDescription)")
        }
    }
}
#endif
