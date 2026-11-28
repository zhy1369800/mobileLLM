// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

@MainActor
private final class MockTTSEngine: TTSEngine {
    let id = "mock-tts"
    let displayName = "Mock TTS"
    private(set) var isSpeaking = false
    var isReady = true
    var preservesExternalAudioSession = false
    var onExternalInterruption: (@MainActor @Sendable () -> Void)?
    var preferredBatchCharacterLimit: Int = 0
    private(set) var spokenSegments: [String] = []
    private(set) var lastVoiceID: String?
    private(set) var stopCount = 0
    private(set) var endSessionCount = 0

    var shouldHang = false
    var consecutiveErrorsRemaining = 0

    private var activeContinuation: CheckedContinuation<Void, Error>?

    func availableVoices() -> [TTSVoiceInfo] {
        [
            TTSVoiceInfo(id: "voice-zh", name: "Tingting", language: "zh-CN", qualityLabel: "Enhanced"),
            TTSVoiceInfo(id: "voice-en", name: "Samantha", language: "en-US"),
        ]
    }

    func speak(text: String, voiceID: String?, rate: Double) async throws {
        if consecutiveErrorsRemaining > 0 {
            consecutiveErrorsRemaining -= 1
            throw NSError(domain: "MockTTSEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic failure"])
        }
        spokenSegments.append(text)
        lastVoiceID = voiceID
        guard shouldHang else { return }

        isSpeaking = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.activeContinuation = cont
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
    }

    func stop() {
        stopCount += 1
        isSpeaking = false
        let cont = activeContinuation
        activeContinuation = nil
        cont?.resume(throwing: CancellationError())
    }

    func endPlaybackSession() {
        endSessionCount += 1
    }
}

@MainActor
private final class MockPrefetchableTTSEngine: PrefetchableTTSEngine {
    let id = "mock-prefetch-cloud"
    let displayName = "Mock Prefetch Cloud"
    private(set) var isSpeaking = false
    var isReady = true
    var preservesExternalAudioSession = false
    var onExternalInterruption: (@MainActor @Sendable () -> Void)?
    var preferredBatchCharacterLimit: Int

    private(set) var synthesizedSegments: [String] = []
    private(set) var playedSegments: [String] = []
    private(set) var cancelledSynthesizeCount = 0

    var failSynthesizeAtCallIndex: Int?
    var hangPlayOnCallIndex: Int?
    var hangSynthesizeOnCallIndex: Int?

    private var playContinuation: CheckedContinuation<Void, Error>?
    private var synthesizeContinuation: CheckedContinuation<Data, Error>?

    init(preferredBatchCharacterLimit: Int = 280) {
        self.preferredBatchCharacterLimit = preferredBatchCharacterLimit
    }

    func availableVoices() -> [TTSVoiceInfo] { [] }

    func synthesize(text: String, voiceID: String?, rate: Double) async throws -> Data {
        synthesizedSegments.append(text)
        let callIndex = synthesizedSegments.count
        if failSynthesizeAtCallIndex == callIndex {
            throw NSError(domain: "MockPrefetch", code: 500, userInfo: [NSLocalizedDescriptionKey: "Synthetic prefetch failure"])
        }
        if hangSynthesizeOnCallIndex == callIndex {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    self.synthesizeContinuation = cont
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelledSynthesizeCount += 1
                    let cont = self?.synthesizeContinuation
                    self?.synthesizeContinuation = nil
                    cont?.resume(throwing: CancellationError())
                }
            }
        }
        return Data(text.utf8)
    }

    func play(synthesizedData data: Data) async throws {
        let text = String(decoding: data, as: UTF8.self)
        let callIndex = playedSegments.count + 1
        playedSegments.append(text)
        guard hangPlayOnCallIndex == callIndex else { return }

        isSpeaking = true
        defer { isSpeaking = false }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                self.playContinuation = cont
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
    }

    func resumePendingPlay() {
        let cont = playContinuation
        playContinuation = nil
        cont?.resume(returning: ())
    }

    func resumePendingSynthesize(with text: String) {
        let cont = synthesizeContinuation
        synthesizeContinuation = nil
        cont?.resume(returning: Data(text.utf8))
    }

    func speak(text: String, voiceID: String?, rate: Double) async throws {
        let data = try await synthesize(text: text, voiceID: voiceID, rate: rate)
        try await play(synthesizedData: data)
    }

    func stop() {
        isSpeaking = false
        let playCont = playContinuation
        playContinuation = nil
        playCont?.resume(throwing: CancellationError())
    }
}

@MainActor
final class StreamingSpeechTests: XCTestCase {

    private func makeSettings(autoSpeak: Bool = true) -> AppSettings {
        let suite = "streaming-speech-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults, keychain: nil)
        settings.autoSpeakResponses = autoSpeak
        return settings
    }

    // MARK: - SentenceSegmenter

    func testSegmenterSplitsChineseAndEnglishIncrementally() {
        var segmenter = SentenceSegmenter()
        XCTAssertEqual(segmenter.append("你好，这是第一句"), [])
        XCTAssertEqual(segmenter.append("。Second sen"), ["你好，这是第一句。"])
        XCTAssertEqual(segmenter.append("tence! Tail"), ["Second sentence!"])
        XCTAssertEqual(segmenter.finish(), ["Tail"])
    }

