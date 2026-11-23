// SPDX-License-Identifier: MIT

import Foundation
import Observation

/// Coordinates real-time sentence-by-sentence TTS playback during streaming generation
/// as well as on-demand playback for individual completed messages.
///
/// Mirrors OGAM's streaming speech state machine:
/// - Streams answer text incrementally through `SentenceSegmenter` into a FIFO speech queue.
/// - Flushes trailing partial clauses on stream completion.
/// - Supports instant interruption (`stop`) with single-turn suppression so remaining tokens
///   of a cancelled/muted reply never re-trigger audio output.
@MainActor
@Observable
public final class StreamingSpeechCoordinator {
    public private(set) var isSpeaking: Bool = false
    public private(set) var speakingMessageID: UUID?
    public private(set) var isSuppressedForCurrentTurn: Bool = false
    /// When true, streaming responses are always spoken regardless of `settings.autoSpeakResponses`,
    /// and the active audio session is preserved across turns for full-duplex voice chat.
    public var isVoiceCallActive: Bool = false {
        didSet {
            engine.preservesExternalAudioSession = isVoiceCallActive
            cloudEngine?.preservesExternalAudioSession = isVoiceCallActive
        }
    }
    /// Optional external audio sink injected during voice call mode so TTS shares the VPIO `AVAudioEngine`.
    @ObservationIgnored public var externalOutputSink: (any VoiceAudioOutputSink)? {
        didSet {
            engine.externalOutputSink = externalOutputSink
            cloudEngine?.externalOutputSink = externalOutputSink
        }
    }
    /// Invoked when the playback queue finishes draining normally (not cancelled).
    @ObservationIgnored public var onPlaybackFinished: (@MainActor @Sendable () -> Void)?
    /// Currently spoken sentence (useful for live captions / subtitles).
    public private(set) var currentSpokenSentence: String = ""

    public let engine: any TTSEngine
    public var cloudEngine: (any TTSEngine)? {
        didSet {
            cloudEngine?.preservesExternalAudioSession = isVoiceCallActive
            cloudEngine?.externalOutputSink = externalOutputSink
            cloudEngine?.onExternalInterruption = { [weak self] in
                self?.stop(suppressCurrentTurn: true)
            }
        }
    }
    private let settings: AppSettings

    @ObservationIgnored private var segmenter = SentenceSegmenter()
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var activeTurnMessageID: UUID?
    @ObservationIgnored private var hasFedStreamingText: Bool = false
    @ObservationIgnored private var sessionGeneration: UInt64 = 0

    public init(
        engine: (any TTSEngine)? = nil,
        cloudEngine: (any TTSEngine)? = nil,
        settings: AppSettings
    ) {
        self.engine = engine ?? AppleSystemTTSEngine()
        self.cloudEngine = cloudEngine
        self.settings = settings
        self.engine.onExternalInterruption = { [weak self] in
            self?.stop(suppressCurrentTurn: true)
        }
        self.cloudEngine?.onExternalInterruption = { [weak self] in
            self?.stop(suppressCurrentTurn: true)
        }
    }

    /// Returns the currently selected and ready engine, falling back to `engine` (Apple System)
    /// when Cloud TTS is not configured.
    public func activeEngine() -> any TTSEngine {
        if settings.ttsEngineKind == .cloudOpenAI, let cloudEngine, cloudEngine.isReady {
            return cloudEngine
        }
        return engine
    }

    public func availableVoices() -> [TTSVoiceInfo] {
        activeEngine().availableVoices()
    }

    /// Prewarms the underlying TTS backend ahead of a voice call without touching `AVAudioSession`.
    public func prewarmForVoiceCall() {
        engine.prewarm()
        cloudEngine?.prewarm()
    }

    // MARK: - Streaming Turn Lifecycle

    /// Prepares the coordinator for a brand-new assistant response turn.
    public func resetForNewTurn(messageID: UUID?) {
        haltPlayback(suppressCurrentTurn: false)
        isSuppressedForCurrentTurn = false
        activeTurnMessageID = messageID
        hasFedStreamingText = false
    }

    /// Clears buffered partial text when provisional answer output is discarded (e.g. before a tool call).
    public func discardBufferedStream() {
        segmenter.reset()
        hasFedStreamingText = false
    }

    /// Feeds an answer delta emitted by the model. Ignored when auto-speak is off (unless in voice call) or the turn was muted.
    public func feed(delta: String, messageID: UUID?) {
        guard (settings.autoSpeakResponses || isVoiceCallActive), !isSuppressedForCurrentTurn, !delta.isEmpty else { return }
        if let activeTurnMessageID, let messageID, activeTurnMessageID != messageID {
            return
        }
        hasFedStreamingText = true
        let sentences = segmenter.append(delta)
        if !sentences.isEmpty {
            enqueue(sentences, messageID: messageID ?? activeTurnMessageID)
        }
    }

