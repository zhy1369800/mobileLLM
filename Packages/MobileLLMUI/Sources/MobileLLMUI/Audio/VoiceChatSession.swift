// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import Observation
import Speech

/// State machine for full-duplex real-time voice conversation mode.
public enum VoiceChatState: Equatable, Sendable {
    case idle
    case listening
    case thinking
    case speaking
    case denied
    case unavailable
}

/// Coordinates full-duplex voice conversation:
/// 1. Configures `.playAndRecord` + `.voiceChat` with hardware voice processing (AEC) on iOS.
/// 2. Runs on-device `SFSpeechRecognizer` with silence-timeout endpointing and generation-guarded renewal.
/// 3. Dispatches clean voice turns via `ChatStore.sendVoiceMessage` without touching composer drafts.
/// 4. Streams LLM output & tool status to `StreamingSpeechCoordinator`, supporting zero-IPC barge-in.
@MainActor
@Observable
public final class VoiceChatSession {
    public private(set) var state: VoiceChatState = .idle
    public private(set) var liveUserTranscript: String = ""
    public private(set) var liveAssistantText: String = ""
    public private(set) var activeToolRuns: [ToolRun] = []

    public var isActive: Bool {
        switch state {
        case .listening, .thinking, .speaking:
            return true
        case .idle, .denied, .unavailable:
            return false
        }
    }

    private let chat: ChatStore
    private let speech: StreamingSpeechCoordinator
    private let settings: AppSettings

    @ObservationIgnored private let audioLevelBox = AudioLevelBox()
    @ObservationIgnored private let tapBridge = AudioTapBridge()

    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?

    @ObservationIgnored private var silenceSubmitTask: Task<Void, Never>?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var renewalTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var sessionToken: UInt64 = 0
    @ObservationIgnored private var recognitionGeneration: UInt64 = 0
    @ObservationIgnored private var consecutiveRenewalFailures: Int = 0
    @ObservationIgnored private var isRestartingEngine = false
    @ObservationIgnored nonisolated(unsafe) private var audioObservers: [NSObjectProtocol] = []

    /// Silence duration after user stops speaking before auto-submitting the transcript.
    private let silenceSubmitDelay: Duration = .milliseconds(1350)

    public init(chat: ChatStore, speech: StreamingSpeechCoordinator, settings: AppSettings) {
        self.chat = chat
        self.speech = speech
        self.settings = settings
    }