    func testSegmenterPreservesDecimalsAndNumberedLists() {
        var segmenter = SentenceSegmenter()
        let full = "Pi is 3.14 and version is v1.2. 1. First item. "
        var streamed: [String] = []
        for ch in full {
            streamed.append(contentsOf: segmenter.append(String(ch)))
        }
        streamed.append(contentsOf: segmenter.finish())
        XCTAssertEqual(streamed, ["Pi is 3.14 and version is v1.2.", "1. First item."])
    }

    func testSegmenterWithholdsThinkingAndToolCalls() {
        var segmenter = SentenceSegmenter()
        let raw = "Sure, checking. <tool_call>\n{\"name\": \"search\", \"q\": \"a. b. c\"}\n</tool_call> Here is the result."
        var emitted: [String] = []
        for ch in raw {
            emitted.append(contentsOf: segmenter.append(String(ch)))
        }
        emitted.append(contentsOf: segmenter.finish())

        let joined = emitted.joined(separator: " ")
        XCTAssertTrue(joined.contains("Sure, checking."))
        XCTAssertTrue(joined.contains("Here is the result."))
        XCTAssertFalse(joined.contains("tool_call"))
        XCTAssertFalse(joined.contains("search"))
    }

    func testSegmenterWithholdsInlineThinkingUntilClosed() {
        var segmenter = SentenceSegmenter()
        XCTAssertEqual(segmenter.append("<think>Internal reasoning. Still thinking."), [])
        XCTAssertEqual(segmenter.append("</think>Final answer. "), ["Final answer."])
    }

    func testSegmenterCleansMarkdownAndSkipsCodeFences() {
        var segmenter = SentenceSegmenter()
        let text = "## Title\nLook at ![chart](https://example.com/c.png) and [this doc](https://example.com) and **bold**.\n```swift\nlet x = 1\n```\nDone!"
        let out = segmenter.append(text) + segmenter.finish()
        XCTAssertEqual(out, ["Title", "Look at chart and this doc and bold.", "Done!"])
    }

    // MARK: - StreamingSpeechCoordinator

    func testCoordinatorIgnoresTokensWhenAutoSpeakDisabled() async {
        let settings = makeSettings(autoSpeak: false)
        let engine = MockTTSEngine()
        let coordinator = StreamingSpeechCoordinator(engine: engine, settings: settings)
        let msgID = UUID()

        coordinator.resetForNewTurn(messageID: msgID)
        coordinator.feed(delta: "Hello world.", messageID: msgID)
        coordinator.finish(fullText: "Hello world.", messageID: msgID)
        await Task.yield()

        XCTAssertEqual(engine.spokenSegments, [])
        XCTAssertFalse(coordinator.isSpeaking)
    }

    func testCoordinatorStreamsAndFlushesTail() async {
        let settings = makeSettings(autoSpeak: true)
        let engine = MockTTSEngine()
        let coordinator = StreamingSpeechCoordinator(engine: engine, settings: settings)
        let msgID = UUID()

        coordinator.resetForNewTurn(messageID: msgID)
        coordinator.feed(delta: "First sentence. Second", messageID: msgID)
        coordinator.finish(fullText: nil, messageID: msgID)

        for _ in 0..<10 where coordinator.isSpeaking {
            await Task.yield()
        }

        XCTAssertEqual(engine.spokenSegments, ["First sentence.", "Second"])
        XCTAssertFalse(coordinator.isSpeaking)
    }

    func testCoordinatorStopSuppressesRestOfTurnUntilReset() async {
        let settings = makeSettings(autoSpeak: true)
        let engine = MockTTSEngine()
        engine.shouldHang = true
        let coordinator = StreamingSpeechCoordinator(engine: engine, settings: settings)
        let turn1 = UUID()

        coordinator.resetForNewTurn(messageID: turn1)
        coordinator.feed(delta: "One. ", messageID: turn1)
        await Task.yield()
        XCTAssertTrue(coordinator.isSpeaking)

        coordinator.stop(suppressCurrentTurn: true)
        XCTAssertFalse(coordinator.isSpeaking)
        XCTAssertTrue(coordinator.isSuppressedForCurrentTurn)

        // Further tokens in the same turn stay silent.
        engine.shouldHang = false
        coordinator.feed(delta: "Two. Three.", messageID: turn1)
        coordinator.finish(fullText: nil, messageID: turn1)
        await Task.yield()
        XCTAssertEqual(engine.spokenSegments, ["One."])

        // A new turn clears suppression and speaks again.
        let turn2 = UUID()
        coordinator.resetForNewTurn(messageID: turn2)
        XCTAssertFalse(coordinator.isSuppressedForCurrentTurn)
        coordinator.feed(delta: "Fresh turn.", messageID: turn2)
        coordinator.finish(fullText: nil, messageID: turn2)
        for _ in 0..<10 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(engine.spokenSegments, ["One.", "Fresh turn."])
        XCTAssertGreaterThan(engine.endSessionCount, 0)
    }

    func testOnDemandToggleSpeakMessageWorksWhenAutoSpeakIsOff() async {
        let settings = makeSettings(autoSpeak: false)
        let engine = MockTTSEngine()
        let coordinator = StreamingSpeechCoordinator(engine: engine, settings: settings)
        let msgID = UUID()

        coordinator.toggleSpeakMessage(text: "Manual play.", messageID: msgID)
        for _ in 0..<10 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(engine.spokenSegments, ["Manual play."])
    }

