// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation
import MobileLLMUI
import NaturalLanguage
import SherpaOnnx

/// Offline neural TTS engine powered by Kokoro v1.1 (`sherpa-onnx`) + `AVAudioEngine`.
///
/// Synthesis runs off the main thread on a dedicated serial queue so UI interactions remain fluid,
/// and model weights can be evicted via `unload()` when entering background or reclaiming RAM.
@MainActor
public final class KokoroTTSEngine: TTSEngine {
    public enum KokoroError: LocalizedError {
        case modelNotInstalled
        case initializationFailed
        case audioEngineFailed

        public var errorDescription: String? {
            switch self {
            case .modelNotInstalled:
                return "Kokoro offline model is not installed."
            case .initializationFailed:
                return "Failed to initialize Kokoro neural TTS engine."
            case .audioEngineFailed:
                return "Failed to start audio playback engine."
            }
        }
    }

    public let id = "kokoro-offline"
    public let displayName = "Kokoro Neural (Offline)"
    public private(set) var isSpeaking: Bool = false
    public var onExternalInterruption: (@MainActor () -> Void)?

    public var isReady: Bool {
        modelManager.resolveInstalledFiles() != nil
    }

    private let modelManager: KokoroModelManager
    private let synthesizerBox = SynthesizerBox()
    private static let synthesisQueue = DispatchQueue(label: "com.mobilellm.tts.kokoro.synth", qos: .userInitiated)

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var connectedSampleRate: Double = 0

    private var activeContinuation: CheckedContinuation<Void, Error>?
    private var activePlaybackToken: UInt64?
    private var nextPlaybackToken: UInt64 = 0

    private var audioSessionActive = false
    nonisolated(unsafe) private var audioObservers: [NSObjectProtocol] = []

    #if os(iOS)
    private static let audioSessionQueue = DispatchQueue(label: "com.mobilellm.tts.kokoro.audiosession", qos: .userInitiated)
    private let audioSessionTokenBox = AudioSessionTokenBox()
    #endif

    public init(modelManager: KokoroModelManager) {
        self.modelManager = modelManager
    }

    deinit {
        for observer in audioObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func availableVoices() -> [TTSVoiceInfo] {
        KokoroVoicePreset.curated.map { $0.toTTSVoiceInfo() }
    }

    public func speak(text: String, voiceID: String?, rate: Double) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try Task.checkCancellation()

        guard let files = modelManager.resolveInstalledFiles() else {
            throw KokoroError.modelNotInstalled
        }

        if isSpeaking || activeContinuation != nil {
            stop()
        }

        nextPlaybackToken &+= 1
        let token = nextPlaybackToken
        activePlaybackToken = token

        let isChinese = Self.looksChinese(trimmed)
        let sid = KokoroVoicePreset.resolveSID(voiceID: voiceID, fallbackChinese: isChinese)
        let clampedRate = Float(min(max(rate, 0.5), 2.0))
        let box = synthesizerBox

        let synthesized: (samples: [Float], sampleRate: Int32) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.synthesisQueue.async {
                    do {
                        let wrapper = try box.ensureLoaded(files: files)
                        let speakerCount = Int(wrapper.numSpeakers)
                        let clampedSID = speakerCount > 0 ? min(max(sid, 0), speakerCount - 1) : 0
                        let audio = wrapper.generate(text: trimmed, sid: clampedSID, speed: clampedRate)
                        let samples = audio.samples
                        let sampleRate = audio.sampleRate
                        continuation.resume(returning: (samples, sampleRate))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.activePlaybackToken == token else { return }
                self.stop()
            }
        }

        try Task.checkCancellation()
        guard activePlaybackToken == token else {
            throw CancellationError()
        }
        guard !synthesized.samples.isEmpty, synthesized.sampleRate > 0 else {
            activePlaybackToken = nil
            return
        }

        try await playPCM(samples: synthesized.samples, sampleRate: Double(synthesized.sampleRate), token: token)
    }

    public func stop() {
        isSpeaking = false
        activePlaybackToken = nil
        playerNode?.stop()
        let continuation = activeContinuation
        activeContinuation = nil
        continuation?.resume(throwing: CancellationError())
    }

