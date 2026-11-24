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
    public private(set) var isVerifyingBargeInKeyword: Bool = false

    /// The sentence batch currently being spoken by TTS (empty outside active playback).
    public var currentSpokenSentence: String {
        speech.currentSpokenSentence
    }

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
    @ObservationIgnored private let playbackController: EnginePlaybackController

    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var activePlayerNode: AVAudioPlayerNode?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var keywordRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var keywordRecognitionTask: SFSpeechRecognitionTask?

    @ObservationIgnored private var silenceSubmitTask: Task<Void, Never>?
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var renewalTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var configRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var routeRestartTask: Task<Void, Never>?
    @ObservationIgnored private var keywordWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var sessionToken: UInt64 = 0
    @ObservationIgnored private var recognitionGeneration: UInt64 = 0
    @ObservationIgnored private var keywordVerificationGeneration: UInt64 = 0
    @ObservationIgnored private var consecutiveRenewalFailures: Int = 0
    @ObservationIgnored private var consecutiveConfigRecoveries: Int = 0
    @ObservationIgnored private var isRestartingEngine = false
    @ObservationIgnored private var isHardwareAECEnabled = false
    @ObservationIgnored private var lastPublishedLiveActivity: VoiceLiveActivitySnapshot?
    @ObservationIgnored private var lastRawLiveActivityKey: RawLiveActivityKey?
    @ObservationIgnored nonisolated(unsafe) private var audioObservers: [NSObjectProtocol] = []

    private struct RawLiveActivityKey: Equatable {
        let state: VoiceChatState
        let rawSubtitle: String
        let toolName: String?
        let toolRunning: Bool
        let modelName: String
    }

    @ObservationIgnored public var isScreenVisible = false {
        didSet {
            guard isScreenVisible != oldValue else { return }
            onScreenVisibilityChanged?(isScreenVisible)
        }
    }
    /// Optional Live Activity bridge for iOS Dynamic Island & Lock Screen presentation.
    public var liveActivity: (any VoiceLiveActivityProviding)?
    /// Invoked once the voice session has started and is actively listening (e.g. to dismiss chat banners/PiP).
    public var onSessionActivated: (@MainActor () -> Void)?
    /// Invoked after the voice session stops cleanly (e.g. to suspend idle local weights if still backgrounded).
    public var onSessionStopped: (@MainActor () -> Void)?
    /// Invoked when the voice chat screen appears or disappears so the host app can suppress/restore PiP.
    public var onScreenVisibilityChanged: (@MainActor (Bool) -> Void)?

    /// Silence duration after user stops speaking before auto-submitting the transcript.
    private let silenceSubmitDelay: Duration = .milliseconds(1350)
    private let keywordMinListenDuration: Double = 0.70
    private let keywordSilenceEndDuration: Double = 0.55
    private let keywordFinalGraceDuration: Double = 0.25
    private let keywordMaxDuration: Double = 2.20

    public init(chat: ChatStore, speech: StreamingSpeechCoordinator, settings: AppSettings) {
        self.chat = chat
        self.speech = speech
        self.settings = settings
        self.playbackController = EnginePlaybackController(levelBox: audioLevelBox)
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

        speech.externalOutputSink = nil
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
        consecutiveConfigRecoveries = 0
        lastPublishedLiveActivity = nil
        lastRawLiveActivityKey = nil
        tapBridge.setSamplingAmbient(false)
        tapBridge.setSpeaking(false)
        playbackController.setDucked(false)
        liveActivity?.end()
        onSessionStopped?()
    }

    /// Interrupts current thinking or speaking and immediately switches back to listening.
    /// Used both for manual orb tap-to-interrupt and automatic voice barge-in.
    public func interruptAndListen() {
        guard isActive else { return }
        guard state == .thinking || state == .speaking else { return }

        teardownKeywordVerification(completeWithMatch: true, restorePlayback: false)
        observationTask?.cancel()
        observationTask = nil
        sendTask?.cancel()
        sendTask = nil
        tapBridge.setSamplingAmbient(false)
        tapBridge.setSpeaking(false)
        speech.stop(suppressCurrentTurn: true)
        playbackController.setDucked(false)
        if chat.streaming != nil {
            chat.stop()
        }

        beginListening()
    }

    /// Immediately submits the current live user transcript while listening, bypassing the silence timer.
    public func submitCurrentTranscriptNow() {
        guard isActive, state == .listening else { return }
        let text = liveUserTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        submitTranscript(text)
    }

    /// Discards the current partial user transcript and restarts speech recognition cleanly.
    public func restartListening() {
        guard isActive, state == .listening else { return }
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

        // Notify the host app BEFORE configuring AVAudioSession so PiPCoordinator releases its
        // audio session claim first instead of deactivating the newly started voice session.
        onSessionActivated?()
        speech.prewarmForVoiceCall()

        guard let engine = setupAudioSessionAndEngine() else {
            cleanupOnFailure(to: .unavailable)
            return
        }
        // Install observers AFTER `setVoiceProcessingEnabled` + `engine.start()` so initial VPIO setup
        // does not trigger a configuration-change restart storm.
        installAudioObservers(for: engine)
        refreshBargeInThresholds()

        speech.isVoiceCallActive = true
        speech.externalOutputSink = playbackController
        speech.onPlaybackFinished = { [weak self] in
            guard let self, self.isActive, self.state == .speaking else { return }
            if self.chat.streaming == nil {
                self.beginListening()
            }
        }

        liveAssistantText = ""
        activeToolRuns = []
        consecutiveRenewalFailures = 0
        consecutiveConfigRecoveries = 0
        lastPublishedLiveActivity = nil
        lastRawLiveActivityKey = nil
        beginListening()
        guard isActive else { return }
        publishLiveActivity(isStart: true)
    }

    private func setupAudioSessionAndEngine() -> AVAudioEngine? {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .videoChat,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return nil
        }
        #endif

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let player = AVAudioPlayerNode()
        engine.attach(player)

        // Connect output graph first so VPIO activates full-duplex I/O negotiation cleanly.
        engine.connect(player, to: engine.mainMixerNode, format: nil)

        #if os(iOS)
        // Enable hardware voice processing (AEC + noise suppression) while the engine is stopped;
        // set minimum ducking so playback stays at full volume.
        var vpioEnabled = false
        do {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
            vpioEnabled = input.isVoiceProcessingEnabled
        } catch {
            vpioEnabled = false
        }
        self.isHardwareAECEnabled = vpioEnabled
        #else
        self.isHardwareAECEnabled = false
        #endif

        guard let playbackFormat = resolvePlaybackFormat(for: engine) else {
            return nil
        }
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        guard installMicrophoneTap(on: engine) else {
            return nil
        }

        engine.prepare()
        do {
            try engine.start()
            player.play()
            playbackController.attach(player: player, format: playbackFormat)
            tapBridge.resetCalibration()
            self.audioEngine = engine
            self.activePlayerNode = player
            return engine
        } catch {
            playbackController.detach()
            input.removeTap(onBus: 0)
            return nil
        }
    }

    private func resolvePlaybackFormat(for engine: AVAudioEngine) -> AVAudioFormat? {
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        if mixerFormat.channelCount > 0 && mixerFormat.sampleRate > 0 {
            return mixerFormat
        }
        return AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
    }

    private func installMicrophoneTap(on engine: AVAudioEngine) -> Bool {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            return false
        }

        input.removeTap(onBus: 0)
        let token = sessionToken
        let bridge = tapBridge
        let playback = playbackController
        let levelBox = audioLevelBox
        // Pass `format: nil` so CoreAudio binds cleanly to the VPIO node's live output format.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            bridge.appendIfActive(buffer)
            let bufferDuration = Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)

            if bridge.isCurrentlySpeaking() {
                let farEndLevel = playback.currentPlaybackLevel
                let action = bridge.processSpeakingFrame(
                    buffer: buffer,
                    duration: bufferDuration,
                    farEndLevel: farEndLevel
                )
                switch action {
                case .none:
                    break
                case .duckPlayback:
                    playback.setDucked(true)
                case .restorePlayback:
                    playback.setDucked(false)
                case .confirmInterrupt:
                    playback.muteForInterrupt()
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionToken == token else { return }
                        self.interruptAndListen()
                    }
                case .beginKeywordVerification:
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionToken == token else { return }
                        self.beginKeywordVerification()
                    }
                }
            } else {
                let rawLevel = Self.computeNormalizedRMS(from: buffer)
                bridge.sampleAmbientIfNeeded(buffer: buffer)
                let prev = levelBox.get()
                levelBox.set(prev * 0.55 + rawLevel * 0.45)
            }
        }
        return true
    }

    private func teardownAudioEngine() {
        playbackController.detach()
        activePlayerNode = nil
        isHardwareAECEnabled = false
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
        tapBridge.setSamplingAmbient(false)
        tapBridge.setSpeaking(false)
        playbackController.setDucked(false)
        speech.externalOutputSink = nil
        speech.isVoiceCallActive = false
        speech.onPlaybackFinished = nil
        restoreAudioSessionAfterCall()
        audioLevelBox.set(0)
        consecutiveConfigRecoveries = 0
        lastPublishedLiveActivity = nil
        lastRawLiveActivityKey = nil
        state = failureState
        liveActivity?.end()
        onSessionStopped?()
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
        configRecoveryTask?.cancel()
        configRecoveryTask = nil
        routeRestartTask?.cancel()
        routeRestartTask = nil
        keywordWatchdogTask?.cancel()
        keywordWatchdogTask = nil
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
                self?.scheduleRouteRestart()
            }
        }
        audioObservers = [interruption, routeChange]
        #endif

        let engineID = ObjectIdentifier(engine)
        let configChange = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let currentEngine = self.audioEngine,
                      ObjectIdentifier(currentEngine) == engineID,
                      !currentEngine.isRunning
                else {
                    return
                }
                self.scheduleConfigRecovery(for: currentEngine)
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

    /// Recovers the existing `AVAudioEngine` in-place after iOS VPIO finishes its initial
    /// duplex hardware format negotiation (or transient config pause), debouncing bursts by 120ms.
    private func scheduleConfigRecovery(for engine: AVAudioEngine) {
        configRecoveryTask?.cancel()
        let token = sessionToken
        let engineID = ObjectIdentifier(engine)
        configRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled,
                  let self,
                  self.sessionToken == token,
                  self.isActive,
                  let engine = self.audioEngine,
                  ObjectIdentifier(engine) == engineID,
                  !engine.isRunning
            else { return }

            guard self.consecutiveConfigRecoveries < 3 else {
                self.cleanupOnFailure(to: .unavailable)
                return
            }
            self.consecutiveConfigRecoveries += 1

            if self.isVerifyingBargeInKeyword {
                self.teardownKeywordVerification(completeWithMatch: false, restorePlayback: true)
            }

            if let player = self.activePlayerNode, let playbackFormat = self.resolvePlaybackFormat(for: engine) {
                engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
                self.playbackController.reattachForRecovery(player: player, format: playbackFormat)
            }

            guard self.installMicrophoneTap(on: engine) else {
                self.restartEngineAfterRouteChange()
                return
            }

            engine.prepare()
            do {
                try engine.start()
                self.activePlayerNode?.play()
                self.tapBridge.resetCalibration()
                #if os(iOS)
                self.isHardwareAECEnabled = engine.inputNode.isVoiceProcessingEnabled
                #endif
                self.refreshBargeInThresholds()
                if self.state == .listening {
                    self.beginListening()
                }
            } catch {
                self.restartEngineAfterRouteChange()
            }
        }
    }

    private func scheduleRouteRestart() {
        routeRestartTask?.cancel()
        let token = sessionToken
        routeRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, self.sessionToken == token, self.isActive else { return }
            self.restartEngineAfterRouteChange()
        }
    }

    private func restartEngineAfterRouteChange() {
        guard isActive, !isRestartingEngine else { return }
        isRestartingEngine = true
        defer { isRestartingEngine = false }

        configRecoveryTask?.cancel()
        configRecoveryTask = nil
        routeRestartTask?.cancel()
        routeRestartTask = nil

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

    public func refreshBargeInSettings() {
        refreshBargeInThresholds()
    }

    internal nonisolated static func resolveBargeInConfig(
        mode: VoiceBargeInMode,
        keywords: [String],
        isUsingHeadphones: Bool,
        isHardwareAECEnabled: Bool
    ) -> VoiceBargeInConfig {
        if mode == .keyword && keywords.isEmpty {
            return .disabled
        }
        let base: VoiceBargeInConfig
        if isUsingHeadphones {
            base = .headphones
        } else if isHardwareAECEnabled {
            base = .speakerWithHardwareAEC
        } else {
            base = .disabled
        }
        guard base.enabled else { return .disabled }
        return base.withKeywordVerification(mode == .keyword)
    }

    private func refreshBargeInThresholds() {
        let config: VoiceBargeInConfig
        #if os(iOS)
        config = Self.resolveBargeInConfig(
            mode: settings.voiceBargeInMode,
            keywords: settings.parsedVoiceBargeInKeywords,
            isUsingHeadphones: Self.isUsingHeadphones(),
            isHardwareAECEnabled: isHardwareAECEnabled
        )
        #else
        // macOS does not enable hardware VPIO AEC; disable voice barge-in to avoid speaker duck/restore pumping.
        config = .disabled
        #endif
        if !config.requiresKeywordVerification && isVerifyingBargeInKeyword {
            teardownKeywordVerification(completeWithMatch: nil, restorePlayback: true)
        }
        let wasDucked = tapBridge.configureBargeIn(config)
        if wasDucked {
            playbackController.setDucked(false)
        }
    }

    // MARK: - Listening & VAD Endpointing

    private func beginListening() {
        guard sessionToken != 0 else { return }
        teardownRecognition()
        silenceSubmitTask?.cancel()
        silenceSubmitTask = nil
        renewalTask?.cancel()
        renewalTask = nil
        tapBridge.setSamplingAmbient(false)
        tapBridge.setSpeaking(false)
        playbackController.setDucked(false)
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
        self.publishLiveActivity()

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
                        self.consecutiveConfigRecoveries = 0
                        self.liveUserTranscript = trimmed
                        self.publishLiveActivity()
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
        teardownKeywordVerification(completeWithMatch: nil, restorePlayback: false)
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
        playbackController.setDucked(false)
        tapBridge.setSamplingAmbient(true)
        publishLiveActivity()

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
                    let playbackLevel = self.playbackController.currentPlaybackLevel
                    if playbackLevel > 0.04 {
                        let visual = min(max(playbackLevel * 0.85, 0.18), 0.82)
                        self.audioLevelBox.set(self.audioLevelBox.get() * 0.50 + visual * 0.50)
                    } else {
                        self.audioLevelBox.set(self.audioLevelBox.get() * 0.6)
                    }
                }

                self.publishLiveActivity()
                try? await Task.sleep(for: .milliseconds(75))
            }
        }
    }

    private func enterSpeakingState() {
        state = .speaking
        tapBridge.setSamplingAmbient(false)
        refreshBargeInThresholds()
        tapBridge.setSpeaking(true)
        publishLiveActivity()
    }

    // MARK: - Keyword Barge-In Verification

    private func beginKeywordVerification() {
        guard isActive,
              state == .speaking,
              settings.voiceBargeInMode == .keyword else {
            abortKeywordVerificationAndRestore()
            return
        }

        let keywords = settings.parsedVoiceBargeInKeywords
        guard !keywords.isEmpty else {
            abortKeywordVerificationAndRestore()
            return
        }

        guard keywordRecognitionTask == nil else { return }

        let locale = settings.dictationLocale.flatMap { Locale(identifier: $0) }
        let rec = locale.flatMap { SFSpeechRecognizer(locale: $0) } ?? SFSpeechRecognizer()
        guard let rec, rec.isAvailable else {
            abortKeywordVerificationAndRestore()
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = keywords
        if rec.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        keywordVerificationGeneration &+= 1
        let kwGen = keywordVerificationGeneration
        let token = sessionToken

        keywordRecognitionRequest = request
        isVerifyingBargeInKeyword = true

        guard tapBridge.attachKeywordRequest(request) else {
            teardownKeywordVerification(completeWithMatch: nil, restorePlayback: false)
            return
        }

        keywordRecognitionTask = rec.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let hasError = error != nil

            Task { @MainActor [weak self] in
                guard let self,
                      self.sessionToken == token,
                      self.keywordVerificationGeneration == kwGen,
                      self.state == .speaking
                else { return }

                if let text,
                   !text.isEmpty,
                   VoiceBargeInKeywordMatcher.matches(transcript: text, keywords: keywords)
                {
                    self.playbackController.muteForInterrupt()
                    self.teardownKeywordVerification(completeWithMatch: true, restorePlayback: false)
                    self.interruptAndListen()
                    return
                }

                if isFinal || hasError {
                    self.finishKeywordVerificationWithoutMatch(generation: kwGen)
                }
            }
        }

        startKeywordWatchdog(token: token, generation: kwGen)
    }

    private func startKeywordWatchdog(token: UInt64, generation: UInt64) {
        keywordWatchdogTask?.cancel()
        let startUptime = ProcessInfo.processInfo.systemUptime
        keywordWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled,
                      let self,
                      self.sessionToken == token,
                      self.keywordVerificationGeneration == generation,
                      self.state == .speaking,
                      self.isVerifyingBargeInKeyword
                else { return }

                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = now - startUptime
                let silentFor = max(0, now - self.tapBridge.lastKeywordVoiceActivityUptime())

                if elapsed >= self.keywordMaxDuration
                    || (elapsed >= self.keywordMinListenDuration && silentFor >= self.keywordSilenceEndDuration)
                {
                    let req = self.keywordRecognitionRequest
                    self.tapBridge.detachKeywordRequest(req)
                    req?.endAudio()

                    let graceMs = Int((self.keywordFinalGraceDuration * 1000).rounded())
                    try? await Task.sleep(for: .milliseconds(graceMs))
                    guard !Task.isCancelled,
                          self.sessionToken == token,
                          self.keywordVerificationGeneration == generation,
                          self.state == .speaking,
                          self.isVerifyingBargeInKeyword
                    else { return }

                    self.finishKeywordVerificationWithoutMatch(generation: generation)
                    return
                }
            }
        }
    }

    private func finishKeywordVerificationWithoutMatch(generation: UInt64) {
        guard keywordVerificationGeneration == generation else { return }
        teardownKeywordVerification(completeWithMatch: false, restorePlayback: true)
    }

    private func abortKeywordVerificationAndRestore() {
        teardownKeywordVerification(completeWithMatch: false, restorePlayback: true)
    }

    private func teardownKeywordVerification(completeWithMatch matched: Bool?, restorePlayback: Bool) {
        keywordVerificationGeneration &+= 1
        keywordWatchdogTask?.cancel()
        keywordWatchdogTask = nil

        let req = keywordRecognitionRequest
        keywordRecognitionRequest = nil
        tapBridge.detachKeywordRequest(req)
        req?.endAudio()

        keywordRecognitionTask?.cancel()
        keywordRecognitionTask = nil
        if isVerifyingBargeInKeyword {
            isVerifyingBargeInKeyword = false
        }

        if let matched {
            _ = tapBridge.completeKeywordVerification(matched: matched)
        }
        if restorePlayback {
            playbackController.setDucked(false)
        }
    }

    private func makeLiveActivitySnapshot() -> VoiceLiveActivitySnapshot? {
        let phase: VoiceLiveActivityPhase
        let rawSubtitle: String
        switch state {
        case .listening:
            phase = .listening
            rawSubtitle = liveUserTranscript
        case .thinking:
            phase = .thinking
            rawSubtitle = liveAssistantText
        case .speaking:
            phase = .speaking
            let spoken = speech.currentSpokenSentence.trimmingCharacters(in: .whitespacesAndNewlines)
            rawSubtitle = spoken.isEmpty ? liveAssistantText : spoken
        case .idle, .denied, .unavailable:
            return nil
        }
        let latestTool = activeToolRuns.last
        return VoiceLiveActivitySnapshot(
            phase: phase,
            subtitle: rawSubtitle,
            toolName: latestTool?.name,
            toolRunning: latestTool != nil && latestTool?.result == nil,
            modelName: chat.activeModelLabel
        )
    }

    private func publishLiveActivity(isStart: Bool = false) {
        // Local models cannot submit Metal GPU commands in audio-only background mode, so Live Activity
        // background presentation is restricted to online models.
        guard let liveActivity else { return }
        guard chat.isOnlineActive else {
            if lastPublishedLiveActivity != nil || lastRawLiveActivityKey != nil {
                lastPublishedLiveActivity = nil
                lastRawLiveActivityKey = nil
                liveActivity.end()
            }
            return
        }
        let rawSubtitle: String
        switch state {
        case .listening:
            rawSubtitle = liveUserTranscript
        case .thinking:
            rawSubtitle = liveAssistantText
        case .speaking:
            let spoken = speech.currentSpokenSentence
            rawSubtitle = spoken.isEmpty ? liveAssistantText : spoken
        case .idle, .denied, .unavailable:
            return
        }

        let latestTool = activeToolRuns.last
        let toolName = latestTool?.name
        let toolRunning = latestTool != nil && latestTool?.result == nil
        let modelName = chat.activeModelLabel
        let rawKey = RawLiveActivityKey(
            state: state,
            rawSubtitle: rawSubtitle,
            toolName: toolName,
            toolRunning: toolRunning,
            modelName: modelName
        )
        if !isStart, rawKey == lastRawLiveActivityKey {
            return
        }
        lastRawLiveActivityKey = rawKey

        guard let snapshot = makeLiveActivitySnapshot() else { return }
        if !isStart, snapshot == lastPublishedLiveActivity {
            return
        }
        lastPublishedLiveActivity = snapshot
        if isStart {
            liveActivity.start(with: snapshot)
        } else {
            liveActivity.update(with: snapshot)
        }
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
            let safe = sample.isFinite ? sample : 0
            sum += safe * safe
        }
        let rms = sqrt(sum / Float(frameLength))
        return VoiceBargeInDetector.normalizeRMS(rms)
    }
}

