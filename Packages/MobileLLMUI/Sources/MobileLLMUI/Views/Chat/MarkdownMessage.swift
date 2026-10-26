// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// A parsed block of assistant text (DESIGN §4). LLMs structure answers with markdown — headings,
/// lists, quotes, tables (the stock system prompt even asks for tables) — so the renderer understands
/// the common block grammar, not just fenced code + inline prose.
struct MarkdownBlock: Identifiable {
    /// One row of a list block: nesting level (0 top / 1 nested — one level deep), whether it's ordered,
    /// the author's number for ordered items, and the (inline-markdown) text.
    struct ListRow: Equatable {
        var level: Int
        var ordered: Bool
        var number: Int?
        var text: String
    }

    enum Kind: Equatable {
        case prose(String)
        case code(language: String?, code: String)
        case heading(level: Int, text: String)
        case list([ListRow])
        case quote([String])
        case table(header: [String], rows: [[String]])
        case html(String)
        case diagram(type: String, code: String)
    }

    /// Stable position-based id so SwiftUI reuses the block views across streaming re-parses — a random
    /// UUID per parse forced a full rebuild every token (FlowDown's "reuse by stable id" fix).
    let id: Int
    let kind: Kind

    /// Parse assistant text into blocks. A trailing unterminated ``` fence (mid-stream) still renders as
    /// a code block, and a half-typed table stays prose until its delimiter row arrives, so streaming
    /// never flashes broken structure.
    /// During streaming (`isStreaming == true`), all code blocks (even terminated HTML/Mermaid fences)
    /// remain as lightweight `CodeCard`s to prevent WebKit instantiation and layout thrashing.
    static func parse(_ text: String, isStreaming: Bool = false) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var prose: [String] = []
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { blocks.append(MarkdownBlock(id: blocks.count, kind: .prose(joined))) }
            prose.removeAll()
        }

        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]

            // Fenced code — including a trailing UNTERMINATED fence mid-stream.
            // Stream performance guard: while generating (streaming), keep all fences as lightweight
            // code to prevent WebKit instantiation thrashing on every token. Activate rich rendering only
            // after the closing fence is received in the finalized non-streaming message.
            if line.hasPrefix("```") {
                flushProse()
                let rawLang = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                let lang = rawLang.lowercased()
                var code: [String] = []
                i += 1
                var isClosed = false
                while i < lines.count {
                    if lines[i].hasPrefix("```") {
                        isClosed = true
                        i += 1   // consume the closing fence
                        break
                    }
                    code.append(lines[i])
                    i += 1
                }
                let codeBody = code.joined(separator: "\n")
                if !isStreaming && isClosed && (lang == "html" || lang == "htm") {
                    blocks.append(MarkdownBlock(id: blocks.count, kind: .html(codeBody)))
                } else if !isStreaming && isClosed && lang == "mermaid" {
                    blocks.append(MarkdownBlock(id: blocks.count, kind: .diagram(type: "mermaid", code: codeBody)))
                } else {
                    blocks.append(MarkdownBlock(id: blocks.count,
                                                kind: .code(language: rawLang.isEmpty ? nil : rawLang,
                                                            code: codeBody)))
                }
                continue
            }

            // ATX heading (#…###### followed by a space — GFM requires the space, so "#hashtag" is prose).
            if let heading = atxHeading(line) {
                flushProse()
                blocks.append(MarkdownBlock(id: blocks.count, kind: .heading(level: heading.0, text: heading.1)))
                i += 1
                continue
            }

            // GFM table: a pipe row immediately followed by a delimiter row (|---|:--:|). Until the
            // delimiter arrives (streaming), the header line stays prose so a half-typed table doesn't flash.
            if isTableRow(line), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) {
                flushProse()
                let header = tableCells(line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count, isTableRow(lines[i]) { rows.append(tableCells(lines[i])); i += 1 }
                blocks.append(MarkdownBlock(id: blocks.count, kind: .table(header: header, rows: rows)))
                continue
            }

            // Blockquote — consecutive `>` lines collapse into one quote.
            if isQuote(line) {
                flushProse()
                var quoted: [String] = []
                while i < lines.count, isQuote(lines[i]) { quoted.append(stripQuote(lines[i])); i += 1 }
                blocks.append(MarkdownBlock(id: blocks.count, kind: .quote(quoted)))
                continue
            }

            // List — a run of `-`/`*`/`+`/`1.`/`1)` lines (one level of nesting), tolerant of a single
            // blank line between items (a loose list).
            if listRow(line) != nil {
                flushProse()
                var rows: [ListRow] = []
                while i < lines.count {
                    if let row = listRow(lines[i]) { rows.append(row); i += 1 }
                    else if lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                            i + 1 < lines.count, listRow(lines[i + 1]) != nil { i += 1 }
                    else { break }
                }
                blocks.append(MarkdownBlock(id: blocks.count, kind: .list(rows)))
                continue
            }

            prose.append(line)
            i += 1
        }
        flushProse()
        return blocks
    }

    // MARK: - Line classifiers

    private static func atxHeading(_ line: String) -> (Int, String)? {
        var hashes = 0
        for ch in line { if ch == "#" { hashes += 1 } else { break } }
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        guard let first = rest.first, first == " " || first == "\t" else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes, text)
    }

    private static func isQuote(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }
    private static func stripQuote(_ line: String) -> String {
        var s = Substring(line.trimmingCharacters(in: .whitespaces))
        if s.first == ">" { s = s.dropFirst() }
        if s.first == " " { s = s.dropFirst() }
        return String(s)
    }

    private static func listRow(_ line: String) -> ListRow? {
        var columns = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            columns += line[idx] == "\t" ? 2 : 1
            idx = line.index(after: idx)
        }
        let rest = line[idx...]
        guard let marker = rest.first else { return nil }
        let level = columns >= 2 ? 1 : 0
        if "-*+".contains(marker) {
            let after = rest.dropFirst()
            guard let sp = after.first, sp == " " || sp == "\t" else { return nil }
            let text = after.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : ListRow(level: level, ordered: false, number: nil, text: text)
        }
        var digits = ""
        var j = rest.startIndex
        while j < rest.endIndex, rest[j].isNumber { digits.append(rest[j]); j = rest.index(after: j) }
        guard !digits.isEmpty, j < rest.endIndex, rest[j] == "." || rest[j] == ")" else { return nil }
        let after = rest[rest.index(after: j)...]
        guard let sp = after.first, sp == " " || sp == "\t" else { return nil }
        let text = after.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : ListRow(level: level, ordered: true, number: Int(digits), text: text)
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).contains("|")
    }
    private static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return false }
        let cells = splitPipes(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            var c = Substring(cell.trimmingCharacters(in: .whitespaces))
            guard !c.isEmpty else { return false }
            if c.first == ":" { c = c.dropFirst() }
            if c.last == ":" { c = c.dropLast() }
            return !c.isEmpty && c.allSatisfy { $0 == "-" }
        }
    }
    private static func tableCells(_ line: String) -> [String] {
        splitPipes(line.trimmingCharacters(in: .whitespaces)).map { $0.trimmingCharacters(in: .whitespaces) }
    }
    /// Split a table row on pipes, dropping the empty cells produced by a leading/trailing `|`.
    private static func splitPipes(_ line: String) -> [String] {
        var cells = line.components(separatedBy: "|")
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells
    }
}

