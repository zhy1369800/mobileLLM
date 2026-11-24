// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

@MainActor
private final class PrewarmSpyTTSEngine: TTSEngine {
    let id: String
    let displayName: String
    private(set) var isSpeaking = false
    var isReady = true
    var preservesExternalAudioSession = false
    var onExternalInterruption: (@MainActor @Sendable () -> Void)?

    private(set) var prewarmCount = 0
    private(set) var spokenSegments: [String] = []
    private(set) var endSessionCount = 0

    init(id: String = "spy-tts", displayName: String = "Spy TTS") {
        self.id = id
        self.displayName = displayName
    }

    func availableVoices() -> [TTSVoiceInfo] { [] }

    func prewarm() {
        prewarmCount += 1
    }

    func speak(text: String, voiceID: String?, rate: Double) async throws {
        spokenSegments.append(text)
    }

    func stop() {
        isSpeaking = false
    }

    func endPlaybackSession() {
        endSessionCount += 1
    }
}

@MainActor
final class VoiceBargeInTests: XCTestCase {

    private func feedFrames(
        _ detector: inout VoiceBargeInDetector,
        count: Int,
        duration: Double = 0.02,
        micLevel: Float,
        farEndLevel: Float
    ) -> [VoiceBargeInAction] {
        var actions: [VoiceBargeInAction] = []
        actions.reserveCapacity(count)
        for _ in 0..<count {
            actions.append(detector.process(micLevel: micLevel, farEndLevel: farEndLevel, duration: duration))
        }
        return actions
    }

    func testFirstTurnLeadingSilenceDoesNotConsumeAECConvergence() {
        var detector = VoiceBargeInDetector(config: .speakerWithHardwareAEC)
        detector.setSpeaking(true)

        // 500ms of TTS buffering / leading silence (`farEndLevel` below `farEndActiveFloor`).
        let actions = feedFrames(&detector, count: 25, micLevel: 0.85, farEndLevel: 0.01)

        XCTAssertTrue(actions.allSatisfy { $0 == .none })
        XCTAssertEqual(detector.aecConvergedPlaybackDuration, 0, accuracy: 1e-6)
        XCTAssertFalse(detector.isAECConverged)
        XCTAssertFalse(detector.hasHeardPlaybackInTurn)
    }

    func testFirstTurnShortOpenerAndSilenceGapPreservesColdStartProtection() {
        var detector = VoiceBargeInDetector(config: .speakerWithHardwareAEC)
        detector.setSpeaking(true)

        // Short opener: 0.30s of active playback with strong echo.
        let openerActions = feedFrames(&detector, count: 15, micLevel: 0.80, farEndLevel: 0.70)
        XCTAssertTrue(openerActions.allSatisfy { $0 == .none })
        XCTAssertEqual(detector.aecConvergedPlaybackDuration, 0.30, accuracy: 1e-6)
        XCTAssertFalse(detector.isAECConverged)

        // 1.20s inter-sentence silence gap must freeze convergence progress instead of burning it.
        let gapActions = feedFrames(&detector, count: 60, micLevel: 0.15, farEndLevel: 0.0)
        XCTAssertTrue(gapActions.allSatisfy { $0 == .none })
        XCTAssertEqual(detector.aecConvergedPlaybackDuration, 0.30, accuracy: 1e-6)
        XCTAssertFalse(detector.isAECConverged)

        // Sentence 2 plays for 0.80s (total active playback 1.10s < 1.15s) with loud echo.
        let sentence2Actions = feedFrames(&detector, count: 40, micLevel: 0.85, farEndLevel: 0.70)
        XCTAssertTrue(sentence2Actions.allSatisfy { $0 == .none })
        XCTAssertEqual(detector.aecConvergedPlaybackDuration, 1.10, accuracy: 1e-6)
        XCTAssertFalse(detector.isAECConverged)

        // Remaining 0.10s of playback brings total active speech past 1.15s convergence threshold.
        _ = feedFrames(&detector, count: 5, micLevel: 0.20, farEndLevel: 0.70)
        XCTAssertTrue(detector.isAECConverged)
    }