    /// Flushes any remaining buffered tail when generation completes cleanly.
    public func finish(fullText: String? = nil, messageID: UUID?) {
        guard (settings.autoSpeakResponses || isVoiceCallActive), !isSuppressedForCurrentTurn else { return }
        if let activeTurnMessageID, let messageID, activeTurnMessageID != messageID {
            return
        }

        let sentences: [String]
        if hasFedStreamingText {
            sentences = segmenter.finish()
        } else if let fullText, !fullText.isEmpty {
            // Non-streamed paths (e.g. Shortcuts completion) did not feed tokens incrementally.
            var oneShot = SentenceSegmenter()
            sentences = oneShot.append(fullText) + oneShot.finish()
        } else {
            sentences = []
        }

        if !sentences.isEmpty {
            enqueue(sentences, messageID: messageID ?? activeTurnMessageID)
        }
    }

    // MARK: - On-Demand Playback & Controls

    /// Speaks (or stops if already speaking) a specific completed message, ignoring the auto-speak toggle.
    public func toggleSpeakMessage(text: String, messageID: UUID) {
        if isSpeaking && speakingMessageID == messageID {
            stop(suppressCurrentTurn: true)
            return
        }
        speakMessage(text: text, messageID: messageID)
    }

    /// Speaks a full message on demand, segmented sentence by sentence.
    public func speakMessage(text: String, messageID: UUID?) {
        haltPlayback(suppressCurrentTurn: false)
        var oneShot = SentenceSegmenter()
        let sentences = oneShot.append(text) + oneShot.finish()
        guard !sentences.isEmpty else { return }
        enqueue(sentences, messageID: messageID)
    }

    /// Toggles the global auto-speak setting; turning it off also halts any active playback for the turn.
    public func toggleAutoSpeak() {
        let next = !settings.autoSpeakResponses
        settings.autoSpeakResponses = next
        if !next {
            stop(suppressCurrentTurn: true)
        }
    }

    /// Immediately stops audio output and clears pending segments.
    /// Pass `suppressCurrentTurn: true` when stopping mid-generation so trailing tokens stay silent.
    public func stop(suppressCurrentTurn: Bool = true) {
        haltPlayback(suppressCurrentTurn: suppressCurrentTurn)
    }

    // MARK: - Queue Execution

    private func haltPlayback(suppressCurrentTurn: Bool) {
        sessionGeneration &+= 1
        if suppressCurrentTurn {
            isSuppressedForCurrentTurn = true
        }
        queue.removeAll(keepingCapacity: false)
        segmenter.reset()
        drainTask?.cancel()
        drainTask = nil
        engine.stop()
        cloudEngine?.stop()
        if !isVoiceCallActive {
            engine.endPlaybackSession()
            cloudEngine?.endPlaybackSession()
        }
        isSpeaking = false
        speakingMessageID = nil
        currentSpokenSentence = ""
    }

    private func enqueue(_ sentences: [String], messageID: UUID?) {
        guard !sentences.isEmpty else { return }
        queue.append(contentsOf: sentences)
        if speakingMessageID == nil {
            speakingMessageID = messageID
        }
        isSpeaking = true
        ensureDraining()
    }

    private func ensureDraining() {
        guard drainTask == nil else { return }
        let generation = sessionGeneration

        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var targetEngine = self.activeEngine()
            var usingCloud = targetEngine === self.cloudEngine
            var preferredVoiceID: String? = usingCloud
                ? self.settings.cloudTTSVoice
                : self.settings.ttsVoiceIdentifier
            var consecutiveFailures = 0

            while self.sessionGeneration == generation, !Task.isCancelled, !self.queue.isEmpty {
                let nextSentence = self.queue.removeFirst()
                self.currentSpokenSentence = nextSentence
                do {
                    try await targetEngine.speak(
                        text: nextSentence,
                        voiceID: preferredVoiceID,
                        rate: self.settings.ttsSpeechRate
                    )
                    consecutiveFailures = 0
                } catch is CancellationError {
                    break
                } catch {
                    // Seamless automatic fallback to Apple System Voice if Cloud TTS fails (offline, HTTP error, etc.).
                    if usingCloud {
                        usingCloud = false
                        targetEngine = self.engine
                        preferredVoiceID = self.settings.ttsVoiceIdentifier
                        do {
                            try await self.engine.speak(
                                text: nextSentence,
                                voiceID: preferredVoiceID,
                                rate: self.settings.ttsSpeechRate
                            )
                            consecutiveFailures = 0
                            continue
                        } catch is CancellationError {
                            break
                        } catch {
                            consecutiveFailures += 1
                        }
                    } else {
                        consecutiveFailures += 1
                    }

                    // Abort draining after 2 consecutive engine failures to prevent wedged loops.
                    if consecutiveFailures >= 2 {
                        self.queue.removeAll(keepingCapacity: false)
                        break
                    }
                }
            }

            guard self.sessionGeneration == generation else { return }
            self.drainTask = nil
            self.isSpeaking = false
            self.speakingMessageID = nil
            self.currentSpokenSentence = ""
            if !self.isVoiceCallActive {
                targetEngine.endPlaybackSession()
            }
            self.onPlaybackFinished?()
        }
    }
}