enum MarkdownInline {
    private static let lock = NSLock()
    private static var cache: [String: AttributedString] = [:]
    private static let triggerChars: Set<Character> = ["*", "_", "`", "[", "]", "~", "<"]

    static func attributed(_ raw: String) -> AttributedString {
        lock.lock()
        if let hit = cache[raw] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let attr: AttributedString
        if raw.contains(where: { triggerChars.contains($0) }) {
            attr = (try? AttributedString(markdown: raw,
                                   options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(raw)
        } else {
            attr = AttributedString(raw)
        }

        lock.lock()
        if cache.count >= 256 {
            cache.removeAll(keepingCapacity: true)
        }
        cache[raw] = attr
        lock.unlock()

        return attr
    }
}

/// Renders assistant text as markdown blocks — prose, headings, lists, quotes, tables, and fenced code
/// cards (DESIGN §4).
struct MarkdownMessage: View {
    let text: String
    var isStreaming: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            ForEach(MarkdownBlock.parse(text, isStreaming: isStreaming)) { block in
                switch block.kind {
                case .prose(let s): ProseText(s)
                case let .code(language, code): CodeCard(language: language, code: code)
                case let .heading(level, text): MarkdownHeading(level: level, text: text)
                case let .list(rows): MarkdownList(rows: rows)
                case let .quote(lines): MarkdownQuote(lines: lines)
                case let .table(header, rows): MarkdownTable(header: header, rows: rows)
                case let .html(code): HTMLCardView(code: code)
                case let .diagram(type, code): DiagramCardView(type: type, code: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Streaming wrapper: coalesces token-by-token growth to ~20 fps so the markdown re-parse can't thrash
/// on a phone (FlowDown's throttle idea). The inline block caret rides at the tail; the final text is
/// always shown when the caller switches to the non-streaming `MarkdownMessage` on completion.
struct StreamingMarkdown: View {
    let text: String
    @State private var shown = ""
    @State private var lastRenderedAt = Date.distantPast
    @State private var trailingFlush: Task<Void, Never>?
    /// Latest text seen; read by the trailing flush so tokens arriving while it is pending aren't lost
    /// (a value captured at scheduling time would be stale).
    @State private var latest = ""

    private static let interval: TimeInterval = 0.04   // ~25 fps cap, immune to large online chunks

    var body: some View {
        MarkdownMessage(text: shown + "\u{258C}", isStreaming: true)
            .onChange(of: text) { _, new in
                latest = new
                let now = Date()
                let elapsed = now.timeIntervalSince(lastRenderedAt)
                if elapsed >= Self.interval {
                    trailingFlush?.cancel()
                    trailingFlush = nil
                    shown = new
                    lastRenderedAt = now
                } else if trailingFlush == nil {
                    // Trailing-edge flush: if the stream pauses (tool call, network stall) inside the gate,
                    // the withheld tail still lands instead of waiting for the next token.
                    let wait = max(0, Self.interval - elapsed)
                    trailingFlush = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        shown = latest
                        lastRenderedAt = Date()
                        trailingFlush = nil
                    }
                }
            }
            .onAppear { shown = text; latest = text }
            .onDisappear { trailingFlush?.cancel(); trailingFlush = nil }
    }
}

/// Inline-only markdown paragraph (bold / italic / inline-code / links, hard breaks kept).
struct ProseText: View {
    let raw: String
    init(_ raw: String) { self.raw = raw }

    var body: some View {
        Text(MarkdownInline.attributed(raw))
            .font(.body)
            .foregroundStyle(Theme.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// An ATX heading — three type steps (title3 / headline / subheadline) across the six levels.
struct MarkdownHeading: View {
    let level: Int
    let text: String

    private var font: Font {
        switch level {
        case 1: return .title3.weight(.bold)
        case 2: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }

    var body: some View {
        Text(MarkdownInline.attributed(text))
            .font(font)
            .foregroundStyle(Theme.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, level <= 2 ? Theme.Space.xs : 0)
    }
}

/// An unordered/ordered list, one level of nesting. Ordered markers use monospaced digits so the
/// numbers align.
struct MarkdownList: View {
    let rows: [MarkdownBlock.ListRow]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                    Text(marker(row))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                    Text(MarkdownInline.attributed(row.text))
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(row.level) * Theme.Space.lg)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func marker(_ row: MarkdownBlock.ListRow) -> String {
        row.ordered ? "\(row.number ?? 1)." : "•"
    }
}

/// A blockquote — quiet secondary text behind a hairline leading bar.
struct MarkdownQuote: View {
    let lines: [String]

    var body: some View {
        Text(MarkdownInline.attributed(lines.joined(separator: "\n")))
            .font(.body)
            .foregroundStyle(Theme.textSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Theme.Space.md)
            .overlay(alignment: .leading) { Capsule().fill(Theme.textTertiary).frame(width: 2) }
    }
}

/// A GFM table that fits the thread width: columns share the available width proportionally to their
/// content, long text wraps in place, and the card height grows to show every row fully. The thread is
/// never forced to scroll sideways for a table.
struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    /// The table's actual available width, measured from the thread (the GeometryReader lives in the
    /// background so it never greedily expands the card's height).
    @State private var availableWidth: CGFloat = 0
    @State private var isExpanded: Bool = false

    private var columns: Int { max(1, max(header.count, rows.map(\.count).max() ?? 0)) }
    private var isCollapsible: Bool { rows.count > 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if availableWidth > 0 {
                let widths = Self.columnWidths(
                    header: header,
                    rows: rows,
                    totalWidth: availableWidth,
                    spacing: Theme.Space.lg,
                    horizontalPadding: Theme.Space.md * 2
                )
                tableRow(header, widths: widths, header: true)
                Divider().overlay(Theme.hairline)
                let displayRows = (isCollapsible && !isExpanded) ? Array(rows.prefix(3)) : rows
                ForEach(Array(displayRows.enumerated()), id: \.offset) { _, row in
                    tableRow(row, widths: widths, header: false)
                }

                if isCollapsible && !isExpanded {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("查看完整内容")
                                .font(.subheadline.weight(.medium))
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Theme.surface2.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Theme.hairline)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { availableWidth = g.size.width }
                .onChange(of: g.size.width) { _, new in availableWidth = new }
        })
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
    }

    /// Proportional column widths: each column gets weight from the longest text it contains (header
    /// included), so wide columns receive more of the available width and short ones stay compact.
    /// Pure and unit-testable.
    static func columnWidths(
        header: [String],
        rows: [[String]],
        totalWidth: CGFloat,
        spacing: CGFloat,
        horizontalPadding: CGFloat
    ) -> [CGFloat] {
        let columnCount = max(1, max(header.count, rows.map(\.count).max() ?? 0))
        var weights: [CGFloat] = []
        for c in 0..<columnCount {
            let headerWeight = CGFloat(header.indices.contains(c) ? header[c].count : 0) + 1
            let rowWeight = rows
                .compactMap { $0.indices.contains(c) ? CGFloat($0[c].count) : nil }
                .max() ?? 0
            weights.append(max(1, headerWeight + rowWeight))
        }
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return [] }
        let spacingTotal = spacing * CGFloat(max(0, columnCount - 1))
        let content = max(0, totalWidth - spacingTotal - horizontalPadding)
        return weights.map { content * $0 / sum }
    }

    private func tableRow(_ cells: [String], widths: [CGFloat], header: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.lg) {
            ForEach(Array(0..<columns), id: \.self) { c in
                cell(cells.indices.contains(c) ? cells[c] : "",
                     width: widths.indices.contains(c) ? widths[c] : 0,
                     header: header)
            }
        }
    }

    private func cell(_ raw: String, width: CGFloat, header: Bool) -> some View {
        Text(MarkdownInline.attributed(raw))
            .font(.callout.monospacedDigit().weight(header ? .semibold : .regular))
            .foregroundStyle(header ? Theme.textPrimary : Theme.textSecondary)
            .frame(width: max(0, width), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A fenced code block: mono card, language label + Copy, horizontal scroll (never wrap — DESIGN §4).
struct CodeCard: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? "CODE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    Clipboard.copy(code)
                    withAnimation(Motion.spring) { copied = true }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(copied ? Theme.fitGreen : Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied code" : "Copy code")
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.xs)
            .background(Theme.surface2)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(Theme.Space.md)
                    .frame(minWidth: 0, alignment: .leading)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        // Clip to the rounded shape so the header's surface2 fill doesn't poke past the card corners.
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
            .strokeBorder(Theme.hairline))
    }
}

#if DEBUG
#Preview("Markdown message") {
    ScrollView {
        MarkdownMessage(text: """
        ## Reversing a string

        Here's how to reverse a string in **Swift**:

        ```swift
        let reversed = String("hello".reversed())
        print(reversed) // "olleh"
        ```

        Steps:
        1. Take the characters
        2. Reverse them
           - works on any collection
        3. Rebuild a `String`

        > `.reversed()` returns a lazy view — wrap it in `String` to materialize.

        | Approach | Speed |
        | --- | --- |
        | reversed() | fast |
        | manual loop | slow |
        """)
        .padding()
    }
    .background(Theme.bg)
}
#endif

/// HTML block view wrapped in a collapsible preview container
struct HTMLCardView: View {
    let code: String

    var body: some View {
        CollapsibleCardContainer(
            title: "HTML 页面",
            iconName: "chevron.left.forwardslash.chevron.right",
            collapsedHeight: 260,
            sourceCode: code,
            content: {
                RichContentWebView(htmlString: code, isScrollEnabled: false)
                    .frame(maxWidth: .infinity)
            },
            expandedContent: {
                RichContentWebView(htmlString: code, isScrollEnabled: true)
            }
        )
    }
}

/// Diagram (Mermaid) block view wrapped in a collapsible preview container
struct DiagramCardView: View {
    let type: String
    let code: String

    var body: some View {
        CollapsibleCardContainer(
            title: type == "mermaid" ? "流程架构图 (Mermaid)" : "图表预览",
            iconName: "point.3.connected.trianglepath.dotted",
            collapsedHeight: 280,
            sourceCode: code,
            content: {
                MermaidDiagramView(code: code, isInteractiveZoom: false)
                    .frame(maxWidth: .infinity)
            },
            expandedContent: {
                MermaidDiagramView(code: code, isInteractiveZoom: true)
            }
        )
    }
}