private final class AudioTapBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var activeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var cachedMonoFormat: AVAudioFormat?
    private var detector = VoiceBargeInDetector(config: .speakerWithHardwareAEC)
    private var isSamplingAmbient = false
    private var hpfPrevInput: Float = 0
    private var hpfPrevOutput: Float = 0
    private var hpfSampleRate: Double = 0
    private var preRollBuffers: [(buffer: AVAudioPCMBuffer, duration: Double)] = []
    private var preRollDuration: Double = 0
    private var preRollSampleRate: Double = 0
    private var pendingPreRollBuffers: [AVAudioPCMBuffer] = []
    private var lastKeywordVoiceUptime: TimeInterval = 0
    private let maxPreRollDuration: Double = 0.70

    func setActiveRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        pendingPreRollBuffers.removeAll(keepingCapacity: false)
        activeRequest = request
        lock.unlock()
    }

    func resetCalibration() {
        lock.lock()
        detector.resetCalibration()
        hpfPrevInput = 0
        hpfPrevOutput = 0
        hpfSampleRate = 0
        preRollBuffers.removeAll(keepingCapacity: false)
        preRollDuration = 0
        preRollSampleRate = 0
        pendingPreRollBuffers.removeAll(keepingCapacity: false)
        lastKeywordVoiceUptime = 0
        lock.unlock()
    }

    func setSamplingAmbient(_ enabled: Bool) {
        lock.lock()
        isSamplingAmbient = enabled
        lock.unlock()
    }

    func setSpeaking(_ speaking: Bool) {
        lock.lock()
        _ = detector.setSpeaking(speaking)
        hpfPrevInput = 0
        hpfPrevOutput = 0
        if !speaking {
            preRollBuffers.removeAll(keepingCapacity: false)
            preRollDuration = 0
            preRollSampleRate = 0
            pendingPreRollBuffers.removeAll(keepingCapacity: false)
            lastKeywordVoiceUptime = 0
        }
        lock.unlock()
    }

    func isCurrentlySpeaking() -> Bool {
        lock.lock()
        let v = detector.isSpeaking
        lock.unlock()
        return v
    }

    @discardableResult
    func configureBargeIn(_ config: VoiceBargeInConfig) -> Bool {
        lock.lock()
        let wasDucked = detector.configure(config)
        if !config.enabled || !config.requiresKeywordVerification {
            preRollBuffers.removeAll(keepingCapacity: false)
            preRollDuration = 0
            preRollSampleRate = 0
            pendingPreRollBuffers.removeAll(keepingCapacity: false)
        }
        lock.unlock()
        return wasDucked
    }

    func attachKeywordRequest(_ request: SFSpeechAudioBufferRecognitionRequest) -> Bool {
        lock.lock()
        guard detector.isSpeaking && detector.isKeywordVerifying else {
            lock.unlock()
            return false
        }
        pendingPreRollBuffers = preRollBuffers.map(\.buffer)
        preRollBuffers.removeAll(keepingCapacity: true)
        preRollDuration = 0
        activeRequest = request
        lastKeywordVoiceUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        return true
    }

    func detachKeywordRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        guard let request else { return }
        lock.lock()
        if activeRequest === request {
            activeRequest = nil
            pendingPreRollBuffers.removeAll(keepingCapacity: false)
        }
        lock.unlock()
    }

    @discardableResult
    func completeKeywordVerification(matched: Bool) -> Bool {
        lock.lock()
        let changed = detector.completeKeywordVerification(matched: matched)
        pendingPreRollBuffers.removeAll(keepingCapacity: false)
        if matched {
            preRollBuffers.removeAll(keepingCapacity: false)
            preRollDuration = 0
        }
        lock.unlock()
        return changed
    }

    func lastKeywordVoiceActivityUptime() -> TimeInterval {
        lock.lock()
        let uptime = lastKeywordVoiceUptime
        lock.unlock()
        return uptime
    }

    func appendIfActive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = activeRequest
        let shouldRecordPreRoll = (request == nil)
            && detector.isSpeaking
            && detector.config.enabled
            && detector.config.requiresKeywordVerification
        var preRollToFlush: [AVAudioPCMBuffer] = []
        if request != nil && !pendingPreRollBuffers.isEmpty {
            preRollToFlush = pendingPreRollBuffers
            pendingPreRollBuffers.removeAll(keepingCapacity: false)
        }
        var monoFormat = cachedMonoFormat
        if buffer.format.sampleRate > 0 && (buffer.format.channelCount > 1 || shouldRecordPreRoll) {
            if monoFormat == nil || monoFormat?.sampleRate != buffer.format.sampleRate {
                monoFormat = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1)
                cachedMonoFormat = monoFormat
            }
        }
        lock.unlock()

        if let request, buffer.frameLength > 0 {
            for buffered in preRollToFlush {
                request.append(buffered)
            }
            if buffer.format.channelCount == 1 {
                request.append(buffer)
                return
            }

            // VPIO can deliver multi-channel buffers; extract channel 0 as mono for SFSpeechRecognizer.
            if let monoFormat,
               let monoBuffer = Self.makeMonoCopy(of: buffer, monoFormat: monoFormat)
            {
                request.append(monoBuffer)
            } else {
                request.append(buffer)
            }
            return
        }

        guard shouldRecordPreRoll,
              buffer.frameLength > 0,
              let monoFormat,
              let copy = Self.makeMonoCopy(of: buffer, monoFormat: monoFormat)
        else { return }

        let duration = Double(copy.frameLength) / max(monoFormat.sampleRate, 1)
        lock.lock()
        if activeRequest == nil,
           detector.isSpeaking,
           detector.config.enabled,
           detector.config.requiresKeywordVerification
        {
            if preRollSampleRate != monoFormat.sampleRate {
                preRollBuffers.removeAll(keepingCapacity: true)
                preRollDuration = 0
                preRollSampleRate = monoFormat.sampleRate
            }
            preRollBuffers.append((buffer: copy, duration: duration))
            preRollDuration += duration
            while preRollDuration > maxPreRollDuration && preRollBuffers.count > 1 {
                let removed = preRollBuffers.removeFirst()
                preRollDuration = max(0, preRollDuration - removed.duration)
            }
        }
        lock.unlock()
    }

    private static func makeMonoCopy(
        of buffer: AVAudioPCMBuffer,
        monoFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0,
              buffer.format.commonFormat == .pcmFormatFloat32,
              let src = buffer.floatChannelData?[0],
              let copy = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let dst = copy.floatChannelData?[0]
        else { return nil }

        copy.frameLength = buffer.frameLength
        let channelCount = Int(buffer.format.channelCount)
        if buffer.format.isInterleaved && channelCount > 1 {
            for i in 0..<frameLength {
                dst[i] = src[i * channelCount]
            }
        } else {
            memcpy(dst, src, frameLength * MemoryLayout<Float>.size)
        }
        return copy
    }

    /// Updates ambient noise floor while in `.thinking` state using the same 100 Hz high-pass
    /// pipeline used for barge-in evaluation so baseline and trigger energy match.
    func sampleAmbientIfNeeded(buffer: AVAudioPCMBuffer) {
        lock.lock()
        let shouldSample = isSamplingAmbient && !detector.isSpeaking
        let sampleRate = buffer.format.sampleRate
        var xPrev = hpfSampleRate == sampleRate ? hpfPrevInput : 0
        var yPrev = hpfSampleRate == sampleRate ? hpfPrevOutput : 0
        lock.unlock()

        guard shouldSample else { return }
        let level = Self.computeHighPassNormalizedRMS(
            from: buffer,
            prevInput: &xPrev,
            prevOutput: &yPrev
        )

        lock.lock()
        if isSamplingAmbient && !detector.isSpeaking {
            hpfSampleRate = sampleRate
            hpfPrevInput = xPrev
            hpfPrevOutput = yPrev
            detector.updateAmbientNoise(level: level)
        }
        lock.unlock()
    }

    /// Evaluates high-pass filtered microphone energy against `VoiceBargeInDetector`.
    func processSpeakingFrame(
        buffer: AVAudioPCMBuffer,
        duration: Double,
        farEndLevel: Float
    ) -> VoiceBargeInAction {
        lock.lock()
        let speaking = detector.isSpeaking
        let enabled = detector.config.enabled
        let sampleRate = buffer.format.sampleRate
        var xPrev = hpfSampleRate == sampleRate ? hpfPrevInput : 0
        var yPrev = hpfSampleRate == sampleRate ? hpfPrevOutput : 0
        lock.unlock()

        guard speaking, enabled, duration > 0 else { return .none }

        let level = Self.computeHighPassNormalizedRMS(
            from: buffer,
            prevInput: &xPrev,
            prevOutput: &yPrev
        )

        lock.lock()
        hpfSampleRate = sampleRate
        hpfPrevInput = xPrev
        hpfPrevOutput = yPrev
        if detector.isKeywordVerifying {
            if level >= detector.currentStage2Threshold {
                lastKeywordVoiceUptime = ProcessInfo.processInfo.systemUptime
            }
            lock.unlock()
            return .none
        }
        let action = detector.process(
            micLevel: level,
            farEndLevel: farEndLevel,
            duration: duration
        )
        lock.unlock()
        return action
    }

    /// 1-pole high-pass filter (~100 Hz cutoff) that strips DC offset, handling rumble,
    /// and sub-vocal resonance while preserving human voice fundamentals before normalizing RMS.
    private static func computeHighPassNormalizedRMS(
        from buffer: AVAudioPCMBuffer,
        prevInput: inout Float,
        prevOutput: inout Float
    ) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        let sampleRate = max(buffer.format.sampleRate, 1.0)
        let rc = 1.0 / (2.0 * Double.pi * 100.0)
        let dt = 1.0 / sampleRate
        let alpha = Float(rc / (rc + dt))

        var xPrev = prevInput.isFinite ? prevInput : 0
        var yPrev = prevOutput.isFinite ? prevOutput : 0
        var sum: Float = 0

        for i in 0..<frameLength {
            let raw = channelData[i]
            let x = raw.isFinite ? raw : 0
            let y = alpha * (yPrev + x - xPrev)
            let safeY = y.isFinite ? y : 0
            xPrev = x
            yPrev = safeY
            sum += safeY * safeY
        }

        prevInput = xPrev
        prevOutput = yPrev
        let rms = sqrt(sum / Float(frameLength))
        return VoiceBargeInDetector.normalizeRMS(rms)
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

