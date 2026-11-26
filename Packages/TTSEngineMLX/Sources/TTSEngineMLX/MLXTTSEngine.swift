// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import MobileLLMUI
#if os(iOS)
import UIKit
#endif

/// Local on-device MLX neural TTS engine conforming to `PrefetchableTTSEngine`.
/// Routes CosyVoice3 0.5B (recommended) and Qwen3-TTS 0.6B CustomVoice weights on Apple Silicon,
/// supports full-duplex `VoiceAudioOutputSink` handoff, and releases weights when idle or backgrounded.
@MainActor
public final class MLXTTSEngine: PrefetchableTTSEngine {
    public typealias ModelResolution = (model: LocalTTSModel, variant: LocalTTSModelVariant, directory: URL)

    public let id = "local-mlx"
    public let displayName = "Local MLX Voice"
    public private(set) var isSpeaking: Bool = false
    public var onExternalInterruption: (@MainActor @Sendable () -> Void)?
    public var preservesExternalAudioSession: Bool = false
    public var externalOutputSink: (any VoiceAudioOutputSink)?
    public var preferredBatchCharacterLimit: Int { 140 }

    private let modelResolver: @MainActor () -> ModelResolution?
    private let voiceCloneResolver: @MainActor (String) -> LocalMLXTTSVoiceCloneReference?
    private let clonedVoicesProvider: @MainActor () -> [TTSVoiceInfo]
    private let runtime: LocalMLXTTSRuntime
    private let idleUnloadDelay: Duration
    private let playerDelegate = PlayerDelegateProxy()

    private var player: AVAudioPlayer?
    private var activeContinuation: CheckedContinuation<Void, Error>?
    private var activePlaybackToken: UInt64?
    private var nextPlaybackToken: UInt64 = 0

    private var prewarmTask: Task<Void, Never>?
    private var idleUnloadTask: Task<Void, Never>?
    private var audioSessionActive = false
    nonisolated(unsafe) private var audioObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var memoryWarningObserver: NSObjectProtocol?

    #if os(iOS)
    private static let audioSessionQueue = DispatchQueue(label: "com.mobilellm.tts.localmlx.audiosession", qos: .userInitiated)
    private let audioSessionTokenBox = AudioSessionTokenBox()
    #endif

