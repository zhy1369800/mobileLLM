// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// A parsed block of assistant text (DESIGN §4). LLMs structure answers with markdown — headings,
/// lists, quotes, tables (the stock system prompt even asks for tables) — so the renderer understands
/// the common block grammar, not just fenced code + inline prose.
struct MarkdownBlock: Identifiable, Equatable {
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
        case image(source: MarkdownImageSource, alt: String?)
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
            if !joined.isEmpty {
                let parsedBlocks = splitProseAndImages(joined, startIndex: blocks.count)
                blocks.append(contentsOf: parsedBlocks)
            }
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

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushProse()
                i += 1
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

    private static func splitProseAndImages(_ text: String, startIndex: Int) -> [MarkdownBlock] {
        guard text.contains("![") && text.contains("](") else {
            return [MarkdownBlock(id: startIndex, kind: .prose(text))]
        }

        let pattern = #"!\[(.*?)\]\((.*?)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return [MarkdownBlock(id: startIndex, kind: .prose(text))]
        }

        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let matches = regex.matches(in: text, options: [], range: fullRange)

        if matches.isEmpty {
            return [MarkdownBlock(id: startIndex, kind: .prose(text))]
        }

        var result: [MarkdownBlock] = []
        var currentId = startIndex
        var lastIndex = 0

        for match in matches {
            let matchRange = match.range
            let altRange = match.range(at: 1)
            let targetRange = match.range(at: 2)

            let rawAlt = nsString.substring(with: altRange)
            let rawTarget = nsString.substring(with: targetRange)

            let trimmedTarget = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalTarget: String
            if trimmedTarget.hasPrefix("data:") {
                finalTarget = trimmedTarget
            } else if let spaceIdx = trimmedTarget.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                finalTarget = String(trimmedTarget[..<spaceIdx])
            } else {
                finalTarget = trimmedTarget
            }

            guard let source = MarkdownImageSource.resolve(finalTarget) else {
                continue
            }

            if matchRange.location > lastIndex {
                let preText = nsString.substring(with: NSRange(location: lastIndex, length: matchRange.location - lastIndex))
                let trimmedPre = preText.trimmingCharacters(in: .newlines)
                if !trimmedPre.isEmpty {
                    result.append(MarkdownBlock(id: currentId, kind: .prose(trimmedPre)))
                    currentId += 1
                }
            }

            let alt = rawAlt.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(MarkdownBlock(id: currentId, kind: .image(source: source, alt: alt.isEmpty ? nil : alt)))
            currentId += 1

            lastIndex = matchRange.location + matchRange.length
        }

        if lastIndex < nsString.length {
            let postText = nsString.substring(with: NSRange(location: lastIndex, length: nsString.length - lastIndex))
            let trimmedPost = postText.trimmingCharacters(in: .newlines)
            if !trimmedPost.isEmpty {
                result.append(MarkdownBlock(id: currentId, kind: .prose(trimmedPost)))
                currentId += 1
            }
        }

        if result.isEmpty {
            return [MarkdownBlock(id: startIndex, kind: .prose(text))]
        }

        return result
    }
}

enum MarkdownInline {
    private static let lock = NSLock()
    private static var cache: [String: AttributedString] = [:]
    private static var order: [String] = []
    private static let maxEntries = 2048
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
        if cache[raw] == nil {
            order.append(raw)
            if order.count > maxEntries {
                // Gently evict the oldest 256 entries rather than wiping the entire cache,
                // preventing catastrophic multi-frame hitching (frame drop avalanche) during fast scrolling.
                let evictCount = min(256, order.count)
                for _ in 0..<evictCount {
                    let oldKey = order.removeFirst()
                    cache.removeValue(forKey: oldKey)
                }
            }
        }
        cache[raw] = attr
        lock.unlock()

        return attr
    }
}

/// Cache for parsed MarkdownBlock ASTs to eliminate repetitive AST parsing in LazyVStack
enum MarkdownBlockCache {
    private static let lock = NSLock()
    private static var cache: [String: [MarkdownBlock]] = [:]
    private static var order: [String] = []
    private static let maxEntries = 512

    // Single-slot incremental streaming state (aligned with kelivo IncrementalMarkdownDocument)
    private static var streamSourcePrefix: String = ""
    private static var streamStableByteCount: Int = 0
    private static var streamStableBlocks: [MarkdownBlock] = []