    deinit {
        for observer in audioObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Thread-safe, non-observable audio level accessor for 30fps Canvas rendering without triggering SwiftUI body diffs.
    public nonisolated func currentAudioLevel() -> Float {
        audioLevelBox.get()
    }

    /// Starts a full-duplex voice chat session (requests speech & mic permissions if needed).
    public func start() {
        guard !isActive else { return }
        sessionToken &+= 1
        let token = sessionToken

        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor [weak self] in
                guard let self, self.sessionToken == token else { return }
                guard auth == .authorized else {
                    self.state = .denied
                    return
                }
                self.requestMicrophoneThenStart(token: token)
            }
        }
    }

    /// Stops the voice chat session, halting any active recognition, generation, or speech playback,
    /// and cleanly restoring the system audio session for normal chat TTS.
    public func stop() {
        sessionToken &+= 1
        cancelPendingTasks()
        removeAudioObservers()

        teardownRecognition()
        teardownAudioEngine()

        speech.isVoiceCallActive = false
        speech.onPlaybackFinished = nil
        speech.stop(suppressCurrentTurn: true)

        if chat.streaming != nil {
            chat.stop()
        }

        restoreAudioSessionAfterCall()

        state = .idle
        audioLevelBox.set(0)
        liveUserTranscript = ""
        liveAssistantText = ""
        activeToolRuns = []
        consecutiveRenewalFailures = 0
        tapBridge.setSpeaking(false)
    }

    /// Interrupts current thinking or speaking and immediately switches back to listening.
    /// Used both for manual orb tap-to-interrupt and automatic voice barge-in.
    public func interruptAndListen() {
        guard isActive else { return }
        guard state == .thinking || state == .speaking else { return }

        observationTask?.cancel()
        observationTask = nil
        sendTask?.cancel()
        sendTask = nil
        tapBridge.setSpeaking(false)
        speech.stop(suppressCurrentTurn: true)
        if chat.streaming != nil {
            chat.stop()
        }

        beginListening()
    }

    // MARK: - Permissions & Audio Setup

    private func requestMicrophoneThenStart(token: UInt64) {
        #if os(iOS)
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self, self.sessionToken == token else { return }
                guard granted else {
                    self.state = .denied
                    return
                }
                self.activateSessionAndListen()
            }
        }
        #else
        activateSessionAndListen()
        #endif
    }

    private func activateSessionAndListen() {
        if chat.activeID == nil {
            _ = chat.newConversation()
        }

        guard let engine = setupAudioSessionAndEngine() else {
            cleanupOnFailure(to: .unavailable)
            return
        }
        // Install observers AFTER `setVoiceProcessingEnabled` + `engine.start()` so initial VPIO setup
        // does not trigger a configuration-change restart storm.
        installAudioObservers(for: engine)
        refreshBargeInThresholds()

        speech.isVoiceCallActive = true
        speech.onPlaybackFinished = { [weak self] in
            guard let self, self.isActive, self.state == .speaking else { return }
            if self.chat.streaming == nil {
                self.beginListening()
            }
        }

        liveAssistantText = ""
        activeToolRuns = []
        consecutiveRenewalFailures = 0
        beginListening()
    }

    private func setupAudioSessionAndEngine() -> AVAudioEngine? {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return nil
        }
        #endif

        let engine = AVAudioEngine()
        let input = engine.inputNode
        #if os(iOS)
        // Enable hardware voice processing (AEC + noise suppression) on iOS;
        // macOS split input/output devices can throw -10875 on VPIO.
        try? input.setVoiceProcessingEnabled(true)
        #endif

        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            return nil
        }

        let token = sessionToken
        let bridge = tapBridge
        let levelBox = audioLevelBox
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            bridge.appendIfActive(buffer)
            let level = Self.computeNormalizedRMS(from: buffer)

            if bridge.recordAndCheckBargeIn(level: level) {
                Task { @MainActor [weak self] in
                    guard let self, self.sessionToken == token else { return }
                    self.interruptAndListen()
                }
            } else if !bridge.isCurrentlySpeaking() {
                // During `.speaking`, the 75ms observation loop drives the speech pulse;
                // avoid fighting it with mic silence.
                let prev = levelBox.get()
                levelBox.set(prev * 0.55 + level * 0.45)
            }
        }

        engine.prepare()
        do {
            try engine.start()
            self.audioEngine = engine
            return engine
        } catch {
            input.removeTap(onBus: 0)
            return nil
        }
    }

    private func teardownAudioEngine() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
    }

    private func restoreAudioSessionAfterCall() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func cleanupOnFailure(to failureState: VoiceChatState) {
        sessionToken &+= 1
        cancelPendingTasks()
        removeAudioObservers()
        teardownRecognition()
        teardownAudioEngine()
        tapBridge.setSpeaking(false)
        speech.isVoiceCallActive = false
        speech.onPlaybackFinished = nil
        restoreAudioSessionAfterCall()
        audioLevelBox.set(0)
        state = failureState
    }

    private func cancelPendingTasks() {
        silenceSubmitTask?.cancel()
        silenceSubmitTask = nil
        observationTask?.cancel()
        observationTask = nil
        renewalTask?.cancel()
        renewalTask = nil
        sendTask?.cancel()
        sendTask = nil
    }

    // MARK: - Audio Session & Route Observers

    private func installAudioObservers(for engine: AVAudioEngine) {
        removeAudioObservers()
        let center = NotificationCenter.default

        #if os(iOS)
        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let typeRaw, AVAudioSession.InterruptionType(rawValue: typeRaw) == .began else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                self.stop()
            }
        }

        let routeChange = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = reasonRaw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
            Task { @MainActor [weak self] in
                self?.refreshBargeInThresholds()
                self?.restartEngineAfterRouteChange()
            }
        }
        audioObservers = [interruption, routeChange]
        #endif

        let configChange = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartEngineAfterRouteChange()
            }
        }
        audioObservers.append(configChange)
    }

    private func removeAudioObservers() {
        for observer in audioObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        audioObservers.removeAll()
    }

    private func restartEngineAfterRouteChange() {
        guard isActive, !isRestartingEngine else { return }
        isRestartingEngine = true
        defer { isRestartingEngine = false }

        removeAudioObservers()
        teardownRecognition()
        teardownAudioEngine()
        guard let engine = setupAudioSessionAndEngine() else {
            cleanupOnFailure(to: .unavailable)
            return
        }
        installAudioObservers(for: engine)
        refreshBargeInThresholds()
        if state == .listening {
            beginListening()
        }
    }

    private func refreshBargeInThresholds() {
        let usingHeadphones = Self.isUsingHeadphones()
        tapBridge.configureBargeIn(
            threshold: usingHeadphones ? 0.34 : 0.58,
            requiredHits: usingHeadphones ? 8 : 16
        )
    }

    // MARK: - Listening & VAD Endpointing

    private func beginListening() {
        guard sessionToken != 0 else { return }
        teardownRecognition()
        silenceSubmitTask?.cancel()
        silenceSubmitTask = nil
        renewalTask?.cancel()
        renewalTask = nil
        tapBridge.setSpeaking(false)
        liveUserTranscript = ""
        activeToolRuns = []

        let locale = settings.dictationLocale.flatMap { Locale(identifier: $0) }
        let rec = locale.flatMap { SFSpeechRecognizer(locale: $0) } ?? SFSpeechRecognizer()
        guard let rec, rec.isAvailable else {
            cleanupOnFailure(to: .unavailable)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        recognitionGeneration &+= 1
        let recGen = recognitionGeneration
        let token = sessionToken

        self.recognizer = rec
        self.recognitionRequest = request
        self.tapBridge.setActiveRequest(request)
        self.state = .listening

        self.recognitionTask = rec.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let hasError = error != nil

            Task { @MainActor [weak self] in
                guard let self,
                      self.sessionToken == token,
                      self.recognitionGeneration == recGen,
                      self.state == .listening
                else { return }

                if let text {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        self.consecutiveRenewalFailures = 0
                        self.liveUserTranscript = trimmed
                        self.scheduleSilenceSubmit(token: token, recGen: recGen)
                    }
                }
                if isFinal || hasError {
                    let candidate = self.liveUserTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !candidate.isEmpty {
                        self.consecutiveRenewalFailures = 0
                        self.submitTranscript(candidate)
                    } else if hasError {
                        self.consecutiveRenewalFailures += 1
                        if self.consecutiveRenewalFailures >= 3 {
                            self.cleanupOnFailure(to: .unavailable)
                        } else {
                            self.scheduleRecognitionRenewal(token: token, recGen: recGen)
                        }
                    } else {
                        // Clean ~60s timeout with no speech: renew seamlessly.
                        self.consecutiveRenewalFailures = 0
                        self.scheduleRecognitionRenewal(token: token, recGen: recGen)
                    }
                }
            }
        }
    }

    private func scheduleRecognitionRenewal(token: UInt64, recGen: UInt64) {
        renewalTask?.cancel()
        renewalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled,
                  let self,
                  self.sessionToken == token,
                  self.recognitionGeneration == recGen,
                  self.state == .listening
            else { return }
            self.beginListening()
        }
    }

    private func teardownRecognition() {
        recognitionGeneration &+= 1
        tapBridge.setActiveRequest(nil)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func scheduleSilenceSubmit(token: UInt64, recGen: UInt64) {
        silenceSubmitTask?.cancel()
        let delay = silenceSubmitDelay
        silenceSubmitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled,
                  let self,
                  self.sessionToken == token,
                  self.recognitionGeneration == recGen,
                  self.state == .listening
            else { return }
            let text = self.liveUserTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            self.submitTranscript(text)
        }
    }

    private func submitTranscript(_ text: String) {
        silenceSubmitTask?.cancel()
        silenceSubmitTask = nil
        renewalTask?.cancel()
        renewalTask = nil
        teardownRecognition()

        guard chat.hasModel else {
            liveUserTranscript = ""
            beginListening()
            return
        }

        state = .thinking
        liveAssistantText = ""
        activeToolRuns = []
        tapBridge.setSpeaking(false)

        let token = sessionToken
        sendTask?.cancel()
        sendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<20 where self.chat.streaming != nil {
                guard !Task.isCancelled, self.sessionToken == token, self.isActive else { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, self.sessionToken == token, self.isActive else { return }

            guard self.chat.sendVoiceMessage(text) else {
                self.beginListening()
                return
            }
            self.startObservingGeneration(token: token)
        }
    }

    // MARK: - Generation & Playback Observation

    private func startObservingGeneration(token: UInt64) {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()

            while !Task.isCancelled, self.sessionToken == token, self.isActive {
                if let streaming = self.chat.streaming {
                    if self.activeToolRuns != streaming.toolActivity {
                        self.activeToolRuns = streaming.toolActivity
                    }
                    if !streaming.answer.isEmpty && self.liveAssistantText != streaming.answer {
                        self.liveAssistantText = streaming.answer
                    }
                    if self.speech.isSpeaking && self.state != .speaking {
                        self.enterSpeakingState()
                    }
                } else if self.speech.isSpeaking {
                    if self.state != .speaking {
                        self.enterSpeakingState()
                    }
                    if !self.speech.currentSpokenSentence.isEmpty && self.liveAssistantText.isEmpty {
                        self.liveAssistantText = self.speech.currentSpokenSentence
                    }
                } else {
                    if self.state == .thinking || self.state == .speaking {
                        self.beginListening()
                    }
                    break
                }

                if self.state == .speaking {
                    let pulse = Float.random(in: 0.25...0.72)
                    self.audioLevelBox.set(self.audioLevelBox.get() * 0.55 + pulse * 0.45)
                }

                try? await Task.sleep(for: .milliseconds(75))
            }
        }
    }

    private func enterSpeakingState() {
        state = .speaking
        tapBridge.setSpeaking(true)
    }

    // MARK: - Helpers

    private nonisolated static func isUsingHeadphones() -> Bool {
        #if os(iOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains { out in
            switch out.portType {
            case .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio:
                return true
            default:
                return false
            }
        }
        #else
        return false
        #endif
    }

    private nonisolated static func computeNormalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))
        let db = 20 * log10(max(rms, 1e-6))
        let normalized = (db + 52) / 44
        return min(max(normalized, 0), 1)
    }
}

