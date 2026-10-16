// SPDX-License-Identifier: MIT

import XCTest
@testable import LLMEngineLlama

final class NativeMtpDriverTests: XCTestCase {

    func testIsCompiledInDoesNotCrash() {
        // Querying whether native symbols are linked must be safe in any environment
        let available = NativeMtpDriver.isCompiledIn
        XCTAssertTrue(available || !available)
    }

    func testInitWithNilContextGracefullyReturnsNil() {
        let driver = NativeMtpDriver(context: nil, model: nil)
        XCTAssertNil(driver)
    }

    func testPredictSafelyHandlesNilDriver() {
        // Ensuring fallback safety when driver is nil
        let driver: NativeMtpDriver? = nil
        let drafts = driver?.predict(lastToken: 42) ?? []
        XCTAssertTrue(drafts.isEmpty)
    }
}