    func testConvergedResidualEchoBelowFarEndThresholdAndIntermittentSpikesDoNotTrigger() {
        var detector = VoiceBargeInDetector(config: .speakerWithHardwareAEC)
        detector.setSpeaking(true)

        // Warm up AEC past 1.15s + steady grace (1.30s).
        _ = feedFrames(&detector, count: 65, micLevel: 0.25, farEndLevel: 0.65)
        XCTAssertTrue(detector.isAECConverged)

        // Sustained residual echo below dynamic far-end threshold (~0.541) must stay quiet.
        let steadyEcho = feedFrames(&detector, count: 50, micLevel: 0.48, farEndLevel: 0.65)
        XCTAssertTrue(steadyEcho.allSatisfy { $0 == .none })
        XCTAssertEqual(detector.stage1Accumulated, 0, accuracy: 1e-6)

        // Intermittent 0.62 peaks (40ms on / 40ms off) decay 1.1x faster than they accumulate.
        for _ in 0..<20 {
            let on = feedFrames(&detector, count: 2, micLevel: 0.62, farEndLevel: 0.65)
            let off = feedFrames(&detector, count: 2, micLevel: 0.20, farEndLevel: 0.65)
            XCTAssertTrue(on.allSatisfy { $0 == .none })
            XCTAssertTrue(off.allSatisfy { $0 == .none })
        }
        XCTAssertFalse(detector.isVerifying)
        XCTAssertEqual(detector.stage1Accumulated, 0, accuracy: 1e-6)
    }

    func testTwoStageDuckAndConfirmRejectsLoudEchoAndAdaptsOffset() {
        var detector = VoiceBargeInDetector(config: .speakerWithHardwareAEC)
        detector.setSpeaking(true)

        // Warm up AEC (1.30s active playback at farEnd = 0.60 -> Stage 1 threshold = 0.534).
        _ = feedFrames(&detector, count: 65, micLevel: 0.20, farEndLevel: 0.60)

        // Sustained loud echo (0.57) crosses Stage 1 (0.534) over 0.12s (6 * 0.02s) -> duck playback.
        let stage1 = feedFrames(&detector, count: 6, micLevel: 0.57, farEndLevel: 0.60)
        XCTAssertEqual(stage1.dropLast().allSatisfy { $0 == .none }, true)
        XCTAssertEqual(stage1.last, .duckPlayback)
        XCTAssertTrue(detector.isVerifying)

        // Settle period (0.06s < 0.07s) while acoustic echo tails off.
        let settle = feedFrames(&detector, count: 3, micLevel: 0.40, farEndLevel: 0.05)
        XCTAssertTrue(settle.allSatisfy { $0 == .none })

        // Once playback is ducked, echo drops to 0.18 for 0.14s (7 frames >= 0.13s) -> reject & restore playback.
        let verify = feedFrames(&detector, count: 7, micLevel: 0.18, farEndLevel: 0.05)
        XCTAssertEqual(verify.dropLast().allSatisfy { $0 == .none }, true)
        XCTAssertEqual(verify.last, .restorePlayback)
        XCTAssertFalse(detector.isVerifying)
        XCTAssertTrue(detector.isSpeaking)
        XCTAssertEqual(detector.cooldownRemaining, 0.55, accuracy: 1e-6)
        XCTAssertEqual(detector.adaptiveEchoOffset, 0.05, accuracy: 1e-6)

        // Cooldown period (0.55s) suppresses immediate re-triggering.
        let cooldown = feedFrames(&detector, count: 28, micLevel: 0.57, farEndLevel: 0.60)
        XCTAssertTrue(cooldown.allSatisfy { $0 == .none })
        XCTAssertEqual(detector.cooldownRemaining, 0, accuracy: 1e-6)

        // Post-cooldown: persistent 0.57 echo stays locked out without decaying into periodic re-ducking.
        let postCooldown = feedFrames(&detector, count: 150, micLevel: 0.57, farEndLevel: 0.60)
        XCTAssertTrue(postCooldown.allSatisfy { $0 == .none })
        XCTAssertFalse(detector.isVerifying)
        XCTAssertEqual(detector.adaptiveEchoOffset, 0.05, accuracy: 1e-6)

        // Clean active playback well below threshold gradually decays adaptiveEchoOffset back to zero.
        let cleanPlayback = feedFrames(&detector, count: 330, micLevel: 0.18, farEndLevel: 0.60)
        XCTAssertTrue(cleanPlayback.allSatisfy { $0 == .none })
        XCTAssertEqual(detector.adaptiveEchoOffset, 0, accuracy: 1e-6)
    }

