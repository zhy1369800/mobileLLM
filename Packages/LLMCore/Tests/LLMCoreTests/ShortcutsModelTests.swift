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

    func testBuildMessageWithTools() {
        let msg = ShortcutsModelPromptBuilder.buildMessage(
            systemPrompt: "你是一个助手",
            toolDescriptions: "- create_calendar_event(title: String): 创建日程",
            history: [],
            currentPrompt: "帮我定个明早9点的会"
        )
        XCTAssertTrue(msg.contains("【可用工具说明】"))
        XCTAssertTrue(msg.contains("create_calendar_event"))
        XCTAssertTrue(msg.contains("【工具调用格式规范】"))
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

    func testParseToolCallFromMarkdownCodeBlock() {
        let response = """
        好的，正在为您创建日程：
        ```tool_call
        {"tool": "create_calendar_event", "arguments": {"title": "团队周会", "time": "2026-10-12 10:00"}}
        ```
        请稍候。
        """
        let parsed = ShortcutsModelPromptBuilder.parseToolCall(from: response)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.tool, "create_calendar_event")
        XCTAssertEqual(parsed?.arguments["title"] as? String, "团队周会")
    }

    func testParseToolCallFromBareJSON() {
        let response = """
        {"tool": "calculator", "args": {"expression": "125 * 8"}}
        """
        let parsed = ShortcutsModelPromptBuilder.parseToolCall(from: response)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.tool, "calculator")
        XCTAssertEqual(parsed?.arguments["expression"] as? String, "125 * 8")
    }

    func testParseToolCallReturnsNilForNormalText() {
        let response = "今天的天气非常晴朗，气温大约20摄氏度。"
        let parsed = ShortcutsModelPromptBuilder.parseToolCall(from: response)
        XCTAssertNil(parsed)
    }
}
