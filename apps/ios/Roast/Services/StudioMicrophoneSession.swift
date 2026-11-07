import AVFoundation
import Foundation

/// Hardware echo cancellation leaves the source's digital audio untouched. The
/// capture session continues to deliver its original, host-clocked buffers.
@MainActor
final class StudioMicrophoneSession {
    private let audio: any StudioAudioSessionControlling
    private(set) var configurationErrors: [String] = []
    private var isMonitoring = false
    private var verificationID = UUID()

    init(audio: (any StudioAudioSessionControlling)? = nil) {
        self.audio = audio ?? SystemStudioAudioSession()
    }

    var snapshot: StudioMicrophoneSnapshot { audio.snapshot }

    func configureForRecording() throws {
        verificationID = UUID()
        isMonitoring = false
        configurationErrors = []
        // In-app AVPlayer playback shares this session. Mixing unrelated apps is
        // unnecessary during a take and lowers our audio-preference priority.
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        #if os(iOS) && !targetEnvironment(macCatalyst)
        // Full-band input/output on compatible AirPods; HFP remains the fallback.
        options.insert(.bluetoothHighQualityRecording)
        #endif
        try audio.setCategory(.playAndRecord, mode: .default, options: options)
        requestEchoCancellationIfAvailable()
        try audio.setActive(true)
        isMonitoring = true
        // Capabilities can become available only once the input route is active.
        requestEchoCancellationIfAvailable()
    }

    /// Also used after attaching capture input and on route changes. Never
    /// deactivates I/O, selects an input, or changes the microphone's timebase.
    @discardableResult
    func verifyEchoCancellation() async -> StudioMicrophoneSnapshot {
        let id = UUID()
        verificationID = id
        for attempt in 0..<4 {
            guard isMonitoring, verificationID == id, !Task.isCancelled else { break }
            requestEchoCancellationIfAvailable()
            let state = snapshot
            if state.echoCancellationEnabled || (!state.outputs.isEmpty && !state.usesSpeaker) { break }
            if attempt < 3 {
                do { try await Task.sleep(for: .milliseconds(80)) }
                catch { break }
            }
        }
        return snapshot
    }

    func stopMonitoring() {
        isMonitoring = false
        verificationID = UUID()
    }

    private func requestEchoCancellationIfAvailable() {
        let state = snapshot
        guard state.echoCancellationAvailable, !state.echoCancellationEnabled else { return }
        do { try audio.setPrefersEchoCancelledInput(true) }
        catch {
            let message = error.localizedDescription
            if !configurationErrors.contains(message) { configurationErrors.append(message) }
        }
    }
}

struct StudioMicrophoneSnapshot: Codable, Equatable, Sendable {
    var category: String
    var mode: String
    var categoryOptions: UInt
    var inputs: [String]
    var outputs: [String]
    var sampleRate: Double
    var inputChannels: Int
    var outputChannels: Int
    var echoCancellationAvailable: Bool
    var prefersEchoCancellation: Bool
    var echoCancellationEnabled: Bool
    var preferredMicrophoneMode: Int
    var activeMicrophoneMode: Int
    var bluetoothHighQualitySupported: Bool? = nil
    var bluetoothHighQualityEnabled: Bool? = nil

    var usesSpeaker: Bool { outputs.contains(AVAudioSession.Port.builtInSpeaker.rawValue) }
    var needsHeadphonesGuidance: Bool { usesSpeaker && !echoCancellationEnabled }
}

/// A narrow seam for verifying route timing without opening a microphone.
@MainActor
protocol StudioAudioSessionControlling {
    var snapshot: StudioMicrophoneSnapshot { get }
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool) throws
    func setPrefersEchoCancelledInput(_ value: Bool) throws
}

@MainActor
private final class SystemStudioAudioSession: StudioAudioSessionControlling {
    private let session = AVAudioSession.sharedInstance()

    var snapshot: StudioMicrophoneSnapshot {
        let bluetooth = session.currentRoute.inputs.compactMap { $0.bluetoothMicrophoneExtension }.first
        return StudioMicrophoneSnapshot(category: session.category.rawValue, mode: session.mode.rawValue,
            categoryOptions: session.categoryOptions.rawValue,
            inputs: session.currentRoute.inputs.map { $0.portType.rawValue },
            outputs: session.currentRoute.outputs.map { $0.portType.rawValue },
            sampleRate: session.sampleRate, inputChannels: session.inputNumberOfChannels,
            outputChannels: session.outputNumberOfChannels,
            echoCancellationAvailable: session.isEchoCancelledInputAvailable,
            prefersEchoCancellation: session.prefersEchoCancelledInput,
            echoCancellationEnabled: session.isEchoCancelledInputEnabled,
            preferredMicrophoneMode: AVCaptureDevice.preferredMicrophoneMode.rawValue,
            activeMicrophoneMode: AVCaptureDevice.activeMicrophoneMode.rawValue,
            bluetoothHighQualitySupported: bluetooth?.highQualityRecording.isSupported,
            bluetoothHighQualityEnabled: bluetooth?.highQualityRecording.isEnabled)
    }

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws {
        try session.setCategory(category, mode: mode, options: options)
    }

    func setActive(_ active: Bool) throws { try session.setActive(active) }
    func setPrefersEchoCancelledInput(_ value: Bool) throws {
        try session.setPrefersEchoCancelledInput(value)
    }
}
