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

    func testSpeculativeStatsCalculations() {
        let stats = SpeculativeStats(driver: "Native MTP", draftedTokens: 50, acceptedTokens: 35)
        XCTAssertEqual(stats.driver, "Native MTP")
        XCTAssertEqual(stats.draftedTokens, 50)
        XCTAssertEqual(stats.acceptedTokens, 35)
        XCTAssertEqual(stats.acceptanceRate, 0.7, accuracy: 0.001)

        let zeroStats = SpeculativeStats(driver: "Prompt Lookup", draftedTokens: 0, acceptedTokens: 0)
        XCTAssertEqual(zeroStats.acceptanceRate, 0.0)
    }

    func testStatsLegacyJSONCompatibilityWithoutSpeculativeStats() throws {
        let legacyJSON = """
        {
            "promptTokens": 10,
            "genTokens": 20,
            "promptTPS": 30.5,
            "tokensPerSecond": 15.2,
            "peakMemoryBytes": 1048576,
            "stopReason": "eos"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Stats.self, from: legacyJSON)
        XCTAssertEqual(decoded.promptTokens, 10)
        XCTAssertEqual(decoded.genTokens, 20)
        XCTAssertEqual(decoded.stopReason, .eos)
        XCTAssertNil(decoded.speculativeStats)
    }

    func testStatsRoundtripWithSpeculativeStats() throws {
        let spec = SpeculativeStats(driver: "Native MTP", draftedTokens: 40, acceptedTokens: 25)
        let original = Stats(
            promptTokens: 12,
            genTokens: 30,
            promptTPS: 40.0,
            tokensPerSecond: 18.5,
            peakMemoryBytes: 2097152,
            stopReason: .eos,
            speculativeStats: spec
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Stats.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.speculativeStats?.driver, "Native MTP")
        XCTAssertEqual(decoded.speculativeStats?.draftedTokens, 40)
        XCTAssertEqual(decoded.speculativeStats?.acceptedTokens, 25)
        XCTAssertEqual(decoded.speculativeStats?.acceptanceRate ?? 0, 0.625, accuracy: 0.001)
    }

    func testAppConfigurationKeysSettingsStorageKey() {
        XCTAssertEqual(AppConfigurationKeys.settingsStorageKey, "mobileLLM.settings.v1")
    }
}

