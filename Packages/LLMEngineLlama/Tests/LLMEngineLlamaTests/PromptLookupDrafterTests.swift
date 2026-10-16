// SPDX-License-Identifier: MIT

import XCTest
import llama
@testable import LLMEngineLlama

final class PromptLookupDrafterTests: XCTestCase {

    func testProposesFollowUpTokensOnMatch() {
        let drafter = PromptLookupDrafter(maxDraftTokens: 3, minNgram: 2, maxNgram: 3)
        // Tokens: [1, 2, 3, 4, 5, 1, 2, 3] -> matches [1, 2, 3], follow-up is [4, 5]
        let tokens: [llama_token] = [1, 2, 3, 4, 5, 1, 2, 3]
        let candidates = drafter.propose(from: tokens)
        XCTAssertEqual(candidates, [4, 5])
    }

    func testPrefersLongerNgramMatch() {
        let drafter = PromptLookupDrafter(maxDraftTokens: 2, minNgram: 2, maxNgram: 3)
        // [10, 20, 99, 10, 20, 30, 40, 10, 20, 30]
        // 2-gram [20, 30] would point to [40], but 3-gram [10, 20, 30] also points to [40].
        // If 2-gram [10, 20] had pointed to [99], the 3-gram should take precedence.
        let tokens: [llama_token] = [10, 20, 99, 10, 20, 30, 40, 10, 20, 30]
        let candidates = drafter.propose(from: tokens)
        XCTAssertEqual(candidates, [40])
    }

    func testPrefersRecentOccurrenceOnMultipleMatches() {
        let drafter = PromptLookupDrafter(maxDraftTokens: 2, minNgram: 2, maxNgram: 2)
        // [1, 2, 88, 1, 2, 99, 1, 2] -> two matches for [1, 2]; recent one is followed by [99]
        let tokens: [llama_token] = [1, 2, 88, 1, 2, 99, 1, 2]
        let candidates = drafter.propose(from: tokens)
        XCTAssertEqual(candidates, [99, 1])
    }

    func testReturnsEmptyWhenNoMatchFound() {
        let drafter = PromptLookupDrafter(maxDraftTokens: 3, minNgram: 2, maxNgram: 3)
        let tokens: [llama_token] = [1, 2, 3, 4, 5, 6, 7]
        let candidates = drafter.propose(from: tokens)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testReturnsEmptyWhenTokensTooShort() {
        let drafter = PromptLookupDrafter(maxDraftTokens: 3, minNgram: 2, maxNgram: 3)
        let tokens: [llama_token] = [1, 2]
        let candidates = drafter.propose(from: tokens)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testCapsCandidatesAtMaxDraftTokens() {
        let drafter = PromptLookupDrafter(maxDraftTokens: 2, minNgram: 2, maxNgram: 2)
        let tokens: [llama_token] = [1, 2, 10, 20, 30, 40, 1, 2]
        let candidates = drafter.propose(from: tokens)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates, [10, 20])
    }
}
