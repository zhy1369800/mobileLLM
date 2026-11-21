// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation

/// Configuration snapshot consumed by `CloudTTSEngine` for each synthesis request.
public struct CloudTTSConfiguration: Sendable, Equatable {
    public let baseURL: String
    public let apiKey: String
    public let model: String
    public let voice: String

    public init(baseURL: String, apiKey: String, model: String, voice: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
    }
}

/// Remote TTS engine backed by OpenAI-compatible `/v1/audio/speech` endpoints.
/// Uses `URLSession` + `AVAudioPlayer`, adding zero binary size or local RAM overhead.
@MainActor
public final class CloudTTSEngine: TTSEngine {
    public enum CloudTTSError: LocalizedError {
        case notConfigured
        case invalidURL
        case httpError(statusCode: Int, message: String?)
        case emptyAudio
        case audioPlaybackFailed

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Cloud TTS Base URL or API Key is not configured."
            case .invalidURL:
                return "Cloud TTS Base URL is invalid."
            case .httpError(let statusCode, let message):
                if let message, !message.isEmpty {
                    return "Cloud TTS HTTP \(statusCode): \(message)"
                }
                return "Cloud TTS request failed with HTTP \(statusCode)."
            case .emptyAudio:
                return "Cloud TTS returned empty audio data."
            case .audioPlaybackFailed:
                return "Failed to decode or play Cloud TTS audio."
            }
        }
    }

    public let id = "cloud-openai"
    public let displayName = "Cloud TTS"
    public private(set) var isSpeaking: Bool = false
    public var onExternalInterruption: (@MainActor @Sendable () -> Void)?

    public var isReady: Bool {
        guard let config = configurationProvider() else { return false }
        return !config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Self.speechEndpoint(from: config.baseURL) != nil
    }

    private let session: URLSession
    private let configurationProvider: @MainActor () -> CloudTTSConfiguration?
    private let playerDelegate = PlayerDelegateProxy()

    private var player: AVAudioPlayer?
    private var activeContinuation: CheckedContinuation<Void, Error>?
    private var activePlaybackToken: UInt64?
    private var nextPlaybackToken: UInt64 = 0

    private var audioSessionActive = false
    nonisolated(unsafe) private var audioObservers: [NSObjectProtocol] = []

    #if os(iOS)
    private static let audioSessionQueue = DispatchQueue(label: "com.mobilellm.tts.cloud.audiosession", qos: .userInitiated)
    private let audioSessionTokenBox = AudioSessionTokenBox()
    #endif

    public init(
        session: URLSession? = nil,
        configurationProvider: @escaping @MainActor () -> CloudTTSConfiguration?
    ) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: config)
        }
        self.configurationProvider = configurationProvider
        self.playerDelegate.owner = self
    }

    deinit {
        for observer in audioObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func availableVoices() -> [TTSVoiceInfo] {
        [
            TTSVoiceInfo(id: "alloy", name: "Alloy (OpenAI)", language: "multi", qualityLabel: "Cloud"),
            TTSVoiceInfo(id: "nova", name: "Nova (OpenAI)", language: "multi", qualityLabel: "Cloud"),
            TTSVoiceInfo(id: "shimmer", name: "Shimmer (OpenAI)", language: "multi", qualityLabel: "Cloud"),
            TTSVoiceInfo(id: "coral", name: "Coral (OpenAI)", language: "multi", qualityLabel: "Cloud"),
            TTSVoiceInfo(id: "sage", name: "Sage (OpenAI)", language: "multi", qualityLabel: "Cloud"),
            TTSVoiceInfo(id: "FunAudioLLM/CosyVoice2-0.5B:alex", name: "Alex (SiliconFlow CosyVoice2)", language: "zh-CN", qualityLabel: "Cloud"),
            TTSVoiceInfo(id: "FunAudioLLM/CosyVoice2-0.5B:anna", name: "Anna (SiliconFlow CosyVoice2)", language: "zh-CN", qualityLabel: "Cloud"),
            TTSVoiceInfo(id: "FunAudioLLM/CosyVoice2-0.5B:bella", name: "Bella (SiliconFlow CosyVoice2)", language: "zh-CN", qualityLabel: "Cloud"),
        ]
    }

    public nonisolated static func speechEndpoint(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else { return nil }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("audio/speech") {
            components.path = "/" + path
        } else if path.range(of: #"(^|/)v\d+$"#, options: .regularExpression) != nil {
            components.path = "/" + path + "/audio/speech"
        } else if path.isEmpty {
            components.path = "/v1/audio/speech"
        } else {
            components.path = "/" + path + "/audio/speech"
        }
        return components.url
    }

    public func speak(text: String, voiceID: String?, rate: Double) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try Task.checkCancellation()

        guard let config = configurationProvider(),
              !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudTTSError.notConfigured
        }
        guard let endpoint = Self.speechEndpoint(from: config.baseURL) else {
            throw CloudTTSError.invalidURL
        }

        if isSpeaking || activeContinuation != nil {
            stop()
        }

        nextPlaybackToken &+= 1
        let token = nextPlaybackToken
        activePlaybackToken = token

        let effectiveVoice: String
        if let voiceID, !voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effectiveVoice = voiceID
        } else {
            let trimmedConfigVoice = config.voice.trimmingCharacters(in: .whitespacesAndNewlines)
            effectiveVoice = trimmedConfigVoice.isEmpty ? "alloy" : trimmedConfigVoice
        }
        let effectiveModel = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let clampedRate = min(max(rate, 0.25), 4.0)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "model": effectiveModel.isEmpty ? "tts-1" : effectiveModel,
            "input": trimmed,
            "voice": effectiveVoice,
            "speed": clampedRate,
            "response_format": "mp3",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard activePlaybackToken == token else {
            throw CancellationError()
        }

        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            let snippet = String(data: data.prefix(200), encoding: .utf8)
            activePlaybackToken = nil
            throw CloudTTSError.httpError(statusCode: httpResponse.statusCode, message: snippet)
        }

        guard !data.isEmpty else {
            activePlaybackToken = nil
            throw CloudTTSError.emptyAudio
        }

        try await playAudioData(data, token: token)
    }

    public func stop() {
        isSpeaking = false
        activePlaybackToken = nil
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

    // MARK: - Playback & Session

    private func playAudioData(_ data: Data, token: UInt64) async throws {
        configureAudioSessionIfNeeded()

        let audioPlayer: AVAudioPlayer
        do {
            audioPlayer = try AVAudioPlayer(data: data)
        } catch {
            activePlaybackToken = nil
            throw CloudTTSError.audioPlaybackFailed
        }

        audioPlayer.delegate = playerDelegate
        guard audioPlayer.prepareToPlay() else {
            activePlaybackToken = nil
            throw CloudTTSError.audioPlaybackFailed
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
                    self.finishPlayback(token: token, error: CloudTTSError.audioPlaybackFailed)
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
        weak var owner: CloudTTSEngine?

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor [weak owner] in
                owner?.finishPlayback(error: flag ? nil : CloudTTSError.audioPlaybackFailed)
            }
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            Task { @MainActor [weak owner] in
                owner?.finishPlayback(error: error ?? CloudTTSEngine.CloudTTSError.audioPlaybackFailed)
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