private final class AudioTapBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var activeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var isSpeaking = false
    private var bargeInThreshold: Float = 0.58
    private var bargeInRequiredHits = 16
    private var bargeInHits = 0

    func setActiveRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        activeRequest = request
        lock.unlock()
    }

    func setSpeaking(_ speaking: Bool) {
        lock.lock()
        isSpeaking = speaking
        bargeInHits = 0
        lock.unlock()
    }

    func isCurrentlySpeaking() -> Bool {
        lock.lock()
        let v = isSpeaking
        lock.unlock()
        return v
    }

    func configureBargeIn(threshold: Float, requiredHits: Int) {
        lock.lock()
        bargeInThreshold = threshold
        bargeInRequiredHits = requiredHits
        bargeInHits = 0
        lock.unlock()
    }

    func appendIfActive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = activeRequest
        lock.unlock()
        request?.append(buffer)
    }

    /// Evaluates barge-in directly on the audio callback thread so MainActor is only hopped once when triggered.
    func recordAndCheckBargeIn(level: Float) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isSpeaking else { return false }
        if level >= bargeInThreshold {
            bargeInHits += 1
            if bargeInHits >= bargeInRequiredHits {
                bargeInHits = 0
                isSpeaking = false
                return true
            }
        } else {
            bargeInHits = max(0, bargeInHits - 1)
        }
        return false
    }
}

private final class AudioLevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0

    func get() -> Float {
        lock.lock()
        let v = value
        lock.unlock()
        return v
    }

    func set(_ newValue: Float) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
