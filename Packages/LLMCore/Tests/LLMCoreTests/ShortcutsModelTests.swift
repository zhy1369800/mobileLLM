// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

final class ShortcutsModelTests: XCTestCase {

    func testBuildMessageSingleTurnWithoutSystemPrompt() {
        let msg = ShortcutsModelPromptBuilder.buildMessage(
            systemPrompt: "",
            history: [],
            currentPrompt: "你好，你是谁？"
        )
        XCTAssertEqual(msg, "你好，你是谁？")
    }

    func testBuildMessageWithSystemPromptAndHistory() {
        let msg = ShortcutsModelPromptBuilder.buildMessage(
            systemPrompt: "你是一个智能助理",
            history: [("user", "今天天气怎么样？"), ("assistant", "今天天气晴朗。")],
            currentPrompt: "那明天呢？"
        )
        XCTAssertTrue(msg.contains("【系统提示】\n你是一个智能助理"))
        XCTAssertTrue(msg.contains("【历史对话】\n用户: 今天天气怎么样？\n助手: 今天天气晴朗。"))
        XCTAssertTrue(msg.contains("【当前提问】\n那明天呢？"))
    }

    func testBuildParamsWithoutFileName() {
        let params = ShortcutsModelPromptBuilder.buildParams(msg: "测试信息")
        XCTAssertEqual(params["msg"] as? String, "测试信息")
        XCTAssertNil(params["fileName"])
    }

    func testBuildParamsWithFileName() {
        let params = ShortcutsModelPromptBuilder.buildParams(msg: "看下这张图", fileName: "image_123.jpg")
        XCTAssertEqual(params["msg"] as? String, "看下这张图")
        XCTAssertEqual(params["fileName"] as? String, "image_123.jpg")
    }
}