    func testSingleLoudCoughDoesNotJumpAdaptiveOffsetToMax() {
        var detector = VoiceBargeInDetector(config: .speakerWithHardwareAEC)
        detector.setSpeaking(true)

        _ = feedFrames(&detector, count: 65, micLevel: 0.20, farEndLevel: 0.60)

        // Brief loud cough (0.80 for 0.12s) triggers Stage 1, then stops before Stage 2 confirms.
        let stage1 = feedFrames(&detector, count: 6, micLevel: 0.80, farEndLevel: 0.60)
        XCTAssertEqual(stage1.last, .duckPlayback)

        _ = feedFrames(&detector, count: 3, micLevel: 0.30, farEndLevel: 0.05)
        let verify = feedFrames(&detector, count: 7, micLevel: 0.15, farEndLevel: 0.05)
        XCTAssertEqual(verify.last, .restorePlayback)

        // Offset steps up by a single bounded increment (0.05) rather than jumping near max (0.18).
        XCTAssertEqual(detector.adaptiveEchoOffset, 0.05, accuracy: 1e-6)
        XCTAssertLessThan(detector.adaptiveEchoOffset, detector.config.maxAdaptiveEchoOffset)

        // Wait out cooldown, then confirm subsequent normal user speech (0.62) still interrupts cleanly.
        _ = feedFrames(&detector, count: 28, micLevel: 0.20, farEndLevel: 0.60)
        let bargeIn1 = feedFrames(&detector, count: 6, micLevel: 0.62, farEndLevel: 0.60)
        XCTAssertEqual(bargeIn1.last, .duckPlayback)

        let bargeIn2 = feedFrames(&detector, count: 8, micLevel: 0.52, farEndLevel: 0.05)
        XCTAssertEqual(bargeIn2.last, .confirmInterrupt)
    }

    func testTwoStageDuckAndConfirmInterruptsRealUserSpeech() {
        var detector = VoiceBargeInDetector(config: .speakerWithHardwareAEC)
        detector.setSpeaking(true)

        _ = feedFrames(&detector, count: 65, micLevel: 0.20, farEndLevel: 0.60)

        // Normal user speech (0.60) over playback -> Stage 1 ducks audio after 0.12s.
        let stage1 = feedFrames(&detector, count: 6, micLevel: 0.60, farEndLevel: 0.60)
        XCTAssertEqual(stage1.last, .duckPlayback)

        // User keeps speaking at normal volume (0.48) while speaker playback is ducked (0.05).
        let stage2 = feedFrames(&detector, count: 8, micLevel: 0.48, farEndLevel: 0.05)
        XCTAssertEqual(stage2.dropLast().allSatisfy { $0 == .none }, true)
        XCTAssertEqual(stage2.last, .confirmInterrupt)
        XCTAssertFalse(detector.isSpeaking)
        XCTAssertFalse(detector.isVerifying)
    }