    func testCoordinatorAbortsAfterTwoConsecutiveFailures() async {
        let settings = makeSettings(autoSpeak: true)
        let engine = MockTTSEngine()
        engine.consecutiveErrorsRemaining = 3
        let coordinator = StreamingSpeechCoordinator(engine: engine, settings: settings)
        let msgID = UUID()

        coordinator.resetForNewTurn(messageID: msgID)
        coordinator.feed(delta: "One. Two. Three.", messageID: msgID)
        for _ in 0..<20 where coordinator.isSpeaking {
            await Task.yield()
        }

        XCTAssertFalse(coordinator.isSpeaking)
        XCTAssertEqual(engine.spokenSegments, [])
    }

    func testSettingsPersistSpeechPreferences() {
        let suite = "speech-settings-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        let first = AppSettings(defaults: defaults, keychain: nil)
        first.autoSpeakResponses = true
        first.ttsSpeechRate = 1.4
        first.ttsVoiceIdentifier = "com.apple.voice.enhanced.zh-CN.Tingting"
        first.ttsEngineKind = .cloudOpenAI
        first.cloudTTSBaseURL = "https://api.siliconflow.cn/v1"
        first.cloudTTSModel = "FunAudioLLM/CosyVoice2-0.5B"
        first.cloudTTSVoice = "FunAudioLLM/CosyVoice2-0.5B:alex"

        let reloaded = AppSettings(defaults: defaults, keychain: nil)
        XCTAssertTrue(reloaded.autoSpeakResponses)
        XCTAssertEqual(reloaded.ttsSpeechRate, 1.4, accuracy: 0.001)
        XCTAssertEqual(reloaded.ttsVoiceIdentifier, "com.apple.voice.enhanced.zh-CN.Tingting")
        XCTAssertEqual(reloaded.ttsEngineKind, .cloudOpenAI)
        XCTAssertEqual(reloaded.cloudTTSBaseURL, "https://api.siliconflow.cn/v1")
        XCTAssertEqual(reloaded.cloudTTSModel, "FunAudioLLM/CosyVoice2-0.5B")
        XCTAssertEqual(reloaded.cloudTTSVoice, "FunAudioLLM/CosyVoice2-0.5B:alex")
    }

    func testExternalInterruptionStopsAndSuppressesTurn() async {
        let settings = makeSettings(autoSpeak: true)
        let engine = MockTTSEngine()
        engine.shouldHang = true
        let coordinator = StreamingSpeechCoordinator(engine: engine, settings: settings)
        let turnID = UUID()

        coordinator.resetForNewTurn(messageID: turnID)
        coordinator.feed(delta: "Speaking before call. ", messageID: turnID)
        await Task.yield()
        XCTAssertTrue(coordinator.isSpeaking)

        // Simulate phone call / headphone unplug interruption callback
        engine.onExternalInterruption?()
        XCTAssertFalse(coordinator.isSpeaking)
        XCTAssertTrue(coordinator.isSuppressedForCurrentTurn)

        engine.shouldHang = false
        coordinator.feed(delta: "Should stay silent. ", messageID: turnID)
        await Task.yield()
        XCTAssertEqual(engine.spokenSegments, ["Speaking before call."])
    }

    func testCloudSpeechEndpointResolution() {
        XCTAssertEqual(
            CloudTTSEngine.speechEndpoint(from: "https://api.openai.com/v1")?.absoluteString,
            "https://api.openai.com/v1/audio/speech"
        )
        XCTAssertEqual(
            CloudTTSEngine.speechEndpoint(from: "https://api.siliconflow.cn")?.absoluteString,
            "https://api.siliconflow.cn/v1/audio/speech"
        )
        XCTAssertEqual(
            CloudTTSEngine.speechEndpoint(from: "https://example.com/custom/v1/audio/speech/")?.absoluteString,
            "https://example.com/custom/v1/audio/speech"
        )
        XCTAssertNil(CloudTTSEngine.speechEndpoint(from: ""))
    }

    func testCloudTTSRoutingAndSeamlessFallbackToAppleOnFailure() async {
        let settings = makeSettings(autoSpeak: true)
        settings.ttsEngineKind = .cloudOpenAI
        settings.cloudTTSVoice = "nova"
        settings.ttsVoiceIdentifier = "voice-zh"

        let appleEngine = MockTTSEngine()
        let cloudEngine = MockTTSEngine()
        cloudEngine.isReady = false

        let coordinator = StreamingSpeechCoordinator(
            engine: appleEngine,
            cloudEngine: cloudEngine,
            settings: settings
        )

        // 1. Not configured yet -> falls back to Apple engine directly.
        coordinator.speakMessage(text: "Unconfigured fallback.", messageID: UUID())
        for _ in 0..<10 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(appleEngine.spokenSegments, ["Unconfigured fallback."])
        XCTAssertEqual(cloudEngine.spokenSegments, [])

        // 2. Configured and ready -> routes to Cloud TTS with configured voice.
        cloudEngine.isReady = true
        coordinator.speakMessage(text: "Cloud speaks.", messageID: UUID())
        for _ in 0..<10 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(cloudEngine.spokenSegments, ["Cloud speaks."])
        XCTAssertEqual(cloudEngine.lastVoiceID, "nova")

        // 3. Network/HTTP failure mid-batch -> immediately replays failed sentence and remaining queue on Apple engine.
        cloudEngine.consecutiveErrorsRemaining = 1
        coordinator.speakMessage(text: "First failed. Second continues.", messageID: UUID())
        for _ in 0..<20 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(appleEngine.spokenSegments, ["Unconfigured fallback.", "First failed.", "Second continues."])
    }

