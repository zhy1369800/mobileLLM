// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMEngineLlama

final class MtpDetectorTests: XCTestCase {

    func testDeclaresDraftLayersPositive() {
        XCTAssertTrue(MtpDetector.declaresDraftLayers(key: "qwen2.nextn", value: "1"))
        XCTAssertTrue(MtpDetector.declaresDraftLayers(key: "deepseek.mtp_layers", value: "2"))
        XCTAssertTrue(MtpDetector.declaresDraftLayers(key: "general.multi_token_prediction", value: "true"))
        XCTAssertTrue(MtpDetector.declaresDraftLayers(key: "ARCHITECTURE.MTP", value: "1"))
    }

    func testDeclaresDraftLayersNegativeWhenCountIsZero() {
        XCTAssertFalse(MtpDetector.declaresDraftLayers(key: "qwen2.nextn", value: "0"))
        XCTAssertFalse(MtpDetector.declaresDraftLayers(key: "deepseek.mtp_layers", value: "false"))
        XCTAssertFalse(MtpDetector.declaresDraftLayers(key: "qwen2.nextn", value: ""))
    }

    func testDeclaresDraftLayersNegativeWhenKeyDoesNotMatch() {
        XCTAssertFalse(MtpDetector.declaresDraftLayers(key: "general.architecture", value: "llama"))
        XCTAssertFalse(MtpDetector.declaresDraftLayers(key: "llama.context_length", value: "4096"))
        XCTAssertFalse(MtpDetector.declaresDraftLayers(key: "tokenizer.chat_template", value: "chatml"))
    }

    func testModelDeclaresMtpWithMetadataDictionary() {
        let positiveMeta: [String: String] = [
            "general.architecture": "qwen2",
            "qwen2.block_count": "28",
            "qwen2.nextn": "1",
        ]
        XCTAssertTrue(MtpDetector.modelDeclaresMtp(metadata: positiveMeta))

        let negativeMeta: [String: String] = [
            "general.architecture": "llama",
            "llama.block_count": "32",
            "llama.context_length": "8192",
        ]
        XCTAssertFalse(MtpDetector.modelDeclaresMtp(metadata: negativeMeta))
    }
}
