// SPDX-License-Identifier: MIT

import Foundation
import AVFoundation
import NaturalLanguage

/// Built-in zero-download TTS engine powered by Apple's `AVSpeechSynthesizer`.
/// Holds zero model weights in app RAM so local LLM inference memory budgets remain untouched.
@MainActor
public final class AppleSystemTTSEngine: TTSEngine {
    public let id = "apple-system"
    public let displayName = "Apple System Voice"

    public private(set) var isSpeaking: Bool = false
    public var onExternalInterruption: (@MainActor @Sendable () -> Void)?
    public var preservesExternalAudioSession: Bool = false
    public var externalOutputSink: (any VoiceAudioOutputSink)?
    public var preferredBatchCharacterLimit: Int { 280 }

    private var synthesizer: AVSpeechSynthesizer?
    private let delegateProxy = DelegateProxy()
    private var activeContinuation: CheckedContinuation<Void, Error>?
    private var activeUtteranceToken: UInt64?
    private let writeTokenBox = WriteTokenBox()
    private var nextUtteranceToken: UInt64 = 0
    private var cachedVoices: [TTSVoiceInfo]?
    private var audioSessionActive = false
    nonisolated(unsafe) private var audioObservers: [NSObjectProtocol] = []
    #if os(iOS)
    private static let audioSessionQueue = DispatchQueue(label: "com.mobilellm.tts.audiosession", qos: .userInitiated)
    private let audioSessionTokenBox = AudioSessionTokenBox()
    #endif

    public init() {
        self.delegateProxy.owner = self
    }

    public func prewarm() {
        _ = ensureSynthesizer()
    }