    func testHeadphonesPresetTriggersQuicklyWithoutColdStartAndIgnoresBriefClicks() {
        var detector = VoiceBargeInDetector(config: .headphones)
        detector.setSpeaking(true)

        // Pass steady playback grace (0.16s >= 0.15s); no 1.6s AEC convergence wait required.
        _ = feedFrames(&detector, count: 8, micLevel: 0.10, farEndLevel: 0.60)

        // Brief 60ms click does not trigger Stage 1 and decays back to zero.
        let click = feedFrames(&detector, count: 3, micLevel: 0.60, farEndLevel: 0.60)
        let decay = feedFrames(&detector, count: 4, micLevel: 0.10, farEndLevel: 0.60)
        XCTAssertTrue(click.allSatisfy { $0 == .none })
        XCTAssertTrue(decay.allSatisfy { $0 == .none })
        XCTAssertEqual(detector.stage1Accumulated, 0, accuracy: 1e-6)

        // Sustained user voice (0.45) triggers duck at 0.10s and confirms within another 0.10s.
        let stage1 = feedFrames(&detector, count: 5, micLevel: 0.45, farEndLevel: 0.60)
        XCTAssertEqual(stage1.last, .duckPlayback)

        let stage2 = feedFrames(&detector, count: 5, micLevel: 0.45, farEndLevel: 0.05)
        XCTAssertEqual(stage2.last, .confirmInterrupt)
    }

    func testDisabledPresetNeverTriggersBargeIn() {
        var detector = VoiceBargeInDetector(config: .disabled)
        detector.setSpeaking(true)

        let actions = feedFrames(&detector, count: 200, micLevel: 1.0, farEndLevel: 0.70)
        XCTAssertTrue(actions.allSatisfy { $0 == .none })
        XCTAssertFalse(detector.isVerifying)
    }

    func testAmbientNoiseFloorCalibrationRaisesThresholdsSafely() {
        var detector = VoiceBargeInDetector(config: .speakerWithHardwareAEC)
        let initialStage1 = detector.currentStage1Threshold
        let initialStage2 = detector.currentStage2Threshold

        for _ in 0..<400 {
            detector.updateAmbientNoise(level: 0.40)
        }

        XCTAssertGreaterThan(detector.ambientNoiseFloor, 0.35)
        XCTAssertGreaterThan(detector.currentStage1Threshold, initialStage1)
        XCTAssertGreaterThan(detector.currentStage2Threshold, initialStage2)

        detector.setSpeaking(true)
        _ = feedFrames(&detector, count: 85, micLevel: 0.20, farEndLevel: 0.65)
        XCTAssertTrue(detector.isAECConverged)

        detector.resetCalibration()
        XCTAssertFalse(detector.isAECConverged)
        XCTAssertEqual(detector.aecConvergedPlaybackDuration, 0, accuracy: 1e-6)
    }

    func testPrewarmForVoiceCallDoesNotAffectChatPlayback() async {
        let suite = "voice-bargein-prewarm-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults, keychain: nil)
        settings.autoSpeakResponses = false

        let appleEngine = PrewarmSpyTTSEngine(id: "apple", displayName: "Apple")
        let cloudEngine = PrewarmSpyTTSEngine(id: "cloud", displayName: "Cloud")
        let coordinator = StreamingSpeechCoordinator(
            engine: appleEngine,
            cloudEngine: cloudEngine,
            settings: settings
        )

        coordinator.prewarmForVoiceCall()

        XCTAssertEqual(appleEngine.prewarmCount, 1)
        XCTAssertEqual(cloudEngine.prewarmCount, 1)
        XCTAssertFalse(coordinator.isSpeaking)
        XCTAssertEqual(coordinator.currentSpokenSentence, "")
        XCTAssertFalse(settings.autoSpeakResponses)

        // Normal chat on-demand playback continues working identically.
        coordinator.speakMessage(text: "Chat reply.", messageID: UUID())
        for _ in 0..<10 where coordinator.isSpeaking {
            await Task.yield()
        }
        XCTAssertEqual(appleEngine.spokenSegments, ["Chat reply."])
        XCTAssertGreaterThan(appleEngine.endSessionCount, 0)
    }

