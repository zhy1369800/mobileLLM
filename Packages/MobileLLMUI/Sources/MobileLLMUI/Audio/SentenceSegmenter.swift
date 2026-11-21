// SPDX-License-Identifier: MIT

import Foundation

/// Stateful incremental sentence segmenter for streaming TTS playback.
///
/// Design goals (aligned with OGAM streaming speech):
/// 1. Never speak thinking blocks (`<think>...</think>`) or tool-call payloads (`<tool_call>...</tool_call>`),
///    even when a model emits them inline inside the answer channel.
/// 2. Avoid breaking inside decimal numbers / version strings (e.g. `3.14`, `v2.1`) or numbered list markers (`1. `).
/// 3. Break long clause-heavy text at commas/semicolons once buffered past a threshold so speech starts promptly.
/// 4. Strip noisy Markdown syntax (`**`, `#`, `![alt](url)`, `[label](url)`, inline backticks) before returning speakable chunks.
/// 5. Consume emitted prefixes incrementally so streaming stays O(N) instead of rescanning the full reply per token.
public struct SentenceSegmenter: Sendable {
    private var rawBuffer: String = ""
    private var insideCodeFence: Bool = false

    /// Minimum buffer length before a clause boundary (comma/semicolon) is treated as a flush point.
    private let longClauseThreshold: Int

    public init(longClauseThreshold: Int = 72) {
        self.longClauseThreshold = longClauseThreshold
    }

    /// Appends a streamed answer delta and returns zero or more complete, speakable sentences.
    public mutating func append(_ delta: String) -> [String] {
        guard !delta.isEmpty else { return [] }
        rawBuffer.append(delta)
        return drain(isFinal: false)
    }

    /// Flushes any remaining partial text when the stream finishes.
    public mutating func finish() -> [String] {
        return drain(isFinal: true)
    }

    /// Resets all buffered state for a new turn or cancellation.
    public mutating func reset() {
        rawBuffer.removeAll(keepingCapacity: false)
        insideCodeFence = false
    }

    // MARK: - Core Pipeline

    private mutating func drain(isFinal: Bool) -> [String] {
        let (speakable, withheldTail) = Self.partitionSpeakablePrefix(from: rawBuffer, isFinal: isFinal)
        guard !speakable.isEmpty else {
            rawBuffer = isFinal ? "" : withheldTail
            return []
        }

        var sentences: [String] = []
        var segmentStart = speakable.startIndex
        var cursor = speakable.startIndex

        while cursor < speakable.endIndex {
            let ch = speakable[cursor]
            let nextIdx = speakable.index(after: cursor)
            let distance = speakable.distance(from: segmentStart, to: nextIdx)

            // Track fenced code blocks (``` ... ```) so multi-line code isn't read punctuation-by-punctuation.
            if ch == "`", speakable[cursor...].hasPrefix("```") {
                if !insideCodeFence {
                    let prose = String(speakable[segmentStart..<cursor])
                    if let cleaned = cleanForSpeech(prose) {
                        sentences.append(cleaned)
                    }
                    insideCodeFence = true
                } else {
                    insideCodeFence = false
                }
                let afterFence = speakable.index(cursor, offsetBy: 3, limitedBy: speakable.endIndex) ?? speakable.endIndex
                segmentStart = afterFence
                cursor = afterFence
                continue
            }

            if insideCodeFence {
                cursor = nextIdx
                continue
            }

            let isBoundary: Bool
            if Self.strongTerminators.contains(ch) {
                isBoundary = true
            } else if ch == "." {
                isBoundary = isPeriodSentenceBoundary(
                    in: speakable,
                    dotIndex: cursor,
                    segmentStart: segmentStart,
                    isFinal: isFinal && withheldTail.isEmpty
                )
            } else if Self.clauseTerminators.contains(ch), distance >= longClauseThreshold {
                isBoundary = true
            } else {
                isBoundary = false
            }

            if isBoundary {
                let candidate = String(speakable[segmentStart..<nextIdx])
                if let cleaned = cleanForSpeech(candidate) {
                    sentences.append(cleaned)
                }
                segmentStart = nextIdx
            }

            cursor = nextIdx
        }

        if isFinal && segmentStart < speakable.endIndex && !insideCodeFence {
            let tail = String(speakable[segmentStart...])
            if let cleaned = cleanForSpeech(tail) {
                sentences.append(cleaned)
            }
            segmentStart = speakable.endIndex
        }

        if isFinal {
            rawBuffer.removeAll(keepingCapacity: false)
        } else if insideCodeFence {
            // Code inside the fence was already skipped; keep at most trailing backticks or withheld tags.
            let unconsumed = String(speakable[segmentStart...])
            let trailingTicks = unconsumed.hasSuffix("``") ? "``" : (unconsumed.hasSuffix("`") ? "`" : "")
            rawBuffer = trailingTicks + withheldTail
        } else {
            rawBuffer = String(speakable[segmentStart...]) + withheldTail
        }

        return sentences
    }