    deinit {
        for observer in audioObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func availableVoices() -> [TTSVoiceInfo] {
        if let cachedVoices {
            return cachedVoices
        }
        let voices = Self.loadAvailableVoices()
        cachedVoices = voices
        return voices
    }

    /// Loads and sorts system voices off-actor so callers can pre-fetch without blocking the UI thread.
    public nonisolated static func loadAvailableVoices() -> [TTSVoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { lhs, rhs in
                if lhs.language != rhs.language {
                    return lhs.language < rhs.language
                }
                if lhs.quality != rhs.quality {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                return lhs.name < rhs.name
            }
            .map { voice in
                let quality: String?
                switch voice.quality {
                case .enhanced:
                    quality = "Enhanced"
                case .premium:
                    quality = "Premium"
                default:
                    quality = nil
                }
                return TTSVoiceInfo(
                    id: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    qualityLabel: quality
                )
            }
    }

    public func speak(text: String, voiceID: String?, rate: Double) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try Task.checkCancellation()

        if synthesizer?.isSpeaking == true || activeContinuation != nil {
            stop()
        }

        configureAudioSessionIfNeeded()
        let synth = ensureSynthesizer()

        nextUtteranceToken &+= 1
        let token = nextUtteranceToken
        let utterance = TaggedUtterance(string: trimmed, token: token)
        utterance.rate = Self.mapPlaybackRate(rate)
        utterance.voice = resolveVoice(for: trimmed, preferredID: voiceID)

        if let sink = externalOutputSink {
            isSpeaking = true
            defer { isSpeaking = false }
            let tokenBox = writeTokenBox

            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.activeUtteranceToken = token
                    self.activeContinuation = continuation
                    tokenBox.set(token)
                    synth.write(utterance) { [weak self] buffer in
                        guard tokenBox.current() == token else { return }
                        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                        if pcm.frameLength == 0 {
                            tokenBox.clearIfMatches(token)
                            Task { @MainActor [weak self] in
                                self?.handleUtteranceCompleted(token: token, cancelled: false)
                            }
                        } else {
                            sink.enqueuePCMBuffer(pcm)
                        }
                    }
                }
                try Task.checkCancellation()
                try await sink.drainEnqueuedPlayback()
            } onCancel: {
                tokenBox.clearIfMatches(token)
                sink.stopPlayback()
                Task { @MainActor [weak self] in
                    guard let self, self.activeUtteranceToken == token else { return }
                    self.stop()
                }
            }
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.activeUtteranceToken = token
                self.activeContinuation = continuation
                self.isSpeaking = true
                synth.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.activeUtteranceToken == token else { return }
                self.stop()
            }
        }
    }

    public func stop() {
        isSpeaking = false
        writeTokenBox.clear()
        let continuation = activeContinuation
        activeContinuation = nil
        activeUtteranceToken = nil

        externalOutputSink?.stopPlayback()
        if let synthesizer {
            synthesizer.stopSpeaking(at: .immediate)
        }
        continuation?.resume(throwing: CancellationError())
    }

    public func endPlaybackSession() {
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

    fileprivate func handleUtteranceCompleted(token: UInt64, cancelled: Bool) {
        guard activeUtteranceToken == token else { return }
        isSpeaking = false
        activeUtteranceToken = nil
        let continuation = activeContinuation
        activeContinuation = nil
        if cancelled {
            continuation?.resume(throwing: CancellationError())
        } else {
            continuation?.resume(returning: ())
        }
    }

    // MARK: - Helpers

    private func ensureSynthesizer() -> AVSpeechSynthesizer {
        if let synthesizer {
            return synthesizer
        }
        let synth = AVSpeechSynthesizer()
        synth.delegate = delegateProxy
        self.synthesizer = synth
        return synth
    }

    private func resolveVoice(for text: String, preferredID: String?) -> AVSpeechSynthesisVoice? {
        if let preferredID, !preferredID.isEmpty,
           let explicit = AVSpeechSynthesisVoice(identifier: preferredID) {
            return explicit
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let dominant = recognizer.dominantLanguage {
            let bcp47 = Self.bcp47Code(for: dominant)
            if let voice = bestVoice(forLanguagePrefix: bcp47) {
                return voice
            }
        }
        return AVSpeechSynthesisVoice(language: nil)
    }

    private func bestVoice(forLanguagePrefix prefix: String) -> AVSpeechSynthesisVoice? {
        let normalizedPrefix = prefix.lowercased()
        let cached = availableVoices()
        if let bestCached = cached.first(where: { $0.language.lowercased().hasPrefix(normalizedPrefix) }),
           let voice = AVSpeechSynthesisVoice(identifier: bestCached.id) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: prefix)
    }

    private static func bcp47Code(for language: NLLanguage) -> String {
        switch language {
        case .simplifiedChinese: return "zh-CN"
        case .traditionalChinese: return "zh-TW"
        case .english: return "en"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .french: return "fr"
        case .german: return "de"
        case .spanish: return "es"
        default: return language.rawValue
        }
    }

    /// Maps user-facing multiplier (0.5x ... 2.0x, default 1.0x) to AVSpeechUtterance's range.
    nonisolated static func mapPlaybackRate(_ multiplier: Double) -> Float {
        let clamped = min(max(multiplier, 0.5), 2.0)
        let minRate = AVSpeechUtteranceMinimumSpeechRate
        let defaultRate = AVSpeechUtteranceDefaultSpeechRate
        let maxRate = AVSpeechUtteranceMaximumSpeechRate

        if clamped <= 1.0 {
            let t = Float((clamped - 0.5) / 0.5)
            return minRate + t * (defaultRate - minRate)
        } else {
            let t = Float((clamped - 1.0) / 1.0)
            let comfortableMax = defaultRate + (maxRate - defaultRate) * 0.72
            return defaultRate + t * (comfortableMax - defaultRate)
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
            // Best effort; AVSpeechSynthesizer still attempts output even if session activation fails.
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

    private final class TaggedUtterance: AVSpeechUtterance {
        let token: UInt64

        init(string: String, token: UInt64) {
            self.token = token
            super.init(string: string)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }
    }

    private final class DelegateProxy: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        weak var owner: AppleSystemTTSEngine?

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            guard let token = (utterance as? TaggedUtterance)?.token else { return }
            Task { @MainActor [weak owner] in
                owner?.handleUtteranceCompleted(token: token, cancelled: false)
            }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            guard let token = (utterance as? TaggedUtterance)?.token else { return }
            Task { @MainActor [weak owner] in
                owner?.handleUtteranceCompleted(token: token, cancelled: true)
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

    private final class WriteTokenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var token: UInt64 = 0

        func set(_ value: UInt64) {
            lock.lock()
            token = value
            lock.unlock()
        }

        func current() -> UInt64 {
            lock.lock()
            let value = token
            lock.unlock()
            return value
        }

        func clear() {
            lock.lock()
            token = 0
            lock.unlock()
        }

        func clearIfMatches(_ expected: UInt64) {
            lock.lock()
            if token == expected {
                token = 0
            }
            lock.unlock()
        }
    }
}