    static func get(text: String, isStreaming: Bool) -> [MarkdownBlock]? {
        guard !isStreaming else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return cache[text]
    }

    static func set(text: String, blocks: [MarkdownBlock], isStreaming: Bool) {
        guard !isStreaming else { return }
        lock.lock()
        defer { lock.unlock() }
        if cache[text] == nil {
            order.append(text)
            if order.count > maxEntries {
                let evicted = order.removeFirst()
                cache.removeValue(forKey: evicted)
            }
        }
        cache[text] = blocks
    }

    /// Incremental streaming parser: freezes completed blocks before safe blank-line boundaries so
    /// each 50ms tick only parses the active trailing paragraph/fence in O(delta) time.
    static func parseStreaming(text: String) -> [MarkdownBlock] {
        let totalBytes = text.utf8.count
        guard totalBytes >= 512 else {
            return MarkdownBlock.parse(text, isStreaming: true)
        }
        lock.lock()
        defer { lock.unlock() }

        if totalBytes < streamStableByteCount || !hasMatchingStreamPrefix(text) {
            streamSourcePrefix = ""
            streamStableByteCount = 0
            streamStableBlocks.removeAll(keepingCapacity: true)
        }

        let startIdx = text.utf8.index(text.utf8.startIndex, offsetBy: streamStableByteCount)
        let unscanned = text[startIdx...]

        if unscanned.utf8.count >= 256, let safeBreak = findSafeBreak(in: unscanned) {
            let chunk = String(unscanned[..<safeBreak])
            let parsedChunk = MarkdownBlock.parse(chunk, isStreaming: true)
            let baseId = streamStableBlocks.count
            for (offset, b) in parsedChunk.enumerated() {
                streamStableBlocks.append(MarkdownBlock(id: baseId + offset, kind: b.kind))
            }
            streamStableByteCount = text[..<safeBreak].utf8.count
            streamSourcePrefix = String(text[..<safeBreak])
        }

        let tailStart = text.utf8.index(text.utf8.startIndex, offsetBy: streamStableByteCount)
        let tail = String(text[tailStart...])
        let tailBlocks = MarkdownBlock.parse(tail, isStreaming: true)
        var result = streamStableBlocks
        let baseId = result.count
        for (offset, b) in tailBlocks.enumerated() {
            result.append(MarkdownBlock(id: baseId + offset, kind: b.kind))
        }
        return result
    }

    private static func hasMatchingStreamPrefix(_ text: String) -> Bool {
        guard streamStableByteCount > 0 else { return true }
        guard text.utf8.count >= streamStableByteCount else { return false }
        if streamStableByteCount <= 64 {
            return text.utf8.starts(with: streamSourcePrefix.utf8)
        }
        let checkIdx = text.utf8.index(text.utf8.startIndex, offsetBy: streamStableByteCount - 1)
        let prefixLastIdx = streamSourcePrefix.utf8.index(before: streamSourcePrefix.utf8.endIndex)
        return text.utf8.first == streamSourcePrefix.utf8.first
            && text.utf8[checkIdx] == streamSourcePrefix.utf8[prefixLastIdx]
    }

    private static func findSafeBreak(in slice: Substring) -> String.Index? {
        guard let range = slice.range(of: "\n\n", options: .backwards) else { return nil }
        let candidate = slice[..<range.lowerBound]
        var fenceCount = 0
        var lastNonEmptyLine = ""
        for line in candidate.components(separatedBy: "\n") {
            if line.hasPrefix("```") { fenceCount += 1 }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lastNonEmptyLine = trimmed }
        }
        guard fenceCount % 2 == 0, !lastNonEmptyLine.isEmpty else { return nil }
        // Do not split right after a list item, quote, or table row in case the next line continues it
        if let firstChar = lastNonEmptyLine.first, "-*+>".contains(firstChar) { return nil }
        if lastNonEmptyLine.contains("|") { return nil }
        if lastNonEmptyLine.first?.isNumber == true && (lastNonEmptyLine.contains(". ") || lastNonEmptyLine.contains(") ")) {
            return nil
        }
        return range.upperBound
    }

    /// Background warm-up of markdown AST for an array of message texts
    static func warmup(texts: [String]) {
        guard !texts.isEmpty else { return }
        Task.detached(priority: .utility) {
            for text in texts {
                if get(text: text, isStreaming: false) == nil {
                    let parsed = MarkdownBlock.parse(text, isStreaming: false)
                    set(text: text, blocks: parsed, isStreaming: false)
                }
            }
        }
    }
}

