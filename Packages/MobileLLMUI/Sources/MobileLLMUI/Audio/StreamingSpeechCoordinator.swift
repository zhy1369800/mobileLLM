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
            localMLXEngine?.preservesExternalAudioSession = isVoiceCallActive
            cloudEngine?.preservesExternalAudioSession = isVoiceCallActive
        }
    }
    /// Optional external audio sink injected during voice call mode so TTS shares the VPIO `AVAudioEngine`.
    @ObservationIgnored public var externalOutputSink: (any VoiceAudioOutputSink)? {
        didSet {
            engine.externalOutputSink = externalOutputSink
            localMLXEngine?.externalOutputSink = externalOutputSink
            cloudEngine?.externalOutputSink = externalOutputSink
        }
    }
    /// Invoked when the playback queue finishes draining normally (not cancelled).
    @ObservationIgnored public var onPlaybackFinished: (@MainActor @Sendable () -> Void)?
    /// Currently spoken sentence (useful for live captions / subtitles).
    public private(set) var currentSpokenSentence: String = ""
    /// Last playback error surfaced when fallback is disabled (e.g. Settings "Test voice" preview).
    public private(set) var lastPlaybackError: String?

    public let engine: any TTSEngine
    public var localMLXEngine: (any TTSEngine)? {
        didSet {
            localMLXEngine?.preservesExternalAudioSession = isVoiceCallActive
            localMLXEngine?.externalOutputSink = externalOutputSink
            localMLXEngine?.onExternalInterruption = { [weak self] in
                self?.stop(suppressCurrentTurn: true)
            }
        }
    }
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

    private struct PrefetchedChunk {
        let text: String
        let voiceID: String?
        let rate: Double
        let task: Task<Data, Error>
    }

    private enum DrainEngineKind {
        case appleSystem
        case localMLX
        case cloudOpenAI
    }

    private struct ActiveDrainContext {
        let generation: UInt64
        var engine: any TTSEngine
        var engineKind: DrainEngineKind
        var isPlayingCurrent: Bool
        var allowFallback: Bool
    }

    private enum SpeechScript {
        case han
        case japanese
        case korean
        case otherLetter
        case neutral
    }

    @ObservationIgnored private var segmenter = SentenceSegmenter()
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var activeTurnMessageID: UUID?
    @ObservationIgnored private var hasFedStreamingText: Bool = false
    @ObservationIgnored private var sessionGeneration: UInt64 = 0
    @ObservationIgnored private var prefetchedChunk: PrefetchedChunk?
    @ObservationIgnored private var activeDrainContext: ActiveDrainContext?
    @ObservationIgnored private var isCurrentBatchComplete: Bool = false
    @ObservationIgnored private var allowFallbackForActiveBatch: Bool = true

    private let voiceCallBatchCharacterLimit = 100
    private let streamingPrefetchMinCharacters = 80
    private let voiceCallStreamingPrefetchMinCharacters = 60

    public init(
        engine: (any TTSEngine)? = nil,
        localMLXEngine: (any TTSEngine)? = nil,
        cloudEngine: (any TTSEngine)? = nil,
        settings: AppSettings
    ) {
        self.engine = engine ?? AppleSystemTTSEngine()
        self.localMLXEngine = localMLXEngine
        self.cloudEngine = cloudEngine
        self.settings = settings
        self.engine.onExternalInterruption = { [weak self] in
            self?.stop(suppressCurrentTurn: true)
        }
        self.localMLXEngine?.onExternalInterruption = { [weak self] in
            self?.stop(suppressCurrentTurn: true)
        }
        self.cloudEngine?.onExternalInterruption = { [weak self] in
            self?.stop(suppressCurrentTurn: true)
        }
    }

    /// Returns the currently selected and ready engine, falling back to `engine` (Apple System)
    /// when Local MLX or Cloud TTS is not ready.
    public func activeEngine() -> any TTSEngine {
        selectedEngine(allowFallback: true)?.engine ?? engine
    }

    private func selectedEngine(allowFallback: Bool) -> (engine: any TTSEngine, kind: DrainEngineKind)? {
        switch settings.ttsEngineKind {
        case .cloudOpenAI:
            if let cloudEngine, cloudEngine.isReady {
                return (cloudEngine, .cloudOpenAI)
            }
            return allowFallback ? (engine, .appleSystem) : nil
        case .localMLX:
            if let localMLXEngine, localMLXEngine.isReady {
                return (localMLXEngine, .localMLX)
            }
            return allowFallback ? (engine, .appleSystem) : nil
        case .appleSystem:
            return (engine, .appleSystem)
        }
    }

    private func selectedEngineUnavailableMessage() -> String {
        switch settings.ttsEngineKind {
        case .localMLX:
            return "Local MLX voice engine is not ready. Download a local voice model on an Apple Silicon device."
        case .cloudOpenAI:
            return "Cloud TTS is not configured. Check Base URL and API Key."
        case .appleSystem:
            return "Apple System Voice is currently unavailable."
        }
    }

    public func clearPlaybackError() {
        lastPlaybackError = nil
    }

    public func availableVoices() -> [TTSVoiceInfo] {
        activeEngine().availableVoices()
    }

    /// Prewarms the underlying TTS backend ahead of a voice call without touching `AVAudioSession`.
    public func prewarmForVoiceCall() {
        engine.prewarm()
        if settings.ttsEngineKind == .localMLX {
            localMLXEngine?.prewarm()
        }
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
        isCurrentBatchComplete = false
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

        isCurrentBatchComplete = true
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
        } else {
            maybeSchedulePrefetch()
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
    public func speakMessage(text: String, messageID: UUID?, allowFallback: Bool = true) {
        haltPlayback(suppressCurrentTurn: false)
        if !allowFallback && selectedEngine(allowFallback: false) == nil {
            lastPlaybackError = selectedEngineUnavailableMessage()
            return
        }
        allowFallbackForActiveBatch = allowFallback
        isCurrentBatchComplete = true
        var oneShot = SentenceSegmenter()
        let sentences = oneShot.append(text) + oneShot.finish()
        guard !sentences.isEmpty else {
            isCurrentBatchComplete = false
            allowFallbackForActiveBatch = true
            return
        }
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
        isCurrentBatchComplete = false
        allowFallbackForActiveBatch = true
        lastPlaybackError = nil
        activeDrainContext = nil
        cancelPrefetch()
        queue.removeAll(keepingCapacity: false)
        segmenter.reset()
        drainTask?.cancel()
        drainTask = nil
        engine.stop()
        localMLXEngine?.stop()
        cloudEngine?.stop()
        if !isVoiceCallActive {
            engine.endPlaybackSession()
            localMLXEngine?.endPlaybackSession()
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
        maybeSchedulePrefetch()
    }

    private func ensureDraining() {
        guard drainTask == nil else { return }
        let generation = sessionGeneration
        let allowFallback = allowFallbackForActiveBatch

        guard let resolved = selectedEngine(allowFallback: allowFallback) else {
            queue.removeAll(keepingCapacity: false)
            isCurrentBatchComplete = false
            isSpeaking = false
            speakingMessageID = nil
            lastPlaybackError = selectedEngineUnavailableMessage()
            return
        }

        let initialEngine = resolved.engine
        let initialKind = resolved.kind
        self.activeDrainContext = ActiveDrainContext(
            generation: generation,
            engine: initialEngine,
            engineKind: initialKind,
            isPlayingCurrent: false,
            allowFallback: allowFallback
        )

        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var consecutiveFailures = 0

            while self.sessionGeneration == generation,
                  !Task.isCancelled,
                  (self.prefetchedChunk != nil || !self.queue.isEmpty)
            {
                let ctx = self.activeDrainContext
                var targetEngine = ctx?.engine ?? self.activeEngine()
                var engineKind = ctx?.engineKind ?? self.drainEngineKind(for: targetEngine)
                var preferredVoiceID = self.currentPreferredVoiceID(for: engineKind)
                let splitScripts = self.shouldSplitScripts(for: engineKind, preferredVoiceID: preferredVoiceID)
                var currentTextToSpeak: String?

                do {
                    if let prefetchEngine = targetEngine as? any PrefetchableTTSEngine {
                        let nextText: String
                        let audioData: Data
                        if let prefetched = self.prefetchedChunk {
                            self.prefetchedChunk = nil
                            nextText = prefetched.text
                            currentTextToSpeak = nextText
                            if prefetched.voiceID == preferredVoiceID,
                               abs(prefetched.rate - self.settings.ttsSpeechRate) < 0.001
                            {
                                audioData = try await prefetched.task.value
                            } else {
                                prefetched.task.cancel()
                                audioData = try await prefetchEngine.synthesize(
                                    text: nextText,
                                    voiceID: preferredVoiceID,
                                    rate: self.settings.ttsSpeechRate
                                )
                            }
                        } else {
                            nextText = self.dequeueNextBatch(
                                maxCharacters: self.effectiveBatchCharacterLimit(for: prefetchEngine),
                                splitOnScriptChange: splitScripts
                            )
                            currentTextToSpeak = nextText
                            audioData = try await prefetchEngine.synthesize(
                                text: nextText,
                                voiceID: preferredVoiceID,
                                rate: self.settings.ttsSpeechRate
                            )
                        }

                        guard self.sessionGeneration == generation, !Task.isCancelled else { break }

                        self.currentSpokenSentence = nextText
                        self.activeDrainContext?.isPlayingCurrent = true
                        self.maybeSchedulePrefetch()
                        defer { self.activeDrainContext?.isPlayingCurrent = false }
                        try await prefetchEngine.play(synthesizedData: audioData)
                    } else {
                        let nextText = self.dequeueNextBatch(
                            maxCharacters: self.effectiveBatchCharacterLimit(for: targetEngine),
                            splitOnScriptChange: splitScripts
                        )
                        currentTextToSpeak = nextText
                        self.currentSpokenSentence = nextText
                        try await targetEngine.speak(
                            text: nextText,
                            voiceID: preferredVoiceID,
                            rate: self.settings.ttsSpeechRate
                        )
                    }
                    consecutiveFailures = 0
                } catch is CancellationError {
                    break
                } catch {
                    if Task.isCancelled || self.sessionGeneration != generation {
                        break
                    }
                    self.requeuePrefetchAndCancel()

                    let allowFallback = self.activeDrainContext?.allowFallback ?? true
                    if !allowFallback {
                        self.lastPlaybackError = error.localizedDescription
                        self.queue.removeAll(keepingCapacity: false)
                        self.cancelPrefetch()
                        break
                    }

                    // Seamless automatic fallback to Apple System Voice if Cloud/Local MLX TTS fails.
                    if engineKind != .appleSystem, let fallbackText = currentTextToSpeak {
                        engineKind = .appleSystem
                        targetEngine = self.engine
                        preferredVoiceID = self.currentPreferredVoiceID(for: .appleSystem)
                        self.activeDrainContext = ActiveDrainContext(
                            generation: generation,
                            engine: targetEngine,
                            engineKind: .appleSystem,
                            isPlayingCurrent: false,
                            allowFallback: true
                        )
                        do {
                            self.currentSpokenSentence = fallbackText
                            try await self.engine.speak(
                                text: fallbackText,
                                voiceID: preferredVoiceID,
                                rate: self.settings.ttsSpeechRate
                            )
                            consecutiveFailures = 0
                            continue
                        } catch is CancellationError {
                            break
                        } catch {
                            guard !Task.isCancelled, self.sessionGeneration == generation else { break }
                            consecutiveFailures += 1
                        }
                    } else {
                        consecutiveFailures += 1
                    }

                    // Abort draining after 2 consecutive engine failures to prevent wedged loops.
                    if consecutiveFailures >= 2 {
                        self.queue.removeAll(keepingCapacity: false)
                        self.cancelPrefetch()
                        break
                    }
                }
            }

            guard self.sessionGeneration == generation else { return }
            let endingEngine = self.activeDrainContext?.engine ?? initialEngine
            self.cancelPrefetch()
            self.activeDrainContext = nil
            self.isCurrentBatchComplete = false
            self.allowFallbackForActiveBatch = true
            self.drainTask = nil
            self.isSpeaking = false
            self.speakingMessageID = nil
            self.currentSpokenSentence = ""
            if !self.isVoiceCallActive {
                endingEngine.endPlaybackSession()
            }
            self.onPlaybackFinished?()
        }
    }

    private func drainEngineKind(for targetEngine: any TTSEngine) -> DrainEngineKind {
        if targetEngine === cloudEngine { return .cloudOpenAI }
        if targetEngine === localMLXEngine { return .localMLX }
        return .appleSystem
    }

    private func currentPreferredVoiceID(for kind: DrainEngineKind) -> String? {
        switch kind {
        case .cloudOpenAI:
            return settings.cloudTTSVoice
        case .localMLX:
            return settings.localMLXVoiceID
        case .appleSystem:
            return settings.ttsVoiceIdentifier
        }
    }

    private func shouldSplitScripts(for kind: DrainEngineKind, preferredVoiceID: String?) -> Bool {
        kind == .appleSystem && (preferredVoiceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func effectiveBatchCharacterLimit(for engine: any TTSEngine) -> Int {
        let base = engine.preferredBatchCharacterLimit
        guard base > 0 else { return 0 }
        return isVoiceCallActive ? min(base, voiceCallBatchCharacterLimit) : base
    }

    private func dequeueNextBatch(maxCharacters: Int, splitOnScriptChange: Bool = false) -> String {
        var batch = queue.removeFirst()
        guard maxCharacters > 0 else { return batch }

        var batchScript = splitOnScriptChange ? Self.dominantScript(of: batch) : .neutral
        while let next = queue.first {
            if splitOnScriptChange {
                let nextScript = Self.dominantScript(of: next)
                if batchScript != .neutral && nextScript != .neutral && batchScript != nextScript {
                    break
                }
                if batchScript == .neutral {
                    batchScript = nextScript
                }
            }
            let separator = Self.joinSeparator(between: batch, and: next)
            if batch.count + separator.count + next.count <= maxCharacters {
                queue.removeFirst()
                batch += separator + next
            } else {
                break
            }
        }
        return batch
    }

    private func queuedCharacterCount() -> Int {
        queue.reduce(0) { $0 + $1.count }
    }

    private func maybeSchedulePrefetch() {
        guard prefetchedChunk == nil,
              !queue.isEmpty,
              let ctx = activeDrainContext,
              ctx.generation == sessionGeneration,
              ctx.isPlayingCurrent,
              let prefetchEngine = ctx.engine as? any PrefetchableTTSEngine else {
            return
        }
        let effectiveLimit = effectiveBatchCharacterLimit(for: prefetchEngine)
        let baseMinPrefetchChars = isVoiceCallActive
            ? voiceCallStreamingPrefetchMinCharacters
            : streamingPrefetchMinCharacters
        let minPrefetchChars = effectiveLimit > 0
            ? min(baseMinPrefetchChars, effectiveLimit)
            : baseMinPrefetchChars
        guard isCurrentBatchComplete || queuedCharacterCount() >= minPrefetchChars else {
            return
        }

        let voiceID = currentPreferredVoiceID(for: ctx.engineKind)
        let splitScripts = shouldSplitScripts(for: ctx.engineKind, preferredVoiceID: voiceID)
        let nextText = dequeueNextBatch(
            maxCharacters: effectiveBatchCharacterLimit(for: prefetchEngine),
            splitOnScriptChange: splitScripts
        )
        let rate = settings.ttsSpeechRate
        let task = Task<Data, Error> { @MainActor in
            try await prefetchEngine.synthesize(text: nextText, voiceID: voiceID, rate: rate)
        }
        prefetchedChunk = PrefetchedChunk(text: nextText, voiceID: voiceID, rate: rate, task: task)
    }

    private func cancelPrefetch() {
        prefetchedChunk?.task.cancel()
        prefetchedChunk = nil
    }

    private func requeuePrefetchAndCancel() {
        guard let prefetched = prefetchedChunk else { return }
        prefetchedChunk = nil
        prefetched.task.cancel()
        queue.insert(prefetched.text, at: 0)
    }

    private static let terminalOrPausePunctuation: Set<Character> = [
        "。", "！", "？", "!", "?", "…", "；", ";", "：", ":", "，", ",", ".",
        "）", ")", "」", "』", "\"", "'", "”", "’", "】", "》"
    ]

    private static func joinSeparator(between lhs: String, and rhs: String) -> String {
        guard let last = lhs.last else { return "" }
        if terminalOrPausePunctuation.contains(last) {
            if last.isASCII && rhs.first?.isASCII == true {
                return " "
            }
            return ""
        }
        return (containsCJK(lhs) || containsCJK(rhs)) ? "。" : ". "
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
    }

    private static func dominantScript(of text: String) -> SpeechScript {
        var hanCount = 0
        var japaneseCount = 0
        var koreanCount = 0
        var otherCount = 0

        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x30FF).contains(v) {
                japaneseCount += 1
            } else if (0xAC00...0xD7AF).contains(v) {
                koreanCount += 1
            } else if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                hanCount += 1
            } else if scalar.properties.isAlphabetic {
                otherCount += 1
            }
        }

        if japaneseCount > 0 {
            return .japanese
        }
        if koreanCount > 0 {
            return .korean
        }
        if hanCount == 0 && otherCount == 0 {
            return .neutral
        }
        return hanCount >= otherCount ? .han : .otherLetter
    }
}
