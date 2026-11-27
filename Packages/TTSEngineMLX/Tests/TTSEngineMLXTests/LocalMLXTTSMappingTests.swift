// SPDX-License-Identifier: MIT

import XCTest
import MobileLLMUI
@testable import TTSCosyVoice
@testable import TTSEngineMLX

@MainActor
final class LocalMLXTTSMappingTests: XCTestCase {
    func testDetectLanguageCoversCJKAndEnglishFallback() {
        XCTAssertEqual(LocalMLXTTSMapping.detectLanguage(for: "你好，欢迎使用本地语音。", voiceID: "default_en"), "chinese")
        XCTAssertEqual(LocalMLXTTSMapping.detectLanguage(for: "Hello world, testing 123.", voiceID: "default_en"), "english")
        XCTAssertEqual(LocalMLXTTSMapping.detectLanguage(for: "OK 123", voiceID: "default_zh"), "chinese")
        XCTAssertEqual(LocalMLXTTSMapping.detectLanguage(for: "こんにちは世界", voiceID: nil), "japanese")
        XCTAssertEqual(LocalMLXTTSMapping.detectLanguage(for: "안녕하세요", voiceID: nil), "korean")
        XCTAssertEqual(LocalMLXTTSMapping.detectLanguage(for: "这个 MLX 模型很快", voiceID: nil), "chinese")
    }

    func testCosyVoiceInstructionMapping() {
        XCTAssertEqual(LocalMLXTTSMapping.cosyVoiceInstruction(for: "default_zh"), "You are a helpful assistant.")
        XCTAssertEqual(LocalMLXTTSMapping.cosyVoiceInstruction(for: "warm_female"), "Speak in a warm, gentle female voice.")
        XCTAssertEqual(LocalMLXTTSMapping.cosyVoiceInstruction(for: "clear_male"), "Speak in a clear, calm male voice.")
        XCTAssertEqual(LocalMLXTTSMapping.cosyVoiceInstruction(for: nil), "You are a helpful assistant.")
    }

    func testQwen3SpeakerNormalization() {
        XCTAssertEqual(LocalMLXTTSMapping.qwen3Speaker(for: "Vivian"), "vivian")
        XCTAssertEqual(LocalMLXTTSMapping.qwen3Speaker(for: "  Uncle_Fu "), "uncle_fu")
        XCTAssertEqual(LocalMLXTTSMapping.qwen3Speaker(for: nil), "vivian")
        XCTAssertEqual(LocalMLXTTSMapping.qwen3Speaker(for: "   "), "vivian")
        XCTAssertEqual(LocalMLXTTSMapping.qwen3Speaker(for: "clone:abc"), "vivian")
    }

    func testMLXTTSEngineReadinessMatchesResolverAndSimulatorGuard() {
        let unready = MLXTTSEngine { nil }
        XCTAssertFalse(unready.isReady)

        let stubModel = LocalTTSModelCatalog.defaultModel
        let stubVariant = LocalTTSModelCatalog.defaultVariant
        let ready = MLXTTSEngine {
            (stubModel, stubVariant, FileManager.default.temporaryDirectory)
        }
        #if targetEnvironment(simulator)
        XCTAssertFalse(ready.isReady)
        #else
        XCTAssertTrue(ready.isReady)
        #endif
    }

    func testSplitIntoSafeChunksRespectsMaxLengthForChineseAndEnglish() {
        XCTAssertEqual(LocalMLXTTSMapping.splitIntoSafeChunks("  你好世界。 "), ["你好世界。"])
        XCTAssertTrue(LocalMLXTTSMapping.splitIntoSafeChunks("   ").isEmpty)

        let longChinese = "这是第一句比较长的话，包含逗号和细节描述用来测试自动分片功能，确保长句子能够按照自然的标点切分，这是第二句话也很长用来确认模型不会因为一次性合成过长文本而触发内存峰值，最后结束。"
        let zhChunks = LocalMLXTTSMapping.splitIntoSafeChunks(longChinese)
        XCTAssertGreaterThan(zhChunks.count, 1)
        XCTAssertTrue(zhChunks.allSatisfy { !$0.isEmpty && $0.count <= 85 })
        XCTAssertEqual(zhChunks.joined(), longChinese)

        let unpunctuated = String(repeating: "あ", count: 200)
        let hardChunks = LocalMLXTTSMapping.splitIntoSafeChunks(unpunctuated)
        XCTAssertEqual(hardChunks.count, 3)
        XCTAssertTrue(hardChunks.allSatisfy { !$0.isEmpty && $0.count <= 85 })
        XCTAssertEqual(hardChunks.joined(), unpunctuated)
    }

    func testStitchAudioChunksAddsGapAndEdgeFadeOnlyForMultipleChunks() {
        XCTAssertEqual(LocalMLXTTSMapping.stitchAudioChunks([], sampleRate: 24_000), [])

        let single: [Float] = [0.5, 0.5, 0.5, 0.5]
        XCTAssertEqual(LocalMLXTTSMapping.stitchAudioChunks([[], single], sampleRate: 24_000), single)

        let chunk = [Float](repeating: 1.0, count: 1_000)
        let stitched = LocalMLXTTSMapping.stitchAudioChunks(
            [chunk, chunk],
            sampleRate: 1_000,
            gapSeconds: 0.08,
            edgeFadeSeconds: 0.015
        )
        XCTAssertEqual(stitched.count, 1_000 + 80 + 1_000)
        // Fade-in starts near zero, interior stays unattenuated, gap is pure silence, fade-out tapers near zero.
        XCTAssertLessThan(stitched[0], 0.2)
        XCTAssertEqual(stitched[500], 1.0, accuracy: 0.0001)
        XCTAssertLessThan(stitched[999], 0.2)
        XCTAssertTrue(stitched[1_000..<1_080].allSatisfy { $0 == 0 })
        XCTAssertLessThan(stitched[1_080], 0.2)
        XCTAssertEqual(stitched[1_580], 1.0, accuracy: 0.0001)
        XCTAssertLessThan(stitched[2_079], 0.2)
    }

    func testCosyVoiceSplitForLongFormHandlesChinesePunctuationAndHardCap() {
        let chineseInput = "今天天气非常不错，我们在公园里散步聊了很多关于本地语音合成的技术细节；随后又测试了多种不同长度和标点的句子。为了保证在移动设备上有更低的内存峰值与稳定表现，长句子需要按照自然的标点边界自动切分成多个可控的短片段！"
        let segments = CosyVoiceTTSModel.splitForLongForm(chineseInput)
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { !$0.isEmpty && $0.count <= 85 })
        XCTAssertEqual(
            segments.joined().filter { !$0.isWhitespace },
            chineseInput.filter { !$0.isWhitespace }
        )

        let unpunctuated = String(repeating: "测", count: 200)
        let hardSegments = CosyVoiceTTSModel.splitForLongForm(unpunctuated)
        XCTAssertEqual(hardSegments.count, 3)
        XCTAssertTrue(hardSegments.allSatisfy { !$0.isEmpty && $0.count <= 85 })
        XCTAssertEqual(hardSegments.joined(), unpunctuated)
    }
}
