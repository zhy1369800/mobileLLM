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

/// Unified Text-to-Speech engine protocol.
/// Allows swapping between the zero-footprint system synthesizer (Apple AVSpeechSynthesizer)
/// and future neural or remote TTS engines behind one streaming-capable contract.
@MainActor
public protocol TTSEngine: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var isSpeaking: Bool { get }
    /// Called when an external audio interruption (e.g. phone call, headphones unplugged) halts playback.
    var onExternalInterruption: (@MainActor () -> Void)? { get set }

    /// Lists voices supported by this engine.
    func availableVoices() -> [TTSVoiceInfo]

    /// Synthesizes and plays a single utterance, suspending until playback finishes or is stopped.
    /// Throws `CancellationError` if interrupted via `stop()` or task cancellation.
    func speak(text: String, voiceID: String?, rate: Double) async throws

    /// Immediately halts current playback.
    func stop()

    /// Releases or deactivates any underlying audio session once a playback batch completes.
    func endPlaybackSession()
}

public extension TTSEngine {
    func endPlaybackSession() {}
}
