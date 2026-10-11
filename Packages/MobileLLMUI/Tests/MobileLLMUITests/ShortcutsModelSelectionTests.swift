// SPDX-License-Identifier: MIT

import XCTest
import LLMCore
@testable import MobileLLMUI

@MainActor
final class ShortcutsModelSelectionTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ShortcutsModelSelectionTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testAppSettingsShortcutsDefaultsAndPersistence() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.shortcutsModelEnabled)
        XCTAssertEqual(settings.shortcutsModelName, "豆包")
        XCTAssertEqual(settings.shortcutsShortcutName, "发消息问豆包")
        XCTAssertFalse(settings.shortcutsModelActive)

        settings.shortcutsModelName = "Kimi"
        settings.shortcutsShortcutName = "问Kimi"
        settings.shortcutsModelActive = true

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.shortcutsModelName, "Kimi")
        XCTAssertEqual(reloaded.shortcutsShortcutName, "问Kimi")
        XCTAssertTrue(reloaded.shortcutsModelActive)
    }

    func testChatStoreRecognizesShortcutsModel() {
        let settings = AppSettings(defaults: defaults)
        settings.shortcutsModelActive = true
        settings.shortcutsModelName = "豆包"
        settings.shortcutsShortcutName = "发消息问豆包"

        let store = ConversationStore(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        let chat = ChatStore(engine: MockEngine(), store: store, settings: settings)

        XCTAssertTrue(chat.isShortcutsActive)
        XCTAssertTrue(chat.hasModel)
        XCTAssertEqual(chat.activeModelLabel, "豆包 (快捷指令)")
    }
}

private final class MockEngine: LLMEngine, @unchecked Sendable {
    func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
              progress: @escaping @Sendable (Double) -> Void) async throws {}
    func unload() async {}
    func generate(messages: [ChatTurn], params: Sampling) -> AsyncThrowingStream<EngineDelta, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.token("OK"))
            continuation.yield(.done(Stats(promptTokens: 1, genTokens: 1, promptTPS: 1, tokensPerSecond: 1, peakMemoryBytes: 0, stopReason: .eos)))
            continuation.finish()
        }
    }
}