    public var isReady: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return modelResolver() != nil
        #endif
    }

    public convenience init(
        voiceModels: LocalTTSModelManager,
        settings: AppSettings,
        voiceClones: VoiceCloneStore? = nil,
        runtime: LocalMLXTTSRuntime = LocalMLXTTSRuntime(),
        idleUnloadDelay: Duration = .seconds(90)
    ) {
        self.init(
            runtime: runtime,
            idleUnloadDelay: idleUnloadDelay,
            modelResolver: {
                if let selectedID = settings.localMLXModelVariantID,
                   let found = LocalTTSModelCatalog.variant(id: selectedID),
                   voiceModels.isInstalled(found.variant) {
                    return (found.model, found.variant, voiceModels.localDirectory(for: found.variant))
                }
                for model in voiceModels.catalog {
                    if let installedVariant = model.variants.first(where: { voiceModels.isInstalled($0) }) {
                        return (model, installedVariant, voiceModels.localDirectory(for: installedVariant))
                    }
                }
                return nil
            },
            voiceCloneResolver: { voiceID in
                guard ClonedVoiceProfile.isClonedVoiceID(voiceID),
                      let profile = voiceClones?.profile(id: voiceID),
                      let url = voiceClones?.audioURL(for: profile) else {
                    return nil
                }
                return LocalMLXTTSVoiceCloneReference(
                    profileID: profile.id,
                    audioURL: url,
                    referenceTranscript: profile.referenceTranscript
                )
            },
            clonedVoicesProvider: {
                (voiceClones?.profiles ?? []).map {
                    TTSVoiceInfo(id: $0.id, name: $0.name, language: "clone", qualityLabel: "Voice Clone")
                }
            }
        )
    }

    public init(
        runtime: LocalMLXTTSRuntime = LocalMLXTTSRuntime(),
        idleUnloadDelay: Duration = .seconds(90),
        modelResolver: @escaping @MainActor () -> ModelResolution?,
        voiceCloneResolver: @escaping @MainActor (String) -> LocalMLXTTSVoiceCloneReference? = { _ in nil },
        clonedVoicesProvider: @escaping @MainActor () -> [TTSVoiceInfo] = { [] }
    ) {
        self.runtime = runtime
        self.idleUnloadDelay = idleUnloadDelay
        self.modelResolver = modelResolver
        self.voiceCloneResolver = voiceCloneResolver
        self.clonedVoicesProvider = clonedVoicesProvider
        self.playerDelegate.owner = self
        #if os(iOS)
        self.memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isSpeaking else { return }
                self.unloadWeights()
            }
        }
        #endif
    }

    deinit {
        for observer in audioObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    public func availableVoices() -> [TTSVoiceInfo] {
        let model = modelResolver()?.model ?? LocalTTSModelCatalog.defaultModel
        let presets = model.presetVoices.map {
            TTSVoiceInfo(id: $0.id, name: $0.name, language: $0.language, qualityLabel: "Local MLX")
        }
        return clonedVoicesProvider() + presets
    }

    public func speak(text: String, voiceID: String?, rate: Double) async throws {
        let data = try await synthesize(text: text, voiceID: voiceID, rate: rate)
        guard !data.isEmpty else { return }
        try await play(synthesizedData: data)
    }

    public func synthesize(text: String, voiceID: String?, rate: Double) async throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Data() }
        try Task.checkCancellation()

        idleUnloadTask?.cancel()
        idleUnloadTask = nil

        guard let resolved = modelResolver() else {
            throw LocalMLXTTSError.noInstalledModel
        }

        let cloneReference = voiceID.flatMap { voiceCloneResolver($0) }
        let request = LocalMLXTTSRequest(
            text: trimmed,
            modelID: resolved.model.id,
            variantID: resolved.variant.id,
            weightsDirectory: resolved.directory,
            voiceID: voiceID,
            rate: rate,
            cloneReference: cloneReference
        )
        let result = try await runtime.synthesize(request)
        try Task.checkCancellation()

        let wavData = LocalTTSWAVEncoder.encodePCM16WAV(
            samples: result.samples,
            sampleRate: result.sampleRate
        )
        guard !wavData.isEmpty else {
            throw LocalMLXTTSError.emptyAudio
        }

        scheduleIdleUnload()
        return wavData
    }

    public func play(synthesizedData data: Data) async throws {
        guard !data.isEmpty else { return }
        try Task.checkCancellation()

        idleUnloadTask?.cancel()
        idleUnloadTask = nil

        if isSpeaking || activeContinuation != nil {
            stop()
        }

        nextPlaybackToken &+= 1
        let token = nextPlaybackToken
        activePlaybackToken = token

        if let sink = externalOutputSink {
            isSpeaking = true
            defer {
                isSpeaking = false
                if activePlaybackToken == token {
                    activePlaybackToken = nil
                }
                scheduleIdleUnload()
            }
            try await withTaskCancellationHandler {
                try await sink.playEncodedAudio(data)
            } onCancel: {
                sink.stopPlayback()
            }
            return
        }

        try await playAudioData(data, token: token)
        scheduleIdleUnload()
    }

    public func stop() {
        isSpeaking = false
        activePlaybackToken = nil
        externalOutputSink?.stopPlayback()
        player?.stop()
        player = nil
        let continuation = activeContinuation
        activeContinuation = nil
        continuation?.resume(throwing: CancellationError())
    }

    public func endPlaybackSession() {
        player?.stop()
        player = nil
        #if os(iOS)
        if audioSessionActive {
            audioSessionActive = false
            let expectedToken = audioSessionTokenBox.current()
            let tokenBox = audioSessionTokenBox
            Self.audioSessionQueue.async {
                guard tokenBox.current() == expectedToken else { return }
                let session = AVAudioSession.sharedInstance()
                guard session.category == .playback, session.mode == .spokenAudio else { return }
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        #endif
        scheduleIdleUnload()
    }

    public func prewarm() {
        #if !targetEnvironment(simulator)
        guard let resolved = modelResolver() else { return }
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        prewarmTask?.cancel()
        let runtime = self.runtime
        let modelID = resolved.model.id
        let variantID = resolved.variant.id
        let directory = resolved.directory
        prewarmTask = Task {
            try? await runtime.prewarm(modelID: modelID, variantID: variantID, weightsDirectory: directory)
        }
        #endif
    }

    public func unloadWeights() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        prewarmTask?.cancel()
        prewarmTask = nil
        let runtime = self.runtime
        Task {
            await runtime.unload()
        }
    }

    // MARK: - Idle lifecycle & Playback

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        let delay = idleUnloadDelay
        idleUnloadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !self.isSpeaking else { return }
            await self.runtime.unload()
        }
    }

    private func playAudioData(_ data: Data, token: UInt64) async throws {
        configureAudioSessionIfNeeded()

        let audioPlayer: AVAudioPlayer
        do {
            audioPlayer = try AVAudioPlayer(data: data)
        } catch {
            activePlaybackToken = nil
            throw LocalMLXTTSError.audioPlaybackFailed
        }

        audioPlayer.delegate = playerDelegate
        guard audioPlayer.prepareToPlay() else {
            activePlaybackToken = nil
            throw LocalMLXTTSError.audioPlaybackFailed
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard self.activePlaybackToken == token else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.player = audioPlayer
                self.activeContinuation = continuation
                self.isSpeaking = true
                if !audioPlayer.play() {
                    self.finishPlayback(token: token, error: LocalMLXTTSError.audioPlaybackFailed)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.activePlaybackToken == token else { return }
                self.stop()
            }
        }
    }

    fileprivate func finishPlayback(token: UInt64? = nil, error: Error?) {
        if let token, activePlaybackToken != token {
            return
        }
        guard activePlaybackToken != nil || activeContinuation != nil else { return }
        isSpeaking = false
        activePlaybackToken = nil
        player = nil
        let continuation = activeContinuation
        activeContinuation = nil
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: ())
        }
    }

    private func configureAudioSessionIfNeeded() {
        #if os(iOS)
        ensureAudioInterruptionObservers()
        audioSessionTokenBox.advance()
        guard !preservesExternalAudioSession else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playback || session.mode != .spokenAudio {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            }
            if !audioSessionActive {
                try session.setActive(true)
                audioSessionActive = true
            }
        } catch {
            // Best effort; AVAudioPlayer still attempts playback.
        }
        #endif
    }

    #if os(iOS)
    private func ensureAudioInterruptionObservers() {
        guard audioObservers.isEmpty else { return }
        let center = NotificationCenter.default

        let interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let typeRaw, AVAudioSession.InterruptionType(rawValue: typeRaw) == .began else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isSpeaking else { return }
                self.audioSessionActive = false
                if let handler = self.onExternalInterruption {
                    handler()
                } else {
                    self.stop()
                }
            }
        }

        let routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard let reasonRaw, AVAudioSession.RouteChangeReason(rawValue: reasonRaw) == .oldDeviceUnavailable else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.isSpeaking else { return }
                if let handler = self.onExternalInterruption {
                    handler()
                } else {
                    self.stop()
                }
            }
        }

        audioObservers = [interruptionObserver, routeObserver]
    }
    #endif

    // MARK: - Helpers

    private final class PlayerDelegateProxy: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        weak var owner: MLXTTSEngine?

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor [weak owner] in
                owner?.finishPlayback(error: flag ? nil : LocalMLXTTSError.audioPlaybackFailed)
            }
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            Task { @MainActor [weak owner] in
                owner?.finishPlayback(error: error ?? LocalMLXTTSError.audioPlaybackFailed)
            }
        }
    }

    #if os(iOS)
    private final class AudioSessionTokenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var token: UInt64 = 0

        func advance() {
            lock.lock()
            token &+= 1
            lock.unlock()
        }

        func current() -> UInt64 {
            lock.lock()
            let value = token
            lock.unlock()
            return value
        }
    }
    #endif
}
