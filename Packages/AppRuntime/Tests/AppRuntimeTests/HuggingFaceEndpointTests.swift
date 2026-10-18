// SPDX-License-Identifier: MIT

import XCTest
@testable import AppRuntime

final class HuggingFaceEndpointTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: HuggingFaceEndpoint.userDefaultsKey)
        super.tearDown()
    }

    func testDefaultHostIsMirror() {
        UserDefaults.standard.removeObject(forKey: HuggingFaceEndpoint.userDefaultsKey)
        XCTAssertEqual(HuggingFaceEndpoint.currentHost, HuggingFaceEndpoint.mirrorHost)
    }

    func testExplicitOfficialHostSelection() {
        UserDefaults.standard.set(false, forKey: HuggingFaceEndpoint.userDefaultsKey)
        XCTAssertEqual(HuggingFaceEndpoint.currentHost, HuggingFaceEndpoint.officialHost)
    }

    func testExplicitMirrorHostSelection() {
        UserDefaults.standard.set(true, forKey: HuggingFaceEndpoint.userDefaultsKey)
        XCTAssertEqual(HuggingFaceEndpoint.currentHost, HuggingFaceEndpoint.mirrorHost)
    }
}
