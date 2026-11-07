import AVFoundation
import XCTest
@testable import Roast

@MainActor
final class StudioMicrophoneSessionTests: XCTestCase {
    func testAvailabilityAppearingAfterActivationStillEnablesEchoCancellation() throws {
        let audio = FakeStudioAudioSession()
        audio.availableWhenActivated = true
        let microphone = StudioMicrophoneSession(audio: audio)
        try microphone.configureForRecording()

        XCTAssertEqual(audio.events, ["category", "activate", "preferEcho"])
        XCTAssertTrue(microphone.snapshot.echoCancellationEnabled)
        XCTAssertEqual(audio.category, .playAndRecord)
        XCTAssertEqual(audio.mode, .default)
        XCTAssertFalse(audio.options.contains(.mixWithOthers))
        XCTAssertTrue(audio.options.contains(.allowBluetoothHFP))
        XCTAssertTrue(audio.options.contains(.allowBluetoothA2DP))
        #if os(iOS) && !targetEnvironment(macCatalyst)
        XCTAssertTrue(audio.options.contains(.bluetoothHighQualityRecording))
        #endif
    }

    func testInputRouteBecomingAvailableAfterCaptureAttachesGetsRetried() async throws {
        let audio = FakeStudioAudioSession()
        let microphone = StudioMicrophoneSession(audio: audio)
        try microphone.configureForRecording()
        XCTAssertFalse(microphone.snapshot.echoCancellationEnabled)

        audio.state.echoCancellationAvailable = true
        let verified = await microphone.verifyEchoCancellation()
        XCTAssertTrue(verified.echoCancellationEnabled)
        XCTAssertEqual(audio.events.filter { $0 == "preferEcho" }.count, 1)
    }

    func testPreferenceErrorBeforeActivationIsRecordedAndRetriedAfterActivation() throws {
        let audio = FakeStudioAudioSession()
        audio.state.echoCancellationAvailable = true
        audio.rejectPreferenceUntilActive = true
        let microphone = StudioMicrophoneSession(audio: audio)
        try microphone.configureForRecording()

        XCTAssertEqual(audio.events, ["category", "preferEcho", "activate", "preferEcho"])
        XCTAssertTrue(microphone.snapshot.echoCancellationEnabled)
        XCTAssertEqual(microphone.configurationErrors.count, 1)
    }

    func testRouteChangeRetriesEvenWhenPreferenceIsAlreadyTrue() async throws {
        let audio = FakeStudioAudioSession()
        audio.availableWhenActivated = true
        let microphone = StudioMicrophoneSession(audio: audio)
        try microphone.configureForRecording()
        let initialRequests = audio.events.filter { $0 == "preferEcho" }.count
        audio.state.echoCancellationEnabled = false
        XCTAssertTrue(audio.state.prefersEchoCancellation)

        let verified = await microphone.verifyEchoCancellation()
        XCTAssertTrue(verified.echoCancellationEnabled)
        XCTAssertEqual(audio.events.filter { $0 == "preferEcho" }.count, initialRequests + 1)
        XCTAssertEqual(audio.events.filter { $0 == "activate" }.count, 1,
                       "A route retry must not restart or deactivate capture I/O.")
    }

    func testUnsupportedSpeakerReportsGuidanceWithoutClaimingCancellation() async throws {
        let audio = FakeStudioAudioSession()
        let microphone = StudioMicrophoneSession(audio: audio)
        try microphone.configureForRecording()
        let verified = await microphone.verifyEchoCancellation()
        XCTAssertFalse(verified.echoCancellationEnabled)
        XCTAssertTrue(verified.needsHeadphonesGuidance)
        XCTAssertFalse(audio.events.contains("preferEcho"))
    }