    private func isPeriodSentenceBoundary(
        in text: String,
        dotIndex: String.Index,
        segmentStart: String.Index,
        isFinal: Bool
    ) -> Bool {
        let nextIndex = text.index(after: dotIndex)
        let prevChar: Character? = dotIndex > segmentStart ? text[text.index(before: dotIndex)] : nil

        // Wait for one lookahead character during live streaming so `3.14` isn't split at `3.`.
        if nextIndex == text.endIndex {
            return isFinal
        }

        let nextChar = text[nextIndex]

        // Decimal or version number: `3.14`, `v1.2`
        if let prevChar, prevChar.isNumber, nextChar.isNumber {
            return false
        }

        // Ellipsis `...`: wait until the dots finish.
        if nextChar == "." {
            return false
        }

        // Numbered list marker like `1. Item`: keep the number attached to the list item.
        let prefix = text[segmentStart..<dotIndex].trimmingCharacters(in: .whitespaces)
        if !prefix.isEmpty, prefix.allSatisfy(\.isNumber) {
            return false
        }

        return nextChar.isWhitespace || nextChar.isNewline || Self.isCJK(nextChar)
    }

    // MARK: - Tag Withholding & Markdown Cleanup

    private static let withheldBlockPairs: [(open: String, close: String)] = [
        ("<think>", "</think>"),
        ("<tool_call>", "</tool_call>"),
        ("<|tool_call|>", "<|/tool_call|>"),
        ("<function_call>", "</function_call>"),
        ("<invoke", "</invoke>"),
    ]

    private static let partialOpenerPrefixes: [String] = [
        "<think",
        "<tool_call",
        "<|tool_call",
        "<function_call",
        "<invoke",
    ]

    /// Strips completed hidden blocks and splits out any unclosed/forming block at the tail
    /// so incremental buffer trimming never loses an open `<think>` or `<tool_call>`.
    static func partitionSpeakablePrefix(from raw: String, isFinal: Bool) -> (speakable: String, withheldTail: String) {
        var result = raw
        var withheldTail = ""

        for pair in withheldBlockPairs {
            while let openRange = result.range(of: pair.open, options: .caseInsensitive) {
                if let closeRange = result.range(
                    of: pair.close,
                    options: .caseInsensitive,
                    range: openRange.upperBound..<result.endIndex
                ) {
                    result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                } else {
                    withheldTail = String(result[openRange.lowerBound...]) + withheldTail
                    result = String(result[..<openRange.lowerBound])
                    break
                }
            }
        }

        // Handle templates where `<think>` was injected in the prompt and only `</think>` appears.
        if let loneClose = result.range(of: "</think>", options: .caseInsensitive) {
            result = String(result[loneClose.upperBound...])
        }

        // While streaming, withhold a half-formed `<tool_cal` / `<thi` opener at the very tail.
        if !isFinal, withheldTail.isEmpty, let lastLT = result.lastIndex(of: "<") {
            let tail = String(result[lastLT...]).lowercased()
            if !tail.contains(">") {
                for prefix in partialOpenerPrefixes where prefix.hasPrefix(tail) || tail.hasPrefix(prefix) {
                    withheldTail = String(result[lastLT...])
                    result = String(result[..<lastLT])
                    break
                }
            }
        }

        return (result, withheldTail)
    }

    /// Convenience helper returning the speakable text portion for one-shot inspection.
    static func extractSpeakablePrefix(from raw: String, isFinal: Bool) -> String {
        partitionSpeakablePrefix(from: raw, isFinal: isFinal).speakable
    }

    private func cleanForSpeech(_ raw: String) -> String? {
        var text = raw

        // Markdown images `![alt](url)` MUST run before links `[label](url)` so `!` isn't left behind.
        text = text.replacingOccurrences(
            of: #"!\[([^\]]*)\]\(([^)]+)\)"#,
            with: "$1",
            options: .regularExpression
        )

        // Markdown links `[label](url)` -> `label`
        text = text.replacingOccurrences(
            of: #"\[([^\]]+)\]\(([^)]+)\)"#,
            with: "$1",
            options: .regularExpression
        )

        // Strip Markdown headings, blockquote markers, list bullets, rules, bold/italic/code tokens.
        text = text.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*>\s?"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*[-*_]{3,}\s*$"#, with: "", options: .regularExpression)

        for token in ["**", "__", "~~", "`"] {
            text = text.replacingOccurrences(of: token, with: "")
        }

        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return text
    }

    private static let strongTerminators: Set<Character> = ["。", "！", "？", "!", "?", "…", "\n"]
    private static let clauseTerminators: Set<Character> = ["，", ",", "；", ";", "：", ":"]

    private static func isCJK(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
    }
}