    func testVoiceCallModeOverridesAutoSpeakAndPreservesAudioSession() async {
        let settings = makeSettings(autoSpeak: false)
        let engine = MockTTSEngine()
        let coordinator = StreamingSpeechCoordinator(engine: engine, settings: settings)
        let msgID = UUID()
        var finishedCalled = false

        coordinator.isVoiceCallActive = true
        coordinator.onPlaybackFinished = {
            finishedCalled = true
        }

        coordinator.resetForNewTurn(messageID: msgID)
        coordinator.feed(delta: "Voice call reply.", messageID: msgID)
        coordinator.finish(fullText: nil, messageID: msgID)

        for _ in 0..<10 where coordinator.isSpeaking {
            await Task.yield()
        }

        XCTAssertEqual(engine.spokenSegments, ["Voice call reply."])
        XCTAssertTrue(finishedCalled)
        XCTAssertEqual(engine.endSessionCount, 0)
        XCTAssertTrue(engine.preservesExternalAudioSession)

        coordinator.isVoiceCallActive = false
        XCTAssertFalse(engine.preservesExternalAudioSession)
    }

    func testBatchCoalescingJoinsShortSentencesAndInsertsPunctuationForHeadings() async {
        let settings = makeSettings(autoSpeak: false)
        settings.ttsEngineKind = .cloudOpenAI
        let cloudEngine = MockPrefetchableTTSEngine(preferredBatchCharacterLimit: 280)
        let coordinator = StreamingSpeechCoordinator(
            engine: MockTTSEngine(),
            cloudEngine: cloudEngine,
            settings: settings
        )

        coordinator.speakMessage(text: "## 核心能力\n第一句。\n第二句！", messageID: UUID())
        for _ in 0..<15 where coordinator.isSpeaking {
            await Task.yield()
        }

        XCTAssertEqual(cloudEngine.synthesizedSegments, ["核心能力。第一句。第二句！"])
        XCTAssertEqual(cloudEngine.playedSegments, ["核心能力。第一句。第二句！"])
    }

    func testPrefetchableEngineSynthesizesNextChunkWhileCurrentPlays() async {
        let settings = makeSettings(autoSpeak: false)
        settings.ttsEngineKind = .cloudOpenAI
        let cloudEngine = MockPrefetchableTTSEngine(preferredBatchCharacterLimit: 15)
        cloudEngine.hangPlayOnCallIndex = 1
        let coordinator = StreamingSpeechCoordinator(
            engine: MockTTSEngine(),
            cloudEngine: cloudEngine,
            settings: settings
        )

        coordinator.speakMessage(text: "第一段内容需要足够长一点才行。第二段紧接着自动开始。", messageID: UUID())
        for _ in 0..<10 where cloudEngine.synthesizedSegments.count < 2 {
            await Task.yield()
        }

        XCTAssertEqual(cloudEngine.synthesizedSegments, ["第一段内容需要足够长一点才行。", "第二段紧接着自动开始。"])
        XCTAssertEqual(cloudEngine.playedSegments, ["第一段内容需要足够长一点才行。"])

        cloudEngine.resumePendingPlay()
        for _ in 0..<15 where coordinator.isSpeaking {
            await Task.yield()
        }

        XCTAssertEqual(cloudEngine.playedSegments, ["第一段内容需要足够长一点才行。", "第二段紧接着自动开始。"])
        XCTAssertFalse(coordinator.isSpeaking)
    }

    func testStopCancelsInFlightPrefetchTask() async {
        let settings = makeSettings(autoSpeak: false)
        settings.ttsEngineKind = .cloudOpenAI
        let cloudEngine = MockPrefetchableTTSEngine(preferredBatchCharacterLimit: 15)
        cloudEngine.hangPlayOnCallIndex = 1
        cloudEngine.hangSynthesizeOnCallIndex = 2
        let coordinator = StreamingSpeechCoordinator(
            engine: MockTTSEngine(),
            cloudEngine: cloudEngine,
            settings: settings
        )

        coordinator.speakMessage(text: "第一段内容需要足够长一点才行。第二段合成将被立即取消。", messageID: UUID())
        for _ in 0..<10 where cloudEngine.synthesizedSegments.count < 2 {
            await Task.yield()
        }

        XCTAssertEqual(cloudEngine.playedSegments, ["第一段内容需要足够长一点才行。"])
        coordinator.stop(suppressCurrentTurn: true)
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertEqual(cloudEngine.cancelledSynthesizeCount, 1)
        XCTAssertEqual(cloudEngine.playedSegments, ["第一段内容需要足够长一点才行。"])
        XCTAssertFalse(coordinator.isSpeaking)
    }

    func testPrefetchFailureFallsBackSeamlesslyToAppleEngine() async {
        let settings = makeSettings(autoSpeak: false)
        settings.ttsEngineKind = .cloudOpenAI
        let appleEngine = MockTTSEngine()
        let cloudEngine = MockPrefetchableTTSEngine(preferredBatchCharacterLimit: 15)
        cloudEngine.failSynthesizeAtCallIndex = 2
        let coordinator = StreamingSpeechCoordinator(
            engine: appleEngine,
            cloudEngine: cloudEngine,
            settings: settings
        )

        coordinator.speakMessage(
            text: "第一段云端内容正常播放完毕。第二段云端预取网络突然失败。第三段苹果系统语音无缝继续。",
            messageID: UUID()
        )
        for _ in 0..<25 where coordinator.isSpeaking {
            await Task.yield()
        }

        XCTAssertEqual(cloudEngine.playedSegments, ["第一段云端内容正常播放完毕。"])
        XCTAssertEqual(appleEngine.spokenSegments, ["第二段云端预取网络突然失败。", "第三段苹果系统语音无缝继续。"])
        XCTAssertFalse(coordinator.isSpeaking)
    }