    func testKeywordModeEmitsBeginKeywordVerificationInsteadOfImmediateInterrupt() {
        var detector = VoiceBargeInDetector(
            config: VoiceBargeInConfig.speakerWithHardwareAEC.withKeywordVerification(true)
        )
        detector.setSpeaking(true)

        _ = feedFrames(&detector, count: 65, micLevel: 0.20, farEndLevel: 0.65)

        let stage1 = feedFrames(&detector, count: 6, micLevel: 0.62, farEndLevel: 0.65)
        XCTAssertEqual(stage1.last, .duckPlayback)
        XCTAssertTrue(detector.isVerifying)

        let stage2 = feedFrames(&detector, count: 8, micLevel: 0.50, farEndLevel: 0.05)
        XCTAssertEqual(stage2.dropLast().allSatisfy { $0 == .none }, true)
        XCTAssertEqual(stage2.last, .beginKeywordVerification)
        XCTAssertTrue(detector.isSpeaking)
        XCTAssertFalse(detector.isVerifying)
        XCTAssertTrue(detector.isKeywordVerifying)

        let followUp = feedFrames(&detector, count: 10, micLevel: 0.80, farEndLevel: 0.05)
        XCTAssertTrue(followUp.allSatisfy { $0 == .none })
    }

    func testKeywordVerificationRejectedCoolsDownWithoutEchoOffsetPenalty() {
        var detector = VoiceBargeInDetector(
            config: VoiceBargeInConfig.speakerWithHardwareAEC.withKeywordVerification(true)
        )
        detector.setSpeaking(true)

        _ = feedFrames(&detector, count: 65, micLevel: 0.20, farEndLevel: 0.65)
        _ = feedFrames(&detector, count: 6, micLevel: 0.62, farEndLevel: 0.65)
        let stage2 = feedFrames(&detector, count: 8, micLevel: 0.50, farEndLevel: 0.05)
        XCTAssertEqual(stage2.last, .beginKeywordVerification)

        XCTAssertTrue(detector.completeKeywordVerification(matched: false))
        XCTAssertFalse(detector.isKeywordVerifying)
        XCTAssertTrue(detector.isSpeaking)
        XCTAssertEqual(detector.adaptiveEchoOffset, 0, accuracy: 1e-6)
        XCTAssertEqual(detector.cooldownRemaining, detector.config.keywordRejectCooldownDuration, accuracy: 1e-6)

        // During cooldown (1.0s), loud speech does not re-trigger ducking (51 * 0.02s avoids FP residual).
        let cooldown = feedFrames(&detector, count: 51, micLevel: 0.65, farEndLevel: 0.65)
        XCTAssertTrue(cooldown.allSatisfy { $0 == .none })
        XCTAssertEqual(detector.cooldownRemaining, 0, accuracy: 1e-6)

        // Post-cooldown: user saying a keyword can trigger Stage 1 again cleanly.
        let retrigger = feedFrames(&detector, count: 6, micLevel: 0.65, farEndLevel: 0.65)
        XCTAssertEqual(retrigger.last, .duckPlayback)
    }

    func testKeywordVerificationMatchedStopsSpeaking() {
        var detector = VoiceBargeInDetector(
            config: VoiceBargeInConfig.speakerWithHardwareAEC.withKeywordVerification(true)
        )
        detector.setSpeaking(true)

        _ = feedFrames(&detector, count: 65, micLevel: 0.20, farEndLevel: 0.65)
        _ = feedFrames(&detector, count: 6, micLevel: 0.62, farEndLevel: 0.65)
        _ = feedFrames(&detector, count: 8, micLevel: 0.50, farEndLevel: 0.05)
        XCTAssertTrue(detector.isKeywordVerifying)

        XCTAssertTrue(detector.completeKeywordVerification(matched: true))
        XCTAssertFalse(detector.isKeywordVerifying)
        XCTAssertFalse(detector.isSpeaking)
        XCTAssertFalse(detector.completeKeywordVerification(matched: false))
    }

