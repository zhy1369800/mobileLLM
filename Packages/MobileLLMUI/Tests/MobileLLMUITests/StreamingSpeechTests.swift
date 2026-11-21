// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

@MainActor
private final class MockTTSEngine: TTSEngine {
    let id = "mock-tts"
    let displayName = "Mock TTS"
    private(set) var isSpeaking = false
    var isReady = true
    var onExternalInterruption: (@MainActor () -> Void)?
    private(set) var spokenSegments: [String] = []
    private(set) var lastVoiceID: String?
    private(set) var stopCount = 0
    private(set) var endSessionCount = 0
    private(set) var unloadCount = 0

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

    func unload() {
        unloadCount += 1
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
        first.ttsEngineKind = .kokoroOffline
        first.kokoroVoiceID = "zf_001"

        let reloaded = AppSettings(defaults: defaults, keychain: nil)
        XCTAssertTrue(reloaded.autoSpeakResponses)
        XCTAssertEqual(reloaded.ttsSpeechRate, 1.4, accuracy: 0.001)
        XCTAssertEqual(reloaded.ttsVoiceIdentifier, "com.apple.voice.enhanced.zh-CN.Tingting")
        XCTAssertEqual(reloaded.ttsEngineKind, .kokoroOffline)
        XCTAssertEqual(reloaded.kokoroVoiceID, "zf_001")
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

    func testKokoroEngineSelectionAndFallbackWhenNotReady() async {
        let settings = makeSettings(autoSpeak: true)
        settings.ttsEngineKind = .kokoroOffline
        settings.kokoroVoiceID = "zf_002"

        let appleEngine = MockTTSEngine()
        let kokoroEngine = MockTTSEngine()
        kokoroEngine.isReady = false

        let coordinator = StreamingSpeechCoordinator(
            engine: appleEngine,
            kokoroEngine: kokoroEngine,
            settings: settings
        )

        // Not ready yet -> falls back to Apple engine.
        coordinator.speakMessage(text: "Fallback test.", messageID: UUID())
        for _ in 0..<10 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(appleEngine.spokenSegments, ["Fallback test."])
        XCTAssertEqual(kokoroEngine.spokenSegments, [])

        // Once Kokoro becomes ready -> routes to Kokoro with kokoroVoiceID.
        kokoroEngine.isReady = true
        coordinator.speakMessage(text: "Neural voice ready.", messageID: UUID())
        for _ in 0..<10 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(kokoroEngine.spokenSegments, ["Neural voice ready."])
        XCTAssertEqual(kokoroEngine.lastVoiceID, "zf_002")
    }

    func testNeuralEngineTriggersMemoryTrimAndUnload() async {
        let settings = makeSettings(autoSpeak: true)
        settings.ttsEngineKind = .kokoroOffline

        let appleEngine = MockTTSEngine()
        let kokoroEngine = MockTTSEngine()
        kokoroEngine.isReady = true

        let coordinator = StreamingSpeechCoordinator(
            engine: appleEngine,
            kokoroEngine: kokoroEngine,
            settings: settings
        )

        var memoryTrimCalls = 0
        coordinator.onPrepareMemoryForNeuralTTS = {
            memoryTrimCalls += 1
            return true
        }

        coordinator.speakMessage(text: "Memory check.", messageID: UUID())
        for _ in 0..<10 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(memoryTrimCalls, 1)
        XCTAssertEqual(kokoroEngine.spokenSegments, ["Memory check."])

        // Under critical RAM pressure (< 450 MB), returning false falls back to Apple engine.
        coordinator.onPrepareMemoryForNeuralTTS = { false }
        coordinator.speakMessage(text: "Low RAM fallback.", messageID: UUID())
        for _ in 0..<10 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(appleEngine.spokenSegments, ["Low RAM fallback."])

        coordinator.unloadNeuralEngine()
        XCTAssertEqual(kokoroEngine.unloadCount, 1)
    }
}
