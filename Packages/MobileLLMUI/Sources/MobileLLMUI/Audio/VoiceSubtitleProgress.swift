// SPDX-License-Identifier: MIT

import Foundation

/// Visual highlight state for a subtitle line relative to active TTS playback.
public enum VoiceSubtitleLineEmphasis: Equatable, Sendable {
    case normal
    case spoken
    case active
    case upcoming
}

/// Output of matching the currently spoken TTS batch against full displayed subtitle lines.
public struct VoiceSubtitleProgressResult: Equatable, Sendable {
    public let emphases: [VoiceSubtitleLineEmphasis]
    public let activeLineRange: ClosedRange<Int>?
    public let matchedStartOffset: Int?

    public init(
        emphases: [VoiceSubtitleLineEmphasis],
        activeLineRange: ClosedRange<Int>?,
        matchedStartOffset: Int?
    ) {
        self.emphases = emphases
        self.activeLineRange = activeLineRange
        self.matchedStartOffset = matchedStartOffset
    }
}

/// Maps the currently spoken sentence batch (`StreamingSpeechCoordinator.currentSpokenSentence`)
/// back onto displayed subtitle lines without needing per-word TTS delegate offsets.
public enum VoiceSubtitleProgress: Sendable {
    public static func match(
        lines: [String],
        spokenSentence: String,
        searchFrom: Int = 0
    ) -> VoiceSubtitleProgressResult {
        guard !lines.isEmpty else {
            return VoiceSubtitleProgressResult(emphases: [], activeLineRange: nil, matchedStartOffset: nil)
        }

        let normalEmphases = Array(repeating: VoiceSubtitleLineEmphasis.normal, count: lines.count)
        let spokenScalars = extractCompactScalars(from: spokenSentence)
        guard !spokenScalars.isEmpty else {
            return VoiceSubtitleProgressResult(
                emphases: normalEmphases,
                activeLineRange: nil,
                matchedStartOffset: nil
            )
        }

        var fullScalars: [Unicode.Scalar] = []
        var lineRanges: [Range<Int>?] = []
        lineRanges.reserveCapacity(lines.count)
        var insideCodeFence = false

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                insideCodeFence.toggle()
                lineRanges.append(nil)
                continue
            }
            if insideCodeFence {
                lineRanges.append(nil)
                continue
            }

            let cleanedLine: String
            if line.contains("](") {
                cleanedLine = line.replacingOccurrences(
                    of: #"!?\[([^\]]*)\]\([^)]+\)"#,
                    with: "$1",
                    options: .regularExpression
                )
            } else {
                cleanedLine = line
            }

            let lineScalars = extractCompactScalars(from: cleanedLine)
            if lineScalars.isEmpty {
                lineRanges.append(nil)
            } else {
                let start = fullScalars.count
                fullScalars.append(contentsOf: lineScalars)
                lineRanges.append(start..<fullScalars.count)
            }
        }

        guard !fullScalars.isEmpty else {
            return VoiceSubtitleProgressResult(
                emphases: normalEmphases,
                activeLineRange: nil,
                matchedStartOffset: nil
            )
        }

        let clampedStart = min(max(searchFrom, 0), fullScalars.count)
        var matchRange = findSubsequence(spokenScalars, in: fullScalars, from: clampedStart)
        if matchRange == nil && clampedStart > 0 {
            matchRange = findSubsequence(spokenScalars, in: fullScalars, from: 0)
        }

        if matchRange == nil && spokenScalars.count >= 6 {
            let anchorLength = min(12, spokenScalars.count)
            let prefix = Array(spokenScalars.prefix(anchorLength))
            let suffix = Array(spokenScalars.suffix(anchorLength))

            var prefixRange = findSubsequence(prefix, in: fullScalars, from: clampedStart)
            if prefixRange == nil && clampedStart > 0 {
                prefixRange = findSubsequence(prefix, in: fullScalars, from: 0)
            }

            if let pRange = prefixRange {
                let suffixLimit = min(fullScalars.count, pRange.lowerBound + spokenScalars.count + 40)
                if let sRange = findSubsequence(suffix, in: fullScalars, from: pRange.lowerBound, endLimit: suffixLimit),
                   sRange.upperBound > pRange.lowerBound
                {
                    matchRange = pRange.lowerBound..<sRange.upperBound
                } else {
                    matchRange = pRange
                }
            }
        }

        guard let resolvedRange = matchRange else {
            return VoiceSubtitleProgressResult(
                emphases: normalEmphases,
                activeLineRange: nil,
                matchedStartOffset: nil
            )
        }

        var firstActive: Int?
        var lastActive: Int?
        for (index, maybeRange) in lineRanges.enumerated() {
            guard let r = maybeRange else { continue }
            if r.lowerBound < resolvedRange.upperBound && r.upperBound > resolvedRange.lowerBound {
                if firstActive == nil {
                    firstActive = index
                }
                lastActive = index
            }
        }

        guard let first = firstActive, let last = lastActive else {
            return VoiceSubtitleProgressResult(
                emphases: normalEmphases,
                activeLineRange: nil,
                matchedStartOffset: nil
            )
        }

        var emphases = [VoiceSubtitleLineEmphasis]()
        emphases.reserveCapacity(lines.count)
        for index in 0..<lines.count {
            if index < first {
                emphases.append(.spoken)
            } else if index <= last {
                emphases.append(.active)
            } else {
                emphases.append(.upcoming)
            }
        }

        return VoiceSubtitleProgressResult(
            emphases: emphases,
            activeLineRange: first...last,
            matchedStartOffset: resolvedRange.lowerBound
        )
    }

    private static func extractCompactScalars(from text: String) -> [Unicode.Scalar] {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(folded.unicodeScalars.count)
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            scalars.append(scalar)
        }
        return scalars
    }

    private static func findSubsequence(
        _ needle: [Unicode.Scalar],
        in haystack: [Unicode.Scalar],
        from start: Int,
        endLimit: Int? = nil
    ) -> Range<Int>? {
        guard !needle.isEmpty else { return nil }
        let effectiveEnd = min(endLimit ?? haystack.count, haystack.count)
        let maxStart = effectiveEnd - needle.count
        guard start >= 0, start <= maxStart else { return nil }

        let first = needle[0]
        var i = start
        while i <= maxStart {
            if haystack[i] == first {
                var matched = true
                var j = 1
                while j < needle.count {
                    if haystack[i + j] != needle[j] {
                        matched = false
                        break
                    }
                    j += 1
                }
                if matched {
                    return i..<(i + needle.count)
                }
            }
            i += 1
        }
        return nil
    }
}
