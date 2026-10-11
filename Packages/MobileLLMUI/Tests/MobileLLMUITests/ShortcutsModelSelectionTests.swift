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

    func testAppSettingsShortcutsMultiServicesPersistence() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.shortcutsServices.isEmpty)
        XCTAssertFalse(settings.shortcutsModelActive)

        // 添加一个新服务并激活
        let kimi = ShortcutsService(name: "Kimi", shortcutName: "问Kimi", isEnabled: true)
        settings.upsertShortcutsService(kimi)
        settings.setShortcutsServiceEnabled(id: kimi.id, enabled: true)

        XCTAssertTrue(settings.shortcutsModelActive)
        XCTAssertEqual(settings.shortcutsModelName, "Kimi")
        XCTAssertEqual(settings.shortcutsShortcutName, "问Kimi")

        // 重新从 defaults 加载
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.shortcutsModelActive)
        XCTAssertEqual(reloaded.shortcutsModelName, "Kimi")
        XCTAssertEqual(reloaded.shortcutsShortcutName, "问Kimi")
    }

    func testChatStoreRecognizesActiveShortcutsService() {
        let settings = AppSettings(defaults: defaults)
        let service = ShortcutsService(name: "自定义AI", shortcutName: "问AI", isEnabled: true)
        settings.upsertShortcutsService(service)
        settings.setShortcutsServiceEnabled(id: service.id, enabled: true)

        let store = ConversationStore(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        let chat = ChatStore(engine: MockEngine(), store: store, settings: settings)

        XCTAssertTrue(chat.isShortcutsActive)
        XCTAssertTrue(chat.hasModel)
        XCTAssertEqual(chat.activeModelLabel, "自定义AI (快捷指令)")
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
