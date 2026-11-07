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

    func testShortcutsRegenerateRoutesToShortcutsGeneration() async throws {
        let settings = AppSettings(defaults: defaults)
        let service = ShortcutsService(name: "豆包", shortcutName: "问豆包", isEnabled: true)
        settings.upsertShortcutsService(service)
        settings.setShortcutsServiceEnabled(id: service.id, enabled: true)

        let store = ConversationStore(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        let chat = ChatStore(engine: MockEngine(), store: store, settings: settings)

        chat.newConversation()
        chat.draft = "你好"
        chat.send()

        guard let convo = chat.activeConversation, convo.messages.count >= 2 else {
            XCTFail("Expected user and assistant messages")
            return
        }
        let assistantID = convo.messages[1].id
        chat.regenerate(assistantMessageID: assistantID)

        XCTAssertTrue(chat.isShortcutsActive)
        XCTAssertEqual(chat.streaming?.warmingNote, "正在调用快捷指令...")
    }

    func testShortcutsMidConversationConfigChangeTriggersFullContext() async throws {
        let settings = AppSettings(defaults: defaults)
        let service = ShortcutsService(name: "豆包", shortcutName: "问豆包", isEnabled: true)
        settings.upsertShortcutsService(service)
        settings.setShortcutsServiceEnabled(id: service.id, enabled: true)

        let store = ConversationStore(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        let chat = ChatStore(engine: MockEngine(), store: store, settings: settings)

        chat.newConversation()
        chat.draft = "第一句话"
        chat.send()

        guard let convo = chat.activeConversation, convo.messages.count >= 2 else {
            XCTFail("Expected messages")
            return
        }

        chat.draft = "第二句话"
        chat.send()

        settings.toolsEnabled = true
        chat.draft = "第三句话使用工具"
        chat.send()

        XCTAssertTrue(chat.isShortcutsActive)
    }

    func testShortcutsTaskDispatchedCallbackInvoked() async throws {
        let settings = AppSettings(defaults: defaults)
        let service = ShortcutsService(name: "豆包", shortcutName: "问豆包", isEnabled: true)
        settings.upsertShortcutsService(service)
        settings.setShortcutsServiceEnabled(id: service.id, enabled: true)

        let store = ConversationStore(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        let fakeExecutor = TestDispatchExecutor()
        let chat = ChatStore(engine: MockEngine(), store: store, settings: settings, shortcutExecutor: fakeExecutor)

        var dispatchedCalled = false
        chat.onShortcutsTaskDispatched = {
            dispatchedCalled = true
        }

        chat.newConversation()
        chat.draft = "你好"
        chat.send()

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(dispatchedCalled)
    }
}

private final class TestDispatchExecutor: ShortcutAutomationExecuting, @unchecked Sendable {
    func executeTask(
        action: String,
        shortcut: String?,
        params: String?,
        taskId: String?,
        timeoutSeconds: Int,
        onTaskDispatched: (@Sendable () -> Void)?
    ) async throws -> String {
        onTaskDispatched?()
        return #"{"success":true,"status":"completed","result":"ok"}"#
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
