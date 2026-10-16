// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMCore

final class SpeculativeModeTests: XCTestCase {

    func testDefaultSpeculativeModeIsOff() {
        let s = Sampling()
        XCTAssertEqual(s.speculativeMode, .off)
    }

    func testCustomSpeculativeModePropagates() {
        let s1 = Sampling(speculativeMode: .promptLookup)
        XCTAssertEqual(s1.speculativeMode, .promptLookup)

        let s2 = Sampling(speculativeMode: .mtp)
        XCTAssertEqual(s2.speculativeMode, .mtp)
    }

    func testCodableBackwardCompatibilityLegacyJSONMissingSpeculativeModeDefaultsToOff() throws {
        let legacyJSON = """
        {
            "temperature": 0.7,
            "topP": 0.95,
            "topK": 40,
            "repetitionPenalty": 1.05,
            "maxTokens": 1024,
            "thinking": true,
            "contextTokenCap": 8192,
            "kvBits": 8,
            "quantizedKVStart": 256
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Sampling.self, from: legacyJSON)
        XCTAssertEqual(decoded.speculativeMode, .off)
        XCTAssertEqual(decoded.temperature, 0.7, accuracy: 0.001)
    }

    func testCodableRoundtripWithExplicitSpeculativeMode() throws {
        let original = Sampling(speculativeMode: .mtp)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Sampling.self, from: data)
        XCTAssertEqual(decoded.speculativeMode, .mtp)
        XCTAssertEqual(decoded, original)
    }

    func testSpeculativeModeDisplayNamesAndCases() {
        XCTAssertEqual(SpeculativeMode.off.displayName, "Off (Standard)")
        XCTAssertEqual(SpeculativeMode.promptLookup.displayName, "Prompt Lookup")
        XCTAssertEqual(SpeculativeMode.mtp.displayName, "Native MTP / Auto")
        XCTAssertEqual(SpeculativeMode.allCases.count, 3)
    }
}