/// Equatable block row so SwiftUI short-circuits unchanged prefix blocks during 20fps streaming ticks.
private struct MarkdownBlockRow: View, Equatable {
    let block: MarkdownBlock
    let isStreaming: Bool

    var body: some View {
        switch block.kind {
        case .prose(let s): ProseText(s)
        case let .code(language, code): CodeCard(language: language, code: code, isStreaming: isStreaming)
        case let .heading(level, text): MarkdownHeading(level: level, text: text)
        case let .list(rows): MarkdownList(rows: rows)
        case let .quote(lines): MarkdownQuote(lines: lines)
        case let .table(header, rows): MarkdownTable(header: header, rows: rows)
        case let .html(code): HTMLCardView(code: code)
        case let .diagram(type, code): DiagramCardView(type: type, code: code)
        case let .image(source, alt): MarkdownImageView(source: source, alt: alt)
        }
    }
}

/// Renders assistant text as markdown blocks — prose, headings, lists, quotes, tables, and fenced code
/// cards (DESIGN §4).
struct MarkdownMessage: View {
    let text: String
    var isStreaming: Bool = false

    var body: some View {
        let blocks = isStreaming
            ? MarkdownBlockCache.parseStreaming(text: text)
            : (MarkdownBlockCache.get(text: text, isStreaming: false) ?? {
                let parsed = MarkdownBlock.parse(text, isStreaming: false)
                MarkdownBlockCache.set(text: text, blocks: parsed, isStreaming: false)
                return parsed
            }())

        VStack(alignment: .leading, spacing: Theme.Space.md) {
            ForEach(blocks) { block in
                MarkdownBlockRow(block: block, isStreaming: isStreaming)
                    .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Pure helper calculating smooth typing cadence and safe character advancement.
enum StreamingPacer {
    /// Adaptive step count based on unrendered backlog size (in characters) to provide
    /// smooth typewriter cadence (~20 fps) without falling behind bursty cloud providers.
    static func nextStep(backlog: Int) -> Int {
        if backlog <= 4 {
            return min(max(1, backlog), 2)
        } else if backlog <= 16 {
            return 4
        } else {
            return min(120, max(6, backlog / 3))
        }
    }

    /// Advances visible text towards target in O(step) time rather than scanning the full document.
    static func advance(visible: String, toward target: String, maxStep: Int? = nil) -> String {
        let visibleBytes = visible.utf8.count
        let targetBytes = target.utf8.count
        guard targetBytes > visibleBytes, hasMatchingPrefix(visible: visible, toward: target) else {
            return target
        }
        let splitIdx = target.utf8.index(target.utf8.startIndex, offsetBy: visibleBytes)
        if let maxStep {
            guard maxStep > 0 else { return target }
            guard let sliceEnd = target.index(splitIdx, offsetBy: maxStep, limitedBy: target.endIndex),
                  sliceEnd < target.endIndex else {
                return target
            }
            return String(target[..<sliceEnd])
        }
        let remainingBytes = targetBytes - visibleBytes
        let step: Int
        if remainingBytes > 512 {
            step = 120
        } else {
            let backlog = target[splitIdx...].count
            guard backlog > 0 else { return target }
            step = nextStep(backlog: backlog)
            guard step < backlog else { return target }
        }
        guard let sliceEnd = target.index(splitIdx, offsetBy: step, limitedBy: target.endIndex),
              sliceEnd < target.endIndex else {
            return target
        }
        return String(target[..<sliceEnd])
    }

    private static func hasMatchingPrefix(visible: String, toward target: String) -> Bool {
        let visibleBytes = visible.utf8.count
        guard visibleBytes > 0 else { return true }
        if visibleBytes <= 64 {
            return target.utf8.starts(with: visible.utf8)
        }
        let checkIdx = target.utf8.index(target.utf8.startIndex, offsetBy: visibleBytes - 1)
        let visibleLastIdx = visible.utf8.index(before: visible.utf8.endIndex)
        return target.utf8.first == visible.utf8.first
            && target.utf8[checkIdx] == visible.utf8[visibleLastIdx]
    }
}

/// Streaming wrapper: provides smooth typewriter-like streaming interpolation (~20 fps) to eliminate
/// visual stutter and jumpiness from bursty cloud API network chunks. The inline block caret rides at
/// the tail; the final text is always shown when the caller switches to non-streaming `MarkdownMessage`.
struct StreamingMarkdown: View {
    let text: String
    @State private var shown = ""
    @State private var target = ""
    @State private var ticker: Task<Void, Never>?

    private static let frameIntervalNs: UInt64 = 50_000_000 // 50ms (20 fps, aligned with kelivo)

    var body: some View {
        MarkdownMessage(text: shown + "\u{258C}", isStreaming: true)
            .onChange(of: text) { _, new in
                target = new
                ensureTicker()
            }
            .onAppear {
                shown = text
                target = text
            }
            .onDisappear {
                ticker?.cancel()
                ticker = nil
            }
    }

    private func ensureTicker() {
        guard ticker == nil, shown != target else { return }
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                guard shown != target else { break }
                shown = StreamingPacer.advance(visible: shown, toward: target)
                // Always hold the gate for a full 50ms interval after advancing so rapid
                // single-token arrivals coalesce into `target` instead of bypassing the gate.
                try? await Task.sleep(nanoseconds: Self.frameIntervalNs)
            }
            ticker = nil
        }
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
            .frame(maxWidth: .infinity, alignment: .leading)
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
            .frame(maxWidth: .infinity, alignment: .leading)
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(row.level) * Theme.Space.lg)
            }
        }
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
    /// Default to sensible initial reading column width (340) so the first frame renders full height immediately,
    /// eliminating the 2-phase jitter from height: 0 to measured height.
    @State private var availableWidth: CGFloat = 340
    @State private var isExpanded: Bool = false