    public func endPlaybackSession() {
        playerNode?.stop()
        audioEngine?.stop()
        #if os(iOS)
        guard audioSessionActive else { return }
        audioSessionActive = false
        let expectedToken = audioSessionTokenBox.current()
        let tokenBox = audioSessionTokenBox
        Self.audioSessionQueue.async {
            guard tokenBox.current() == expectedToken else { return }
            let session = AVAudioSession.sharedInstance()
            guard session.category == .playback, session.mode == .spokenAudio else { return }
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }

    public func unload() {
        stop()
        endPlaybackSession()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        connectedSampleRate = 0

        let box = synthesizerBox
        Self.synthesisQueue.async {
            box.unload()
        }
    }

    // MARK: - Audio Playback

    private func playPCM(samples: [Float], sampleRate: Double, token: UInt64) async throws {
        configureAudioSessionIfNeeded()
        let (player, format) = try ensureAudioPipeline(sampleRate: sampleRate)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw KokoroError.audioEngineFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    channelData[0].update(from: base, count: samples.count)
                }
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard self.activePlaybackToken == token else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.activeContinuation = continuation
                self.isSpeaking = true
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.handleBufferCompleted(token: token)
                    }
                }
                if !player.isPlaying {
                    player.play()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.activePlaybackToken == token else { return }
                self.stop()
            }
        }
    }

    private func handleBufferCompleted(token: UInt64) {
        guard activePlaybackToken == token else { return }
        isSpeaking = false
        activePlaybackToken = nil
        let continuation = activeContinuation
        activeContinuation = nil
        continuation?.resume(returning: ())
    }

    private func ensureAudioPipeline(sampleRate: Double) throws -> (AVAudioPlayerNode, AVAudioFormat) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw KokoroError.audioEngineFailed
        }

        let engine: AVAudioEngine
        let player: AVAudioPlayerNode

        if let existingEngine = audioEngine, let existingPlayer = playerNode {
            engine = existingEngine
            player = existingPlayer
            if connectedSampleRate != sampleRate {
                existingPlayer.stop()
                existingEngine.stop()
                existingEngine.disconnectNodeOutput(existingPlayer)
                existingEngine.connect(existingPlayer, to: existingEngine.mainMixerNode, format: format)
                connectedSampleRate = sampleRate
            }
        } else {
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            self.audioEngine = engine
            self.playerNode = player
            self.connectedSampleRate = sampleRate
        }

        if !engine.isRunning {
            try engine.start()
        }
        return (player, format)
    }

    // MARK: - Audio Session & Interruptions

    private func configureAudioSessionIfNeeded() {
        #if os(iOS)
        ensureAudioInterruptionObservers()
        audioSessionTokenBox.advance()
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
            // Best effort; AVAudioEngine still attempts playback.
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

    private static func looksChinese(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let dominant = recognizer.dominantLanguage {
            return dominant == .simplifiedChinese || dominant == .traditionalChinese
        }
        return text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
    }

    // MARK: - Thread-Safe Boxes

    private final class SynthesizerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var wrapper: SherpaOnnxOfflineTtsWrapper?
        private var loadedModelPath: String?

        func ensureLoaded(files: KokoroModelFiles) throws -> SherpaOnnxOfflineTtsWrapper {
            lock.lock()
            defer { lock.unlock() }

            if let wrapper, loadedModelPath == files.modelPath {
                return wrapper
            }

            let lexiconJoined = files.lexiconPaths.joined(separator: ",")
            let kokoroConfig = sherpaOnnxOfflineTtsKokoroModelConfig(
                model: files.modelPath,
                voices: files.voicesPath,
                tokens: files.tokensPath,
                lengthScale: 1.0,
                dictDir: files.dictDirPath ?? "",
                lexicon: lexiconJoined
            )
            let modelConfig = sherpaOnnxOfflineTtsModelConfig(
                kokoro: kokoroConfig,
                numThreads: 2,
                debug: 0
            )
            var ttsConfig = sherpaOnnxOfflineTtsConfig(model: modelConfig)
            let created = SherpaOnnxOfflineTtsWrapper(config: &ttsConfig)
            guard created.tts != nil else {
                throw KokoroError.initializationFailed
            }
            self.wrapper = created
            self.loadedModelPath = files.modelPath
            return created
        }

        func unload() {
            lock.lock()
            wrapper = nil
            loadedModelPath = nil
            lock.unlock()
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
