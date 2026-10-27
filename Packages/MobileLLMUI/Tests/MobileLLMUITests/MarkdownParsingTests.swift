// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI

/// `MarkdownBlock.parse` block grammar (DESIGN §4): headings, lists, quotes, tables, and fenced code —
/// plus the streaming-partial cases the composer must survive mid-token.
final class MarkdownParsingTests: XCTestCase {

    private func row(_ level: Int, _ ordered: Bool, _ number: Int?, _ text: String) -> MarkdownBlock.ListRow {
        MarkdownBlock.ListRow(level: level, ordered: ordered, number: number, text: text)
    }

    // MARK: Headings

    func testHeadingsParseWithLevels() {
        let kinds = MarkdownBlock.parse("# Title\n## Section\n#### Deep\nbody").map(\.kind)
        XCTAssertEqual(kinds, [
            .heading(level: 1, text: "Title"),
            .heading(level: 2, text: "Section"),
            .heading(level: 4, text: "Deep"),
            .prose("body"),
        ])
    }

    func testHashWithoutSpaceIsProse() {
        // GFM requires a space after the #'s — so "#hashtag" is prose, not an empty h1.
        XCTAssertEqual(MarkdownBlock.parse("#nothashtag").map(\.kind), [.prose("#nothashtag")])
    }

    // MARK: Lists

    func testNestedUnorderedListOneLevel() {
        let kinds = MarkdownBlock.parse("- a\n- b\n  - b1\n- c").map(\.kind)
        XCTAssertEqual(kinds, [.list([
            row(0, false, nil, "a"),
            row(0, false, nil, "b"),
            row(1, false, nil, "b1"),
            row(0, false, nil, "c"),
        ])])
    }

    func testOrderedListKeepsAuthorNumbers() {
        let kinds = MarkdownBlock.parse("1. one\n2. two\n3. three").map(\.kind)
        XCTAssertEqual(kinds, [.list([
            row(0, true, 1, "one"),
            row(0, true, 2, "two"),
            row(0, true, 3, "three"),
        ])])
    }

    func testLooseListToleratesSingleBlankLine() {
        let kinds = MarkdownBlock.parse("- a\n\n- b").map(\.kind)
        XCTAssertEqual(kinds, [.list([row(0, false, nil, "a"), row(0, false, nil, "b")])])
    }

    // MARK: Quotes

    func testBlockquoteCollapsesConsecutiveLines() {
        XCTAssertEqual(MarkdownBlock.parse("> first\n> second").map(\.kind),
                       [.quote(["first", "second"])])
    }

    // MARK: Tables

    func testTableParsesHeaderAndRows() {
        let md = "| Name | Age |\n| --- | --- |\n| Alice | 30 |\n| Bob | 25 |"
        XCTAssertEqual(MarkdownBlock.parse(md).map(\.kind),
                       [.table(header: ["Name", "Age"], rows: [["Alice", "30"], ["Bob", "25"]])])
    }

    func testStreamingPartialTable() {
        // Header alone (delimiter not streamed yet) stays prose — no table flash mid-stream.
        XCTAssertEqual(MarkdownBlock.parse("| Name | Age |").map(\.kind), [.prose("| Name | Age |")])
        // Header + delimiter, no body rows yet → an empty table, not broken markup.
        XCTAssertEqual(MarkdownBlock.parse("| Name | Age |\n| --- | --- |").map(\.kind),
                       [.table(header: ["Name", "Age"], rows: [])])
        // Header + delimiter + one row still arriving (no trailing pipe).
        XCTAssertEqual(MarkdownBlock.parse("| Name | Age |\n| --- | --- |\n| Alice | 30").map(\.kind),
                       [.table(header: ["Name", "Age"], rows: [["Alice", "30"]])])
    }

    // MARK: Code (kept working)

    func testCodeFenceStillParses() {
        let kinds = MarkdownBlock.parse("intro\n```swift\nlet x = 1\n```\noutro").map(\.kind)
        XCTAssertEqual(kinds, [.prose("intro"), .code(language: "swift", code: "let x = 1"), .prose("outro")])
    }

    func testUnterminatedCodeFenceMidStreamStaysCode() {
        XCTAssertEqual(MarkdownBlock.parse("```python\nprint(1)").map(\.kind),
                       [.code(language: "python", code: "print(1)")])
    }

    // MARK: Mixed document