    func testAppleAutoVoicePreservesScriptBoundariesWhileCoalescingSameScript() async {
        let settings = makeSettings(autoSpeak: false)
        settings.ttsVoiceIdentifier = nil

        let appleEngine = MockTTSEngine()
        appleEngine.preferredBatchCharacterLimit = 180
        let coordinator = StreamingSpeechCoordinator(engine: appleEngine, settings: settings)

        // 1. Auto-voice: bilingual text must not coalesce across Chinese/English script boundaries.
        coordinator.speakMessage(
            text: "这句话翻译成英文是：\nThe quick brown fox.\n谢谢！",
            messageID: UUID()
        )
        for _ in 0..<20 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(
            appleEngine.spokenSegments,
            ["这句话翻译成英文是：", "The quick brown fox.", "谢谢！"]
        )

        // 2. Auto-voice: monolingual Chinese sentences still coalesce into one utterance.
        let monoEngine = MockTTSEngine()
        monoEngine.preferredBatchCharacterLimit = 180
        let monoCoordinator = StreamingSpeechCoordinator(engine: monoEngine, settings: settings)
        monoCoordinator.speakMessage(text: "## 核心能力\n第一句。\n第二句！", messageID: UUID())
        for _ in 0..<15 where monoCoordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(monoEngine.spokenSegments, ["核心能力。第一句。第二句！"])

        // 3. Explicit fixed voice: script splitting is skipped so short turns still batch together.
        settings.ttsVoiceIdentifier = "voice-zh"
        let fixedEngine = MockTTSEngine()
        fixedEngine.preferredBatchCharacterLimit = 180
        let fixedCoordinator = StreamingSpeechCoordinator(engine: fixedEngine, settings: settings)
        fixedCoordinator.speakMessage(
            text: "这句话翻译成英文是：\nThe quick brown fox.\n谢谢！",
            messageID: UUID()
        )
        for _ in 0..<15 where fixedCoordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(fixedEngine.spokenSegments, ["这句话翻译成英文是：The quick brown fox.谢谢！"])
    }

    func testVoiceCallBatchLimitFitsLiveActivitySubtitleBudget() async {
        let settings = makeSettings(autoSpeak: false)
        settings.ttsEngineKind = .cloudOpenAI
        let cloudEngine = MockPrefetchableTTSEngine(preferredBatchCharacterLimit: 280)
        let coordinator = StreamingSpeechCoordinator(
            engine: MockTTSEngine(),
            cloudEngine: cloudEngine,
            settings: settings
        )
        coordinator.isVoiceCallActive = true

        let sentence1 = String(repeating: "测", count: 59) + "。"
        let sentence2 = String(repeating: "试", count: 59) + "。"
        let msgID = UUID()

        coordinator.resetForNewTurn(messageID: msgID)
        coordinator.feed(delta: sentence1 + sentence2, messageID: msgID)
        coordinator.finish(fullText: nil, messageID: msgID)

        for _ in 0..<20 where coordinator.isSpeaking {
            await Task.yield()
        }

        XCTAssertEqual(cloudEngine.synthesizedSegments.count, 2)
        XCTAssertTrue(cloudEngine.synthesizedSegments.allSatisfy { $0.count <= 100 })
        XCTAssertFalse(coordinator.isSpeaking)
    }

    func testCurrentSpokenSentenceUpdatesWhenPlaybackStartsNotDuringSynthesize() async {
        let settings = makeSettings(autoSpeak: false)
        settings.ttsEngineKind = .cloudOpenAI
        let cloudEngine = MockPrefetchableTTSEngine(preferredBatchCharacterLimit: 280)
        cloudEngine.hangSynthesizeOnCallIndex = 1
        cloudEngine.hangPlayOnCallIndex = 1
        let coordinator = StreamingSpeechCoordinator(
            engine: MockTTSEngine(),
            cloudEngine: cloudEngine,
            settings: settings
        )

        coordinator.speakMessage(text: "第一句内容。", messageID: UUID())
        for _ in 0..<10 where cloudEngine.synthesizedSegments.count < 1 {
            await Task.yield()
        }

        XCTAssertEqual(cloudEngine.synthesizedSegments, ["第一句内容。"])
        XCTAssertTrue(cloudEngine.playedSegments.isEmpty)
        XCTAssertEqual(coordinator.currentSpokenSentence, "")

        cloudEngine.resumePendingSynthesize(with: "第一句内容。")
        for _ in 0..<10 where cloudEngine.playedSegments.count < 1 {
            await Task.yield()
        }

        XCTAssertEqual(cloudEngine.playedSegments, ["第一句内容。"])
        XCTAssertEqual(coordinator.currentSpokenSentence, "第一句内容。")

        cloudEngine.resumePendingPlay()
        for _ in 0..<10 where coordinator.isSpeaking {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.currentSpokenSentence, "")
        XCTAssertFalse(coordinator.isSpeaking)
    }