    private static let maxCollapsedRows = 10
    private var columns: Int { max(1, max(header.count, rows.map(\.count).max() ?? 0)) }
    private var isCollapsible: Bool { rows.count > Self.maxCollapsedRows }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            let width = max(200, availableWidth)
            let widths = Self.columnWidths(
                header: header,
                rows: rows,
                totalWidth: width,
                spacing: Theme.Space.lg,
                horizontalPadding: Theme.Space.md * 2
            )
            tableRow(header, widths: widths, header: true)
            Divider().overlay(Theme.hairline)
            let displayRows = (isCollapsible && !isExpanded) ? Array(rows.prefix(Self.maxCollapsedRows)) : rows
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
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { g in
            Color.clear
                .onAppear {
                    if g.size.width > 50 && abs(availableWidth - g.size.width) > 30 {
                        availableWidth = g.size.width
                    }
                }
                .onChange(of: g.size.width) { _, new in
                    if new > 50 && abs(availableWidth - new) > 30 {
                        availableWidth = new
                    }
                }
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
    var isStreaming: Bool = false
    @State private var copied = false

    /// Capped height matching the finalized `HTMLCardView` (260pt) / `DiagramCardView` (280pt) so
    /// streaming a 500-line HTML/Mermaid block never inflates the message to 8,000pt and then
    /// collapses to 260pt on completion (which leaves LazyVStack stranded on a blank bottom page).
    private var previewCapHeight: CGFloat? {
        guard let lang = language?.lowercased() else { return nil }
        if lang == "html" || lang == "htm" { return 260 }
        if lang == "mermaid" { return 280 }
        return nil
    }

    private var displayedStreamingCode: String {
        guard previewCapHeight != nil else { return code }
        var newlineCount = 0
        var idx = code.endIndex
        while idx > code.startIndex {
            idx = code.index(before: idx)
            if code[idx] == "\n" {
                newlineCount += 1
                if newlineCount >= 20 {
                    return String(code[code.index(after: idx)...])
                }
            }
        }
        return code
    }

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

            if let capHeight = previewCapHeight, isStreaming {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(displayedStreamingCode)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(Theme.Space.md)
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(minWidth: 0, alignment: .leading)
                }
                .frame(maxHeight: capHeight, alignment: .bottomLeading)
                .clipped()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    if isStreaming {
                        Text(code)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(Theme.Space.md)
                            .frame(minWidth: 0, alignment: .leading)
                    } else {
                        Text(code)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .padding(Theme.Space.md)
                            .frame(minWidth: 0, alignment: .leading)
                    }
                }
                .frame(maxHeight: previewCapHeight)
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
            title: type == "mermaid" ? "流程架构图" : "图表预览",
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
