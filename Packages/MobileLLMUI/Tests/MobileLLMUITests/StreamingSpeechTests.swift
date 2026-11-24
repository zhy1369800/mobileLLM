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
}