    func testSettingsPersistLocalMLXTTSPreferencesAndReset() throws {
        let suite = "local-mlx-speech-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        let first = AppSettings(defaults: defaults, keychain: nil)
        XCTAssertEqual(first.localMLXVoiceID, LocalTTSModelCatalog.defaultVoiceID)
        XCTAssertNil(first.localMLXModelVariantID)

        first.ttsEngineKind = .localMLX
        first.localMLXModelVariantID = "cosyvoice3-0.5b-4bit"
        first.localMLXVoiceID = "warm_female"

        let reloaded = AppSettings(defaults: defaults, keychain: nil)
        XCTAssertEqual(reloaded.ttsEngineKind, .localMLX)
        XCTAssertEqual(reloaded.localMLXModelVariantID, "cosyvoice3-0.5b-4bit")
        XCTAssertEqual(reloaded.localMLXVoiceID, "warm_female")

        try reloaded.resetForDataErase()
        XCTAssertEqual(reloaded.ttsEngineKind, .appleSystem)
        XCTAssertNil(reloaded.localMLXModelVariantID)
        XCTAssertEqual(reloaded.localMLXVoiceID, LocalTTSModelCatalog.defaultVoiceID)
    }

    func testLocalMLXTTSRoutingAndFallbackToAppleOnUnreadyOrError() async {
        let settings = makeSettings(autoSpeak: true)
        settings.ttsEngineKind = .localMLX
        settings.localMLXVoiceID = "Serena"
        settings.ttsVoiceIdentifier = "voice-zh"

        let appleEngine = MockTTSEngine()
        let mlxEngine = MockTTSEngine()
        mlxEngine.isReady = false

        let coordinator = StreamingSpeechCoordinator(
            engine: appleEngine,
            localMLXEngine: mlxEngine,
            settings: settings
        )

        // 1. Not ready yet -> falls back to Apple engine.
        coordinator.speakMessage(text: "MLX unready fallback.", messageID: UUID())
        for _ in 0..<10 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(appleEngine.spokenSegments, ["MLX unready fallback."])
        XCTAssertEqual(mlxEngine.spokenSegments, [])

        // 2. Ready -> routes to Local MLX engine with localMLXVoiceID.
        mlxEngine.isReady = true
        coordinator.speakMessage(text: "Local MLX speaks.", messageID: UUID())
        for _ in 0..<10 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(mlxEngine.spokenSegments, ["Local MLX speaks."])
        XCTAssertEqual(mlxEngine.lastVoiceID, "Serena")

        // 3. Failure mid-turn -> seamlessly falls back to Apple System Voice.
        mlxEngine.consecutiveErrorsRemaining = 1
        coordinator.speakMessage(text: "MLX failed. Apple takes over.", messageID: UUID())
        for _ in 0..<20 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(appleEngine.spokenSegments, ["MLX unready fallback.", "MLX failed.", "Apple takes over."])
        XCTAssertFalse(coordinator.isSpeaking)
    }

    func testStreamingPrefetchCapsThresholdToEngineBatchLimit() async {
        let settings = makeSettings(autoSpeak: true)
        settings.ttsEngineKind = .localMLX

        let mlxEngine = MockPrefetchableTTSEngine(preferredBatchCharacterLimit: 40)
        mlxEngine.hangPlayOnCallIndex = 1
        let coordinator = StreamingSpeechCoordinator(
            engine: MockTTSEngine(),
            localMLXEngine: mlxEngine,
            settings: settings
        )

        let msgID = UUID()
        let firstSentence = "这是第一句测试内容。"
        let secondSentence = String(repeating: "测", count: 41) + "。"
        coordinator.resetForNewTurn(messageID: msgID)
        coordinator.feed(delta: firstSentence, messageID: msgID)
        for _ in 0..<10 where mlxEngine.playedSegments.count < 1 {
            await Task.yield()
        }
        XCTAssertEqual(mlxEngine.playedSegments, [firstSentence])

        // Without calling finish(), 42 chars is below streamingPrefetchMinCharacters (80)
        // yet meets the engine's 40-char batch limit, so prefetch must trigger immediately.
        coordinator.feed(delta: secondSentence, messageID: msgID)
        for _ in 0..<10 where mlxEngine.synthesizedSegments.count < 2 {
            await Task.yield()
        }
        XCTAssertEqual(mlxEngine.synthesizedSegments, [firstSentence, secondSentence])

        coordinator.finish(fullText: nil, messageID: msgID)
        mlxEngine.resumePendingPlay()
        for _ in 0..<15 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(mlxEngine.playedSegments, [firstSentence, secondSentence])
        XCTAssertFalse(coordinator.isSpeaking)
    }