    func testMixedDocumentBlockSequence() {
        let md = """
        ## Heading

        A paragraph with **bold**.

        - item one
        - item two

        > a quote

        ```swift
        let x = 1
        ```

        | A | B |
        | --- | --- |
        | 1 | 2 |
        """
        let kinds = MarkdownBlock.parse(md).map(\.kind)
        XCTAssertEqual(kinds.count, 6, "heading, prose, list, quote, code, table")
        if case .heading(let l, _) = kinds[0] { XCTAssertEqual(l, 2) } else { XCTFail("block 0 should be a heading") }
        if case .prose = kinds[1] {} else { XCTFail("block 1 should be prose") }
        if case .list = kinds[2] {} else { XCTFail("block 2 should be a list") }
        if case .quote = kinds[3] {} else { XCTFail("block 3 should be a quote") }
        if case .code = kinds[4] {} else { XCTFail("block 4 should be code") }
        if case .table = kinds[5] {} else { XCTFail("block 5 should be a table") }
    }

    // MARK: Table layout

    func testColumnWidthsAreProportionalAndFitTotal() {
        let widths = MarkdownTable.columnWidths(
            header: ["A", "Long header column"],
            rows: [["x", "A very long cell that should receive more space than the short column"]],
            totalWidth: 300,
            spacing: 8,
            horizontalPadding: 16
        )
        XCTAssertEqual(widths.count, 2)
        XCTAssertTrue(widths[1] > widths[0],
                      "the wider column must receive more of the available width")
        let total = widths.reduce(0, +)
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThanOrEqual(total, 300 - 16 - 8,
                                 "columns must fit the content width without horizontal scrolling")
    }

    func testColumnWidthsHandleEmptyAndRaggedTables() {
        let empty = MarkdownTable.columnWidths(
            header: [],
            rows: [],
            totalWidth: 200,
            spacing: 8,
            horizontalPadding: 16
        )
        XCTAssertEqual(empty.count, 1)
        XCTAssertGreaterThan(empty[0], 0)

        let ragged = MarkdownTable.columnWidths(
            header: ["Only"],
            rows: [["a", "extra", "third"], ["b"]],
            totalWidth: 200,
            spacing: 8,
            horizontalPadding: 16
        )
        XCTAssertEqual(ragged.count, 3, "missing cells must still reserve a column")
        XCTAssertGreaterThan(ragged[0], 0)
        XCTAssertGreaterThan(ragged[1], 0)
        XCTAssertGreaterThan(ragged[2], 0)
    }

    // MARK: HTML & Diagram parsing

    func testHtmlCodeBlockParsesAsHtmlKind() {
        let text = "before\n```html\n<div>Hello World</div>\n```\nafter"
        let kinds = MarkdownBlock.parse(text).map(\.kind)
        XCTAssertEqual(kinds, [
            .prose("before"),
            .html("<div>Hello World</div>"),
            .prose("after")
        ])
    }

    func testHtmCodeBlockCaseInsensitiveParsesAsHtmlKind() {
        let text = "```HTM\n<p>Test</p>\n```"
        let kinds = MarkdownBlock.parse(text).map(\.kind)
        XCTAssertEqual(kinds, [.html("<p>Test</p>")])
    }

    func testMermaidCodeBlockParsesAsDiagramKind() {
        let text = "```mermaid\ngraph TD; A-->B;\n```"
        let kinds = MarkdownBlock.parse(text).map(\.kind)
        XCTAssertEqual(kinds, [.diagram(type: "mermaid", code: "graph TD; A-->B;")])
    }

    func testUnterminatedHtmlMidStreamStaysCodeForPerformance() {
        // Unterminated code fence mid-stream must stay as plain .code to prevent WebKit thrashing
        let text = "```html\n<table><tr><td>streaming</td>"
        let kinds = MarkdownBlock.parse(text).map(\.kind)
        XCTAssertEqual(kinds, [.code(language: "html", code: "<table><tr><td>streaming</td>")])
    }

    func testTerminatedHtmlMidStreamPromotesToHtmlKind() {
        // Once closing fence arrives, it safely promotes to .html in non-streaming (finalized) mode
        let text = "```html\n<table><tr><td>streaming</td>\n```"
        let kinds = MarkdownBlock.parse(text).map(\.kind)
        XCTAssertEqual(kinds, [.html("<table><tr><td>streaming</td>")])
    }

    func testTerminatedHtmlDuringStreamingStaysCodeToPreventThrashing() {
        // During active streaming, even closed fences remain as lightweight .code to avoid WebKit thrashing
        let text = "```html\n<table><tr><td>streaming</td>\n```\nmore tokens"
        let kinds = MarkdownBlock.parse(text, isStreaming: true).map(\.kind)
        XCTAssertEqual(kinds, [
            .code(language: "html", code: "<table><tr><td>streaming</td>"),
            .prose("more tokens")
        ])
    }