    func testExternalHeadphoneRouteIsPreservedAndDoesNotGetSpeakerGuidance() async throws {
        let audio = FakeStudioAudioSession()
        audio.state.inputs = [AVAudioSession.Port.bluetoothHFP.rawValue]
        audio.state.outputs = [AVAudioSession.Port.bluetoothHFP.rawValue]
        let microphone = StudioMicrophoneSession(audio: audio)
        try microphone.configureForRecording()
        let verified = await microphone.verifyEchoCancellation()
        XCTAssertEqual(verified.inputs, [AVAudioSession.Port.bluetoothHFP.rawValue])
        XCTAssertEqual(verified.outputs, [AVAudioSession.Port.bluetoothHFP.rawValue])
        XCTAssertFalse(verified.needsHeadphonesGuidance)
        XCTAssertFalse(audio.events.contains("preferEcho"))
    }

    func testStoppingMonitoringInvalidatesPendingRouteRetries() async throws {
        let audio = FakeStudioAudioSession()
        audio.availableWhenActivated = true
        audio.honorPreference = false
        let microphone = StudioMicrophoneSession(audio: audio)
        try microphone.configureForRecording()
        let initialRequests = audio.events.filter { $0 == "preferEcho" }.count
        let task = Task { @MainActor in await microphone.verifyEchoCancellation() }
        for _ in 0..<100 {
            if audio.events.filter({ $0 == "preferEcho" }).count > initialRequests { break }
            await Task.yield()
        }
        XCTAssertGreaterThan(audio.events.filter { $0 == "preferEcho" }.count, initialRequests)
        microphone.stopMonitoring()
        let requestsAtStop = audio.events.filter { $0 == "preferEcho" }.count
        _ = await task.value
        XCTAssertEqual(audio.events.filter { $0 == "preferEcho" }.count, requestsAtStop)
    }

    func testActivationFailurePropagatesAndCannotStartMonitoring() async {
        let audio = FakeStudioAudioSession()
        audio.rejectActivation = true
        let microphone = StudioMicrophoneSession(audio: audio)
        XCTAssertThrowsError(try microphone.configureForRecording())
        audio.state.echoCancellationAvailable = true
        let before = audio.events
        _ = await microphone.verifyEchoCancellation()
        XCTAssertEqual(audio.events, before)
    }
}

@MainActor
private final class FakeStudioAudioSession: StudioAudioSessionControlling {
    var state = StudioMicrophoneSnapshot(category: AVAudioSession.Category.playback.rawValue,
        mode: AVAudioSession.Mode.moviePlayback.rawValue, categoryOptions: 0,
        inputs: [AVAudioSession.Port.builtInMic.rawValue], outputs: [AVAudioSession.Port.builtInSpeaker.rawValue],
        sampleRate: 48_000, inputChannels: 1, outputChannels: 2,
        echoCancellationAvailable: false, prefersEchoCancellation: false, echoCancellationEnabled: false,
        preferredMicrophoneMode: 0, activeMicrophoneMode: 0)
    var events: [String] = []
    var category: AVAudioSession.Category?
    var mode: AVAudioSession.Mode?
    var options: AVAudioSession.CategoryOptions = []
    var availableWhenActivated = false
    var rejectPreferenceUntilActive = false
    var rejectActivation = false
    var honorPreference = true
    private var active = false
    var snapshot: StudioMicrophoneSnapshot { state }

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws {
        events.append("category")
        self.category = category
        self.mode = mode
        self.options = options
        state.category = category.rawValue
        state.mode = mode.rawValue
        state.categoryOptions = options.rawValue
    }

    func setActive(_ active: Bool) throws {
        events.append(active ? "activate" : "deactivate")
        if rejectActivation { throw TestError.unavailable }
        self.active = active
        if availableWhenActivated { state.echoCancellationAvailable = active }
    }

    func setPrefersEchoCancelledInput(_ value: Bool) throws {
        events.append("preferEcho")
        if rejectPreferenceUntilActive && !active { throw TestError.unavailable }
        state.prefersEchoCancellation = value
        if active && honorPreference { state.echoCancellationEnabled = value }
    }

    private enum TestError: Error { case unavailable }
}