    func testSpeakMessageWithoutFallbackDoesNotUseAppleOnUnreadyOrError() async {
        let settings = makeSettings(autoSpeak: true)
        settings.ttsEngineKind = .localMLX
        settings.localMLXVoiceID = "Serena"

        let appleEngine = MockTTSEngine()
        let mlxEngine = MockTTSEngine()
        mlxEngine.isReady = false

        let coordinator = StreamingSpeechCoordinator(
            engine: appleEngine,
            localMLXEngine: mlxEngine,
            settings: settings
        )

        // 1. Unready Local MLX with allowFallback: false -> must NOT use Apple, surfaces error.
        coordinator.speakMessage(text: "Preview test.", messageID: UUID(), allowFallback: false)
        for _ in 0..<5 {
            await Task.yield()
        }
        XCTAssertEqual(appleEngine.spokenSegments, [])
        XCTAssertEqual(mlxEngine.spokenSegments, [])
        XCTAssertFalse(coordinator.isSpeaking)
        XCTAssertNotNil(coordinator.lastPlaybackError)

        // 2. Failing Local MLX with allowFallback: false -> must NOT fall back to Apple, records error.
        mlxEngine.isReady = true
        mlxEngine.consecutiveErrorsRemaining = 1
        coordinator.speakMessage(text: "First fails. Second skipped.", messageID: UUID(), allowFallback: false)
        for _ in 0..<20 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(appleEngine.spokenSegments, [])
        XCTAssertEqual(mlxEngine.spokenSegments, [])
        XCTAssertFalse(coordinator.isSpeaking)
        XCTAssertNotNil(coordinator.lastPlaybackError)

        // 3. Subsequent successful playback clears lastPlaybackError.
        coordinator.speakMessage(text: "Works now.", messageID: UUID(), allowFallback: false)
        for _ in 0..<15 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(mlxEngine.spokenSegments, ["Works now."])
        XCTAssertNil(coordinator.lastPlaybackError)
    }

    func testLocalMLXUsesShortFirstBatchAndEarlyClauseSplitWhileCloudUnchanged() async {
        // 1. Streaming Local MLX flushes first clause early at >= 24 chars, then uses full 75-char batching.
        let settings = makeSettings(autoSpeak: true)
        settings.ttsEngineKind = .localMLX

        let mlxEngine = MockPrefetchableTTSEngine(preferredBatchCharacterLimit: 75)
        mlxEngine.hangPlayOnCallIndex = 1
        let coordinator = StreamingSpeechCoordinator(
            engine: MockTTSEngine(),
            localMLXEngine: mlxEngine,
            settings: settings
        )

        let msgID = UUID()
        let firstClause = "今天天气真的很不错，我们下午一起去公园散步呼吸空气吧，"
        let secondSentence = "随后再去附近的咖啡馆坐一坐聊聊天，晚上顺便看场电影。"
        coordinator.resetForNewTurn(messageID: msgID)
        coordinator.feed(delta: firstClause, messageID: msgID)
        for _ in 0..<10 where mlxEngine.playedSegments.count < 1 {
            await Task.yield()
        }
        XCTAssertEqual(mlxEngine.playedSegments, [firstClause])

        coordinator.feed(delta: secondSentence, messageID: msgID)
        coordinator.finish(fullText: nil, messageID: msgID)
        mlxEngine.resumePendingPlay()
        for _ in 0..<20 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(mlxEngine.playedSegments, [firstClause, secondSentence])

        // 2. On-demand Local MLX caps batch #1 at 24 chars, then coalesces batch #2 up to 75 chars.
        let mlxBatchEngine = MockPrefetchableTTSEngine(preferredBatchCharacterLimit: 75)
        let batchCoordinator = StreamingSpeechCoordinator(
            engine: MockTTSEngine(),
            localMLXEngine: mlxBatchEngine,
            settings: settings
        )
        let multiSentence = "这是第一句长度刚好十五个字哦。这是第二句长度刚好十五个字哦。这是第三句长度刚好十五个字哦。"
        batchCoordinator.speakMessage(text: multiSentence, messageID: UUID())
        for _ in 0..<20 where batchCoordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(
            mlxBatchEngine.playedSegments,
            ["这是第一句长度刚好十五个字哦。", "这是第二句长度刚好十五个字哦。这是第三句长度刚好十五个字哦。"]
        )

        // 3. Cloud TTS keeps full batching even on the very first utterance.
        settings.ttsEngineKind = .cloudOpenAI
        let cloudEngine = MockPrefetchableTTSEngine(preferredBatchCharacterLimit: 280)
        let cloudCoordinator = StreamingSpeechCoordinator(
            engine: MockTTSEngine(),
            cloudEngine: cloudEngine,
            settings: settings
        )
        cloudCoordinator.speakMessage(text: multiSentence, messageID: UUID())
        for _ in 0..<15 where cloudCoordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(cloudEngine.playedSegments, [multiSentence])
    }

