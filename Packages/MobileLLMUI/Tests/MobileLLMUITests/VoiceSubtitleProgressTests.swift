// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

final class VoiceSubtitleProgressTests: XCTestCase {

    func testEmptyInputsReturnNormalWithoutActiveRange() {
        let emptyLinesResult = VoiceSubtitleProgress.match(lines: [], spokenSentence: "hello")
        XCTAssertEqual(emptyLinesResult.emphases, [])
        XCTAssertNil(emptyLinesResult.activeLineRange)
        XCTAssertNil(emptyLinesResult.matchedStartOffset)

        let emptySpokenResult = VoiceSubtitleProgress.match(
            lines: ["第一句。", "第二句。"],
            spokenSentence: ""
        )
        XCTAssertEqual(emptySpokenResult.emphases, [.normal, .normal])
        XCTAssertNil(emptySpokenResult.activeLineRange)
        XCTAssertNil(emptySpokenResult.matchedStartOffset)

        let punctuationOnlyResult = VoiceSubtitleProgress.match(
            lines: ["第一句。", "第二句。"],
            spokenSentence: "……！？"
        )
        XCTAssertEqual(punctuationOnlyResult.emphases, [.normal, .normal])
        XCTAssertNil(punctuationOnlyResult.activeLineRange)
    }

    func testMatchesCoalescedMultiLineSpokenBatchAndMarksSpokenActiveUpcoming() {
        let lines = [
            "### 准备步骤",
            "第一步打开开关。",
            "第二步等待校准。",
            "第三步开始测试。",
        ]
        let result = VoiceSubtitleProgress.match(
            lines: lines,
            spokenSentence: "第一步打开开关。第二步等待校准。"
        )

        XCTAssertEqual(result.activeLineRange, 1...2)
        XCTAssertEqual(result.emphases, [.spoken, .active, .active, .upcoming])
        XCTAssertEqual(result.matchedStartOffset, 4)
    }

    func testMonotonicSearchFromAdvancesPastRepeatedShortPhrases() {
        let lines = [
            "好的。",
            "第一项完成。",
            "好的。",
            "第二项继续。",
        ]

        let first = VoiceSubtitleProgress.match(lines: lines, spokenSentence: "好的。", searchFrom: 0)
        XCTAssertEqual(first.activeLineRange, 0...0)
        XCTAssertEqual(first.matchedStartOffset, 0)
        XCTAssertEqual(first.emphases, [.active, .upcoming, .upcoming, .upcoming])

        let second = VoiceSubtitleProgress.match(lines: lines, spokenSentence: "好的。", searchFrom: 2)
        XCTAssertEqual(second.activeLineRange, 2...2)
        XCTAssertEqual(second.matchedStartOffset, 7)
        XCTAssertEqual(second.emphases, [.spoken, .spoken, .active, .upcoming])
    }

    func testFallsBackToStartWhenSearchFromExceedsMatchPosition() {
        let lines = [
            "开头第一句。",
            "末尾最后一句。",
        ]

        let result = VoiceSubtitleProgress.match(
            lines: lines,
            spokenSentence: "开头第一句。",
            searchFrom: 50
        )
        XCTAssertEqual(result.activeLineRange, 0...0)
        XCTAssertEqual(result.matchedStartOffset, 0)
        XCTAssertEqual(result.emphases, [.active, .upcoming])
    }

    func testSkipsFencedCodeBlocksAndStripsMarkdownLinkTargets() {
        let lines = [
            "请先看这段示例：",
            "```swift",
            "let x = 1",
            "```",
            "然后访问[官方文档](https://example.com/docs)确认细节。",
        ]

        let result = VoiceSubtitleProgress.match(
            lines: lines,
            spokenSentence: "然后访问官方文档确认细节。"
        )
        XCTAssertEqual(result.activeLineRange, 4...4)
        XCTAssertEqual(result.emphases, [.spoken, .spoken, .spoken, .spoken, .active])
    }

    func testPrefixSuffixAnchorFallbackMatchesAcrossMinorDiscrepancies() {
        let lines = [
            "开场白先跳过。",
            "今天天气晴朗非常适合出门散步并在公园里休息一下最后顺利返回家中完成全部计划。",
            "收尾句。",
        ]
        let spoken = "今天天气晴朗非常适合出门散步还去喝杯咖啡最后顺利返回家中完成全部计划。"

        let result = VoiceSubtitleProgress.match(lines: lines, spokenSentence: spoken)
        XCTAssertEqual(result.activeLineRange, 1...1)
        XCTAssertEqual(result.emphases, [.spoken, .active, .upcoming])
    }
}