/// Schedules TTS PCM buffers and decoded audio files onto the shared `AVAudioEngine`'s
/// `AVAudioPlayerNode` so iOS VPIO hardware AEC receives the exact speaker reference signal.
private final class EnginePlaybackController: VoiceAudioOutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private let levelBox: AudioLevelBox
    private let playbackLevelBox = AudioLevelBox()
    private var player: AVAudioPlayerNode?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var cachedSourceFormat: AVAudioFormat?
    private var pendingBuffers = 0
    private var playbackGeneration: UInt64 = 0
    private var drainContinuation: CheckedContinuation<Void, Error>?
    private var currentVolume: Float = 1.0
    private var scheduledChunkLevels: [Float] = []
    private var chunkHeadIndex: Int = 0

    init(levelBox: AudioLevelBox) {
        self.levelBox = levelBox
    }

    var isPlayingAudio: Bool {
        lock.lock()
        let active = pendingBuffers > 0
        lock.unlock()
        return active
    }

    var currentPlaybackLevel: Float {
        playbackLevelBox.get()
    }

    private func syncPlaybackLevelBoxLocked() {
        let level: Float
        if pendingBuffers > 0, chunkHeadIndex < scheduledChunkLevels.count {
            level = scheduledChunkLevels[chunkHeadIndex] * currentVolume
        } else {
            level = 0
        }
        playbackLevelBox.set(level)
    }

    func setDucked(_ ducked: Bool) {
        let targetVolume: Float = ducked ? 0.08 : 1.0
        lock.lock()
        if currentVolume == targetVolume {
            lock.unlock()
            return
        }
        currentVolume = targetVolume
        syncPlaybackLevelBoxLocked()
        let activePlayer = player
        lock.unlock()
        activePlayer?.volume = targetVolume
    }

    func muteForInterrupt() {
        lock.lock()
        currentVolume = 0
        syncPlaybackLevelBoxLocked()
        let activePlayer = player
        lock.unlock()
        activePlayer?.volume = 0
    }

    func attach(player: AVAudioPlayerNode, format: AVAudioFormat) {
        resetAttachment(player: player, format: format, failDrainWithCancellation: true)
    }

    func reattachForRecovery(player: AVAudioPlayerNode, format: AVAudioFormat) {
        resetAttachment(player: player, format: format, failDrainWithCancellation: false)
    }

    private func resetAttachment(
        player: AVAudioPlayerNode,
        format: AVAudioFormat,
        failDrainWithCancellation: Bool
    ) {
        lock.lock()
        self.player = player
        self.targetFormat = format
        self.converter = nil
        self.cachedSourceFormat = nil
        self.pendingBuffers = 0
        self.scheduledChunkLevels.removeAll(keepingCapacity: false)
        self.chunkHeadIndex = 0
        self.currentVolume = 1.0
        self.playbackGeneration &+= 1
        syncPlaybackLevelBoxLocked()
        let cont = drainContinuation
        self.drainContinuation = nil
        lock.unlock()

        player.volume = 1.0
        if failDrainWithCancellation {
            cont?.resume(throwing: CancellationError())
        } else {
            cont?.resume(returning: ())
        }
    }

    func detach() {
        lock.lock()
        playbackGeneration &+= 1
        pendingBuffers = 0
        scheduledChunkLevels.removeAll(keepingCapacity: false)
        chunkHeadIndex = 0
        currentVolume = 1.0
        syncPlaybackLevelBoxLocked()
        let oldPlayer = player
        player = nil
        targetFormat = nil
        converter = nil
        cachedSourceFormat = nil
        let cont = drainContinuation
        drainContinuation = nil
        lock.unlock()

        oldPlayer?.stop()
        oldPlayer?.volume = 1.0
        levelBox.set(0)
        cont?.resume(throwing: CancellationError())
    }

    func enqueuePCMBuffer(_ buffer: AVAudioPCMBuffer) {
        schedulePCMBuffer(buffer, expectedGeneration: nil)
    }

    private func schedulePCMBuffer(_ buffer: AVAudioPCMBuffer, expectedGeneration: UInt64?) {
        guard buffer.frameLength > 0 else { return }

        lock.lock()
        guard let player,
              let targetFormat,
              player.engine?.isRunning == true,
              expectedGeneration == nil || expectedGeneration == playbackGeneration
        else {
            lock.unlock()
            return
        }

        let bufferToSchedule: AVAudioPCMBuffer
        if buffer.format == targetFormat {
            bufferToSchedule = buffer
        } else {
            if cachedSourceFormat != buffer.format || converter == nil {
                converter = AVAudioConverter(from: buffer.format, to: targetFormat)
                cachedSourceFormat = buffer.format
            }
            guard let activeConverter = converter else {
                lock.unlock()
                return
            }
            let ratio = targetFormat.sampleRate / max(buffer.format.sampleRate, 1)
            let outCapacity = max(AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32, 64)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
                lock.unlock()
                return
            }

            var provided = false
            var convError: NSError?
            let status = activeConverter.convert(to: converted, error: &convError) { _, outStatus in
                if provided {
                    // Use `.noDataNow` rather than `.endOfStream` so resampler filter continuity
                    // is preserved across consecutive streaming TTS chunks without clicks.
                    outStatus.pointee = .noDataNow
                    return nil
                }
                provided = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard convError == nil,
                  status != .error,
                  converted.frameLength > 0
            else {
                lock.unlock()
                return
            }
            bufferToSchedule = converted
        }

        if !player.isPlaying {
            player.play()
        }
        let maxChunkFrames = AVAudioFrameCount(max(targetFormat.sampleRate * 0.08, 1024))
        let chunks = Self.sliceFloat32Buffer(bufferToSchedule, maxFrames: maxChunkFrames)
        let gen = playbackGeneration
        for chunk in chunks {
            let chunkLevel = Self.computeChunkNormalizedRMS(from: chunk)
            scheduledChunkLevels.append(chunkLevel)
            pendingBuffers += 1
            player.scheduleBuffer(chunk, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.handleBufferCompleted(generation: gen)
            }
        }
        syncPlaybackLevelBoxLocked()
        lock.unlock()
    }

    func drainEnqueuedPlayback() async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if pendingBuffers == 0 || player == nil || player?.engine?.isRunning != true {
                lock.unlock()
                continuation.resume(returning: ())
                return
            }
            let previous = drainContinuation
            drainContinuation = continuation
            lock.unlock()
            previous?.resume(throwing: CancellationError())
        }
    }

    func playEncodedAudio(_ data: Data) async throws {
        try Task.checkCancellation()
        let expectedGen = currentGeneration()

        try await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self, self.currentGeneration() == expectedGen else { throw CancellationError() }
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-tts-\(UUID().uuidString).mp3")
            try data.write(to: tempURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let audioFile = try AVAudioFile(forReading: tempURL)
            let format = audioFile.processingFormat
            let chunkFrames: AVAudioFrameCount = 8192

            while audioFile.framePosition < audioFile.length {
                guard self.currentGeneration() == expectedGen else { throw CancellationError() }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
                try audioFile.read(into: buffer, frameCount: chunkFrames)
                guard buffer.frameLength > 0 else { break }
                self.schedulePCMBuffer(buffer, expectedGeneration: expectedGen)
            }
        }.value

        try await drainEnqueuedPlayback()
    }

    private func currentGeneration() -> UInt64 {
        lock.lock()
        let gen = playbackGeneration
        lock.unlock()
        return gen
    }

    func stopPlayback() {
        lock.lock()
        playbackGeneration &+= 1
        pendingBuffers = 0
        scheduledChunkLevels.removeAll(keepingCapacity: false)
        chunkHeadIndex = 0
        currentVolume = 1.0
        syncPlaybackLevelBoxLocked()
        converter?.reset()
        let activePlayer = player
        let cont = drainContinuation
        drainContinuation = nil
        lock.unlock()

        if let activePlayer {
            if activePlayer.engine?.isRunning == true {
                activePlayer.stop()
                activePlayer.volume = 1.0
                activePlayer.play()
            } else {
                activePlayer.volume = 1.0
            }
        }
        levelBox.set(0)
        cont?.resume(throwing: CancellationError())
    }

    private func handleBufferCompleted(generation: UInt64) {
        lock.lock()
        guard playbackGeneration == generation else {
            lock.unlock()
            return
        }
        pendingBuffers = max(0, pendingBuffers - 1)
        if chunkHeadIndex < scheduledChunkLevels.count {
            chunkHeadIndex += 1
        }
        if pendingBuffers == 0 || chunkHeadIndex >= scheduledChunkLevels.count {
            scheduledChunkLevels.removeAll(keepingCapacity: false)
            chunkHeadIndex = 0
        } else if chunkHeadIndex >= 32 {
            scheduledChunkLevels.removeFirst(chunkHeadIndex)
            chunkHeadIndex = 0
        }
        syncPlaybackLevelBoxLocked()
        let shouldResume = pendingBuffers == 0
        let cont = shouldResume ? drainContinuation : nil
        if shouldResume {
            drainContinuation = nil
        }
        lock.unlock()

        if shouldResume {
            levelBox.set(0)
            cont?.resume(returning: ())
        }
    }

    private static func sliceFloat32Buffer(
        _ buffer: AVAudioPCMBuffer,
        maxFrames: AVAudioFrameCount
    ) -> [AVAudioPCMBuffer] {
        let totalFrames = buffer.frameLength
        guard totalFrames > maxFrames,
              buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              let srcChannels = buffer.floatChannelData
        else {
            return [buffer]
        }

        let channelCount = Int(buffer.format.channelCount)
        var chunks: [AVAudioPCMBuffer] = []
        chunks.reserveCapacity(Int((totalFrames + maxFrames - 1) / maxFrames))

        var offset: AVAudioFrameCount = 0
        while offset < totalFrames {
            let count = min(maxFrames, totalFrames - offset)
            guard let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count),
                  let dstChannels = slice.floatChannelData
            else {
                return [buffer]
            }
            slice.frameLength = count
            let byteCount = Int(count) * MemoryLayout<Float>.size
            for ch in 0..<channelCount {
                memcpy(dstChannels[ch], srcChannels[ch].advanced(by: Int(offset)), byteCount)
            }
            chunks.append(slice)
            offset += count
        }
        return chunks
    }

    private static func computeChunkNormalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        let channelCount = max(Int(buffer.format.channelCount), 1)
        guard frameLength > 0,
              buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData
        else { return 0 }

        var sum: Float = 0
        if buffer.format.isInterleaved {
            let sampleCount = frameLength * channelCount
            let ptr = channels[0]
            for i in 0..<sampleCount {
                let raw = ptr[i]
                let safe = raw.isFinite ? raw : 0
                sum += safe * safe
            }
            let rms = sqrt(sum / Float(sampleCount))
            return VoiceBargeInDetector.normalizeRMS(rms)
        } else {
            for ch in 0..<channelCount {
                let ptr = channels[ch]
                for i in 0..<frameLength {
                    let raw = ptr[i]
                    let safe = raw.isFinite ? raw : 0
                    sum += safe * safe
                }
            }
            let rms = sqrt(sum / Float(frameLength * channelCount))
            return VoiceBargeInDetector.normalizeRMS(rms)
        }
    }
}