    func testLocalMLXUsesSteppedBatchLimitsAndEagerSecondBatchPrefetch() async {
        let settings = makeSettings(autoSpeak: true)
        settings.ttsEngineKind = .localMLX

        // 1. Stepped batch limits: batch #1 <= 24, batch #2 <= 28, batch #3 <= 38, batch #4 <= 55, batch #5+ <= 75.
        let steppedEngine = MockPrefetchableTTSEngine(preferredBatchCharacterLimit: 75)
        let coordinator = StreamingSpeechCoordinator(
            engine: MockTTSEngine(),
            localMLXEngine: steppedEngine,
            settings: settings
        )
        let s1 = "这是第一句长度刚好十五个字哦。" // 15 chars -> batch #1 <= 24
        let s2 = "第二句长度十三个字。" // 10 chars
        let s3 = "第三句长度十三个字。" // 10 chars -> s2+s3 = 20 <= 28 (batch #2)
        let s4 = "这是第四句长度刚好十五个字哦。" // 15 chars -> 20+15 = 35 > 28, moves to batch #3
        let s5 = "这是第五句长度刚好十五个字哦。" // 15 chars -> 15+15 = 30 <= 38 (batch #3)
        let s6 = "这是第六句长度刚好十五个字哦。" // 15 chars -> 30+15 = 45 > 38, moves to batch #4
        let s7 = "这是第七句长度刚好十五个字哦。" // 15 chars
        let s8 = "这是第八句长度刚好十五个字哦。" // 15 chars -> s6+s7+s8 = 45 <= 55 (batch #4)
        let s9 = "这是第九句长度刚好十五个字哦。" // 15 chars -> 45+15 = 60 > 55, moves to batch #5
        coordinator.speakMessage(text: s1 + s2 + s3 + s4 + s5 + s6 + s7 + s8 + s9, messageID: UUID())
        for _ in 0..<30 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(steppedEngine.playedSegments, [s1, s2 + s3, s4 + s5, s6 + s7 + s8, s9])

        // 2. Streaming batch #2 prefetches eagerly while batch #1 plays, even below 40 chars.
        let prefetchEngine = MockPrefetchableTTSEngine(preferredBatchCharacterLimit: 75)
        prefetchEngine.hangPlayOnCallIndex = 1
        let streamCoordinator = StreamingSpeechCoordinator(
            engine: MockTTSEngine(),
            localMLXEngine: prefetchEngine,
            settings: settings
        )
        let msgID = UUID()
        let firstClause = "今天天气真的很不错，我们下午一起去公园散步呼吸空气吧，"
        let shortSecond = "你好。"
        streamCoordinator.resetForNewTurn(messageID: msgID)
        streamCoordinator.feed(delta: firstClause, messageID: msgID)
        for _ in 0..<10 where prefetchEngine.playedSegments.count < 1 {
            await Task.yield()
        }
        streamCoordinator.feed(delta: shortSecond, messageID: msgID)
        for _ in 0..<10 where prefetchEngine.synthesizedTexts.count < 2 {
            await Task.yield()
        }
        XCTAssertEqual(prefetchEngine.synthesizedTexts, [firstClause, shortSecond])
        streamCoordinator.finish(fullText: nil, messageID: msgID)
        prefetchEngine.resumePendingPlay()
        for _ in 0..<20 where streamCoordinator.isSpeaking {
            await Task.yield()
        }
    }

    func testLocalMLXSplitsLongCommaHeavySecondSentenceBelowBatchLimit() async {
        let settings = makeSettings(autoSpeak: true)
        settings.ttsEngineKind = .localMLX
        settings.localMLXFlowSteps = 8

        let reloaded = AppSettings(
            defaults: UserDefaults(suiteName: "speech-flow-steps-\(UUID().uuidString)")!,
            keychain: nil
        )
        XCTAssertEqual(reloaded.localMLXFlowSteps, 6)
        settings.resetToDefaults()
        XCTAssertEqual(settings.localMLXFlowSteps, 6)
        settings.ttsEngineKind = .localMLX

        let mlxEngine = MockPrefetchableTTSEngine(preferredBatchCharacterLimit: 75)
        let coordinator = StreamingSpeechCoordinator(
            engine: MockTTSEngine(),
            localMLXEngine: mlxEngine,
            settings: settings
        )
        let first = "今天天气很好。"
        // 61-char single sentence with internal commas (split <= 28 chars for batch #2).
        let longSecond = "我们上午先去街角那边附近的公园散步晒太阳呼吸新鲜空气，然后沿着湖边的小路慢慢散步聊聊天，最后去图书馆看一会儿自己喜欢的书。"
        coordinator.speakMessage(text: first + longSecond, messageID: UUID())
        for _ in 0..<20 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(mlxEngine.playedSegments.count, 3)
        XCTAssertLessThanOrEqual(mlxEngine.playedSegments[1].count, 28)
    }

    func testLocalMLXBatchLimitsParsingAndCustomLimits() async {
        XCTAssertEqual(AppSettings.parsedLocalMLXBatchLimits("24,28,38,55,75"), [24, 28, 38, 55, 75])
        XCTAssertEqual(AppSettings.parsedLocalMLXBatchLimits(" 35, 35，45 , 60, 80 "), [35, 35, 45, 60, 80])
        XCTAssertEqual(AppSettings.parsedLocalMLXBatchLimits("30,40"), [30, 40, 40, 40, 40])
        XCTAssertEqual(AppSettings.parsedLocalMLXBatchLimits("invalid"), [24, 28, 38, 55, 75])
        XCTAssertEqual(AppSettings.parsedLocalMLXBatchLimits("2,500,30,40,50"), [8, 120, 30, 40, 50])

        let settings = makeSettings(autoSpeak: true)
        settings.ttsEngineKind = .localMLX
        settings.localMLXBatchLimits = "35,35,45,60,75"

        let engine = MockPrefetchableTTSEngine(preferredBatchCharacterLimit: 75)
        let coordinator = StreamingSpeechCoordinator(
            engine: MockTTSEngine(),
            localMLXEngine: engine,
            settings: settings
        )
        let s1 = "这是第一句十五字。" // 9 chars
        let s2 = "这是第二句十五个字哦。" // 11 chars -> 9+11 = 20 <= 35 (merged into batch #1)
        let s3 = "这是第三句十五个字哦。" // 11 chars -> 20+11 = 31 <= 35 (merged into batch #1)
        let s4 = "这是第四句十五个字哦。" // 11 chars -> 31+11 = 42 > 35 (moves to batch #2)
        coordinator.speakMessage(text: s1 + s2 + s3 + s4, messageID: UUID())
        for _ in 0..<20 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(engine.playedSegments, [s1 + s2 + s3, s4])
    }
}
