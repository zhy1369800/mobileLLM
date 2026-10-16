// SPDX-License-Identifier: MIT

import Foundation
import llama

/// High-efficiency prompt-lookup draft generator (N-gram speculation).
/// Finds recurring token patterns in the recent conversational context to propose candidate tokens
/// ahead of time without needing a separate draft model.
public struct PromptLookupDrafter: Sendable {
    public let maxDraftTokens: Int
    public let minNgram: Int
    public let maxNgram: Int
    public let maxLookbackWindow: Int

    public init(maxDraftTokens: Int = 3, minNgram: Int = 2, maxNgram: Int = 4, maxLookbackWindow: Int = 512) {
        self.maxDraftTokens = max(1, min(maxDraftTokens, 8))
        self.minNgram = max(1, minNgram)
        self.maxNgram = max(self.minNgram, maxNgram)
        self.maxLookbackWindow = max(16, maxLookbackWindow)
    }

    /// Propose up to `maxDraftTokens` candidates by searching for matching n-gram occurrences in `tokens`.
    public func propose(from tokens: [llama_token]) -> [llama_token] {
        let n = tokens.count
        guard n >= minNgram + 1 else { return [] }

        let currentMaxNgram = min(maxNgram, n - 1)
        guard currentMaxNgram >= minNgram else { return [] }

        for ngram in stride(from: currentMaxNgram, through: minNgram, by: -1) {
            let pattern = tokens[(n - ngram)..<n]
            let searchLimit = n - ngram
            if searchLimit < ngram { continue }

            var foundFollowIndex: Int? = nil
            let searchStart = max(0, searchLimit - maxLookbackWindow)
            // Search backwards so the freshest context takes precedence
            var i = searchLimit - ngram
            while i >= searchStart {
                if tokens[i..<(i + ngram)].elementsEqual(pattern) {
                    foundFollowIndex = i + ngram
                    break
                }
                i -= 1
            }

            if let followIdx = foundFollowIndex, followIdx < n {
                let count = min(maxDraftTokens, n - followIdx)
                let candidates = Array(tokens[followIdx..<(followIdx + count)])
                if !candidates.isEmpty {
                    return candidates
                }
            }
        }
        return []
    }
}