    func testKeywordParserHandlesCommaSeparationTrimmingDedupAndBlank() {
        XCTAssertEqual(VoiceBargeInKeywordMatcher.parseKeywords(""), [])
        XCTAssertEqual(VoiceBargeInKeywordMatcher.parseKeywords("   , ,  "), [])
        XCTAssertEqual(
            VoiceBargeInKeywordMatcher.parseKeywords("停一下, 等等, stop "),
            ["停一下", "等等", "stop"]
        )
        XCTAssertEqual(
            VoiceBargeInKeywordMatcher.parseKeywords("停一下,停一下,STOP,stop"),
            ["停一下", "STOP"]
        )
        XCTAssertEqual(
            VoiceBargeInKeywordMatcher.parseKeywords("停一下，等等"),
            ["停一下", "等等"]
        )
    }

    func testKeywordMatcherHandlesChineseEnglishWordBoundariesAndPunctuation() {
        XCTAssertFalse(VoiceBargeInKeywordMatcher.matches(transcript: "停一下", keywords: []))
        XCTAssertTrue(VoiceBargeInKeywordMatcher.matches(transcript: "嗯，停，一下！", keywords: ["停一下"]))
        XCTAssertTrue(VoiceBargeInKeywordMatcher.matches(transcript: "Please STOP!", keywords: ["stop"]))
        XCTAssertFalse(VoiceBargeInKeywordMatcher.matches(transcript: "nonstop", keywords: ["stop"]))
        XCTAssertFalse(VoiceBargeInKeywordMatcher.matches(transcript: "I know that", keywords: ["no"]))
        XCTAssertTrue(VoiceBargeInKeywordMatcher.matches(transcript: "hey, hold on a second", keywords: ["hold on"]))
        XCTAssertTrue(VoiceBargeInKeywordMatcher.matches(transcript: "停一下stop", keywords: ["stop"]))
        XCTAssertTrue(VoiceBargeInKeywordMatcher.matches(transcript: "嘿 小 a", keywords: ["小A"]))
    }

    func testResolveBargeInConfigRespectsModeAndEmptyKeywords() {
        let freeHeadphones = VoiceChatSession.resolveBargeInConfig(
            mode: .free,
            keywords: [],
            isUsingHeadphones: true,
            isHardwareAECEnabled: false
        )
        XCTAssertTrue(freeHeadphones.enabled)
        XCTAssertFalse(freeHeadphones.requiresKeywordVerification)

        let freeSpeaker = VoiceChatSession.resolveBargeInConfig(
            mode: .free,
            keywords: [],
            isUsingHeadphones: false,
            isHardwareAECEnabled: true
        )
        XCTAssertTrue(freeSpeaker.enabled)
        XCTAssertFalse(freeSpeaker.requiresKeywordVerification)

        let freeNoAEC = VoiceChatSession.resolveBargeInConfig(
            mode: .free,
            keywords: [],
            isUsingHeadphones: false,
            isHardwareAECEnabled: false
        )
        XCTAssertFalse(freeNoAEC.enabled)

        let keywordWithList = VoiceChatSession.resolveBargeInConfig(
            mode: .keyword,
            keywords: ["停一下"],
            isUsingHeadphones: false,
            isHardwareAECEnabled: true
        )
        XCTAssertTrue(keywordWithList.enabled)
        XCTAssertTrue(keywordWithList.requiresKeywordVerification)

        let keywordEmptyHeadphones = VoiceChatSession.resolveBargeInConfig(
            mode: .keyword,
            keywords: [],
            isUsingHeadphones: true,
            isHardwareAECEnabled: true
        )
        XCTAssertFalse(keywordEmptyHeadphones.enabled)

        let keywordEmptySpeaker = VoiceChatSession.resolveBargeInConfig(
            mode: .keyword,
            keywords: [],
            isUsingHeadphones: false,
            isHardwareAECEnabled: true
        )
        XCTAssertFalse(keywordEmptySpeaker.enabled)
    }
}
