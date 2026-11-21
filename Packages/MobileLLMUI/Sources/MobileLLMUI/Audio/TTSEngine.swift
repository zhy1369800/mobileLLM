// SPDX-License-Identifier: MIT

import Foundation

/// Metadata describing an available voice for a TTS engine.
public struct TTSVoiceInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let language: String
    public let qualityLabel: String?

    public init(id: String, name: String, language: String, qualityLabel: String? = nil) {
        self.id = id
        self.name = name
        self.language = language
        self.qualityLabel = qualityLabel
    }
}

/// Selectable speech synthesis backend.
public enum TTSEngineKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case appleSystem
    case kokoroOffline

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleSystem:
            return "Apple System Voice"
        case .kokoroOffline:
            return "Kokoro Neural (Offline)"
        }
    }
}

/// Unified Text-to-Speech engine protocol.
/// Allows swapping between the zero-footprint system synthesizer (Apple AVSpeechSynthesizer)
/// and future neural or remote TTS engines behind one streaming-capable contract.
@MainActor
public protocol TTSEngine: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var isSpeaking: Bool { get }
    var isReady: Bool { get }
    /// Called when an external audio interruption (e.g. phone call, headphones unplugged) halts playback.
    var onExternalInterruption: (@MainActor @Sendable () -> Void)? { get set }

    /// Lists voices supported by this engine.
    func availableVoices() -> [TTSVoiceInfo]

    /// Synthesizes and plays a single utterance, suspending until playback finishes or is stopped.
    /// Throws `CancellationError` if interrupted via `stop()` or task cancellation.
    func speak(text: String, voiceID: String?, rate: Double) async throws

    /// Immediately halts current playback.
    func stop()

    /// Releases or deactivates any underlying audio session once a playback batch completes.
    func endPlaybackSession()

    /// Releases any resident neural model weights/buffers from RAM.
    func unload()
}

public extension TTSEngine {
    var isReady: Bool { true }
    func endPlaybackSession() {}
    func unload() {}
}
