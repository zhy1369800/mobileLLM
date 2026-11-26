// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation

/// External PCM/audio playback sink owned by `VoiceChatSession`'s `AVAudioEngine`.
/// Routing TTS output through the same `AVAudioEngine` provides hardware VPIO AEC
/// with an exact speaker reference signal for full-duplex barge-in.
public protocol VoiceAudioOutputSink: AnyObject, Sendable {
    func enqueuePCMBuffer(_ buffer: AVAudioPCMBuffer)
    func drainEnqueuedPlayback() async throws
    func playEncodedAudio(_ data: Data) async throws
    func stopPlayback()
}

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
    case localMLX
    case cloudOpenAI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleSystem:
            return "Apple System Voice"
        case .localMLX:
            return "Local MLX Voice"
        case .cloudOpenAI:
            return "Cloud TTS"
        }
    }

    public var segmentedLabel: String {
        switch self {
        case .appleSystem:
            return "Apple"
        case .localMLX:
            return "Local MLX"
        case .cloudOpenAI:
            return "Cloud"
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
    /// When true, the caller (e.g. full-duplex `VoiceChatSession`) owns the `AVAudioSession`.
    var preservesExternalAudioSession: Bool { get set }
    /// Optional external audio engine sink for hardware-AEC-aligned playback during voice calls.
    var externalOutputSink: (any VoiceAudioOutputSink)? { get set }
    /// Maximum character budget for coalescing consecutive queued sentences into one utterance.
    /// `0` keeps strict one-sentence-per-call delivery.
    var preferredBatchCharacterLimit: Int { get }

    /// Lists voices supported by this engine.
    func availableVoices() -> [TTSVoiceInfo]

    /// Synthesizes and plays a single utterance, suspending until playback finishes or is stopped.
    /// Throws `CancellationError` if interrupted via `stop()` or task cancellation.
    func speak(text: String, voiceID: String?, rate: Double) async throws

    /// Immediately halts current playback.
    func stop()

    /// Releases or deactivates any underlying audio session once a playback batch completes.
    func endPlaybackSession()

    /// Optionally prepares synthesis infrastructure ahead of a voice call without activating audio sessions.
    func prewarm()
}

public extension TTSEngine {
    var isReady: Bool { true }
    var preservesExternalAudioSession: Bool {
        get { false }
        set {}
    }
    var externalOutputSink: (any VoiceAudioOutputSink)? {
        get { nil }
        set {}
    }
    var preferredBatchCharacterLimit: Int { 0 }
    func endPlaybackSession() {}
    func prewarm() {}
}

/// Optional capability for remote/neural TTS engines that can synthesize audio data ahead of
/// playback so the next chunk is ready before the current utterance ends.
@MainActor
public protocol PrefetchableTTSEngine: TTSEngine {
    func synthesize(text: String, voiceID: String?, rate: Double) async throws -> Data
    func play(synthesizedData data: Data) async throws
}
