// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

final class StopReasonBoardTests: XCTestCase {

    func testRecordThenTakeReturnsReasonAndClearsSlot() {
        let board = StopReasonBoard()
        board.record(.maxTokens, for: "run-1")

        XCTAssertEqual(board.take(for: "run-1"), .maxTokens)
        XCTAssertNil(board.take(for: "run-1"), "take must consume and clear the slot")
    }

    func testTakeEmptySlotReturnsNil() {
        let board = StopReasonBoard()
        XCTAssertNil(board.take(for: "missing-run"))
    }

    func testClearRemovesRecordedReason() {
        let board = StopReasonBoard()
        board.record(.maxTokens, for: "run-1")
        board.record(.eos, for: "run-2")

        board.clear(for: "run-1")
        XCTAssertNil(board.take(for: "run-1"))
        XCTAssertEqual(board.take(for: "run-2"), .eos)

        board.record(.maxTokens, for: "run-3")
        board.clear()
        XCTAssertNil(board.take(for: "run-3"))
    }

    func testKeysAreIsolatedAcrossConcurrentRuns() {
        let board = StopReasonBoard()
        board.record(.maxTokens, for: "workflow-run")
        board.record(.eos, for: "chat-run")

        XCTAssertEqual(board.take(for: "chat-run"), .eos)
        XCTAssertEqual(board.take(for: "workflow-run"), .maxTokens)
    }

    func testBoundedCapacityEvictsOldestKey() {
        let board = StopReasonBoard(maxEntries: 2)
        board.record(.maxTokens, for: "run-1")
        board.record(.eos, for: "run-2")
        board.record(.cancelled, for: "run-3")

        XCTAssertNil(board.take(for: "run-1"), "oldest key should be evicted when capacity is exceeded")
        XCTAssertEqual(board.take(for: "run-2"), .eos)
        XCTAssertEqual(board.take(for: "run-3"), .cancelled)
    }
}
