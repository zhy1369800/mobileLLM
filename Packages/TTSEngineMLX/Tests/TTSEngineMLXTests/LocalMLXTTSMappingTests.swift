// SPDX-License-Identifier: MIT

import XCTest
import MobileLLMUI
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
}