    func testTerminatedMermaidDuringStreamingStaysCodeToPreventThrashing() {
        // During active streaming, closed mermaid fences also stay as .code
        let text = "```mermaid\ngraph TD; A-->B;\n```\nmore tokens"
        let kinds = MarkdownBlock.parse(text, isStreaming: true).map(\.kind)
        XCTAssertEqual(kinds, [
            .code(language: "mermaid", code: "graph TD; A-->B;"),
            .prose("more tokens")
        ])
    }

    // MARK: Mermaid Sanitizer

    func testSanitizeMermaidCodeWrapsUnquotedSpecialLabels() {
        let input = """
        graph TD
            A[输入序列 X1,X2,...Xn] --> B[TOKEN EMBEDDING<br/>词向量 + 位置编码]
            D --> E[注意力分数<br/>Q · K^T / √d_k]
            E --> F[softmax(Q·K^T)]
            formula[Attention(Q,K,V) = softmax(QK^T/√d_k) · V]
            alreadyQuoted["Keep (This) Safe"]
            plainNode[SimpleText]
        """

        let sanitized = MermaidDiagramView.sanitizeMermaidCode(input)

        XCTAssertTrue(sanitized.contains(#"E["注意力分数<br/>Q · K^T / √d_k"]"#))
        XCTAssertTrue(sanitized.contains(#"F["softmax(Q·K^T)"]"#))
        XCTAssertTrue(sanitized.contains(#"formula["Attention(Q,K,V) = softmax(QK^T/√d_k) · V"]"#))
        XCTAssertTrue(sanitized.contains(#"alreadyQuoted["Keep (This) Safe"]"#), "Already quoted labels must not be double quoted")
        XCTAssertTrue(sanitized.contains(#"plainNode[SimpleText]"#), "Labels without special characters should remain unquoted")
    }

    func testSanitizeMermaidCodeSplitsDoublePipesAndSanitizesQuotes() {
        let input = """
        graph TD
            A[用户访问网站] --> B{是否登录？}
            B --> C[是] || B --> D[否]
            C --> E[跳转到主页]
            D --> E

            E --> F[进入登录页面]
            F --> G[输入用户名/密码]
            G --> H[提交登录]
            H --> I{登录成功？}
            I --> J[是] || I --> K[否]

            J --> L[跳转到首页]
            K --> M[提示 "请输入正确凭据"]

            M --> N[重新尝试登录]
        """

        let sanitized = MermaidDiagramView.sanitizeMermaidCode(input)
        XCTAssertFalse(sanitized.contains("||"), "Inline double pipes must be split into separate lines")
        XCTAssertTrue(sanitized.contains("B --> C[是]"))
        XCTAssertTrue(sanitized.contains("B --> D[否]"))
        XCTAssertTrue(sanitized.contains("I --> J[是]"))
        XCTAssertTrue(sanitized.contains("I --> K[否]"))
        XCTAssertTrue(sanitized.contains(#"K --> M["提示 '请输入正确凭据'"]"#))
        XCTAssertTrue(sanitized.contains(#"G["输入用户名/密码"]"#))
        XCTAssertTrue(sanitized.contains(#"B{"是否登录？"}"#))
        XCTAssertTrue(sanitized.contains(#"I{"登录成功？"}"#))
    }

    func testSanitizeMermaidPreservesStandardShapesAndERDiagrams() {
        let erInput = """
        erDiagram
            CUSTOMER ||--o{ ORDER : places
            ORDER ||--|{ LINE_ITEM : contains
        """
        let sanitizedER = MermaidDiagramView.sanitizeMermaidCode(erInput)
        XCTAssertTrue(sanitizedER.contains("CUSTOMER ||--o{ ORDER : places"), "ER relationship line must not be split")

        let shapesInput = """
        graph TD
            db[(Database)] --> app[App]
            start((Start)) --> stop((Stop))
            stadium([Stadium Label]) --> hex{{Hexagon}}
        """
        let sanitizedShapes = MermaidDiagramView.sanitizeMermaidCode(shapesInput)
        XCTAssertTrue(sanitizedShapes.contains("db[(Database)]"), "Cylinder syntax must not be corrupted")
        XCTAssertTrue(sanitizedShapes.contains("start((Start))"), "Circle syntax must not be corrupted")
        XCTAssertTrue(sanitizedShapes.contains("stadium([Stadium Label])"), "Stadium syntax must not be corrupted")
        XCTAssertTrue(sanitizedShapes.contains("hex{{Hexagon}}"), "Hexagon syntax must not be corrupted")
    }
    // MARK: Streaming Pacer Tests

    func testStreamingPacerCadenceSteps() {
        XCTAssertEqual(StreamingPacer.nextStep(backlog: 0), 1)
        XCTAssertEqual(StreamingPacer.nextStep(backlog: 1), 1)
        XCTAssertEqual(StreamingPacer.nextStep(backlog: 2), 2)
        XCTAssertEqual(StreamingPacer.nextStep(backlog: 4), 2)
        XCTAssertEqual(StreamingPacer.nextStep(backlog: 5), 4)
        XCTAssertEqual(StreamingPacer.nextStep(backlog: 16), 4)
        XCTAssertEqual(StreamingPacer.nextStep(backlog: 18), 6)
        XCTAssertEqual(StreamingPacer.nextStep(backlog: 60), 20)
        XCTAssertEqual(StreamingPacer.nextStep(backlog: 500), 120) // Clamped at 120
    }

    func testStreamingPacerAdvanceText() {
        let target = "Hello, world!"
        var visible = "Hello"
        visible = StreamingPacer.advance(visible: visible, toward: target, maxStep: 2)
        XCTAssertEqual(visible, "Hello, ")
        visible = StreamingPacer.advance(visible: visible, toward: target, maxStep: 10)
        XCTAssertEqual(visible, target)
        // Calling advance when already equal returns target
        XCTAssertEqual(StreamingPacer.advance(visible: visible, toward: target, maxStep: 5), target)
        // Diverged target resets
        XCTAssertEqual(StreamingPacer.advance(visible: "Something else", toward: target, maxStep: 5), target)
    }

    func testStreamingPacerEmojiAndMultiByteSafety() {
        let target = "你好👋世界👨‍👩‍👧‍👦🎉"
        var visible = ""
        while visible.count < target.count {
            let next = StreamingPacer.advance(visible: visible, toward: target, maxStep: 1)
            XCTAssertTrue(next.count > visible.count)
            XCTAssertTrue(target.hasPrefix(next))
            visible = next
        }
        XCTAssertEqual(visible, target)
    }


    // MARK: Images & Multi-Protocol Tests

    func testRemoteImageParses() {
        let md = "![Cat](https://example.com/cat.png)"
        let blocks = MarkdownBlock.parse(md)
        XCTAssertEqual(blocks.count, 1)
        guard case let .image(source, alt) = blocks[0].kind else {
            return XCTFail("Expected image block")
        }
        XCTAssertEqual(alt, "Cat")
        XCTAssertEqual(source, .remote(URL(string: "https://example.com/cat.png")!))
    }

    func testLocalFileUriAndAbsolutePath() {
        let fileUriMd = "![Local](file:///var/mobile/photo.jpg)"
        let fileBlocks = MarkdownBlock.parse(fileUriMd)
        XCTAssertEqual(fileBlocks.count, 1)
        guard case let .image(fileSource, _) = fileBlocks[0].kind else {
            return XCTFail("Expected image block for file URI")
        }
        XCTAssertEqual(fileSource, .file(URL(string: "file:///var/mobile/photo.jpg")!))

        let absMd = "![Abs](/var/mobile/test.png)"
        let absBlocks = MarkdownBlock.parse(absMd)
        XCTAssertEqual(absBlocks.count, 1)
        guard case let .image(absSource, _) = absBlocks[0].kind else {
            return XCTFail("Expected image block for absolute path")
        }
        XCTAssertEqual(absSource, .file(URL(fileURLWithPath: "/var/mobile/test.png")))
    }

    func testBase64DataUriParses() {
        // 1x1 transparent PNG in base64
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        let md = "![Dot](data:image/png;base64,\(base64))"
        let blocks = MarkdownBlock.parse(md)
        XCTAssertEqual(blocks.count, 1)
        guard case let .image(source, alt) = blocks[0].kind else {
            return XCTFail("Expected image block for data URI")
        }
        XCTAssertEqual(alt, "Dot")
        guard case let .data(data) = source else {
            return XCTFail("Expected .data source")
        }
        XCTAssertFalse(data.isEmpty)
    }

    func testProseWithInlineImageSplitsCorrectly() {
        let md = "Check this diagram:\n![Architecture](https://example.com/arch.png)\nLooks great!"
        let blocks = MarkdownBlock.parse(md)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].kind, .prose("Check this diagram:"))
        XCTAssertEqual(blocks[1].kind, .image(source: .remote(URL(string: "https://example.com/arch.png")!), alt: "Architecture"))
        XCTAssertEqual(blocks[2].kind, .prose("Looks great!"))
    }

    func testStreamingIncompleteImageStaysProse() {
        // Stream mid-token where closing parenthesis is not yet arrived
        let streamingMd = "Here is the pic: ![Diagram](https://example.com/arch"
        let blocks = MarkdownBlock.parse(streamingMd)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .prose(streamingMd))
    }
}
