// SPDX-License-Identifier: MIT

import XCTest
@testable import MobileLLMUI
import LLMCore

@MainActor
final class LocalModelLogStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalModelLogStoreTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testLogStoreAppendDeleteAndClear() async throws {
        let store = LocalModelLogStore(directory: tempDir, autoReload: false)
        XCTAssertTrue(store.entries.isEmpty)

        let entry1 = LocalModelLogEntry(
            id: UUID(),
            timestamp: Date().addingTimeInterval(-10),
            modelID: "model-a",
            sampling: Sampling(),
            messages: [ChatTurn(role: .user, content: "Hello")],
            response: "Hi there",
            stats: Stats(promptTokens: 5, completionTokens: 2, tokPerSec: 10.0, totalTime: 0.2)
        )
        let entry2 = LocalModelLogEntry(
            id: UUID(),
            timestamp: Date(),
            modelID: "model-b",
            sampling: Sampling(),
            messages: [ChatTurn(role: .user, content: "Explain quantum computing")],
            reasoning: "Thinking process...",
            response: "Quantum computing is...",
            stats: Stats(promptTokens: 10, completionTokens: 20, tokPerSec: 15.0, totalTime: 1.3)
        )

        store.append(entry1)
        store.append(entry2)

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries.first?.id, entry2.id) // Newest first

        // Delete single
        store.delete(id: entry1.id)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.id, entry2.id)

        // Clear all
        store.clearAll()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testAsyncReloadLoadsFromDisk() async throws {
        let store = LocalModelLogStore(directory: tempDir, autoReload: false)
        let entry = LocalModelLogEntry(
            id: UUID(),
            timestamp: Date(),
            modelID: "test-model",
            sampling: Sampling(),
            messages: [ChatTurn(role: .user, content: "ping")],
            response: "pong"
        )
        store.append(entry)

        // Create a new store instance pointing to same directory without auto-reloading
        let secondStore = LocalModelLogStore(directory: tempDir, autoReload: false)
        XCTAssertTrue(secondStore.entries.isEmpty)

        // Wait brief moment for disk write to settle
        try await Task.sleep(nanoseconds: 50_000_000)

        await secondStore.reloadAsync()
        XCTAssertEqual(secondStore.entries.count, 1)
        XCTAssertEqual(secondStore.entries.first?.id, entry.id)
    }

    func testRollingEvictionLimitsMemoryEntries() {
        let store = LocalModelLogStore(directory: tempDir, autoReload: false)
        for i in 0..<(LocalModelLogStore.maxEntriesLimit + 10) {
            let entry = LocalModelLogEntry(
                id: UUID(),
                timestamp: Date().addingTimeInterval(Double(i)),
                modelID: "model-\(i)",
                sampling: Sampling(),
                messages: [ChatTurn(role: .user, content: "msg \(i)")],
                response: "resp \(i)"
            )
            store.append(entry)
        }

        XCTAssertEqual(store.entries.count, LocalModelLogStore.maxEntriesLimit)
    }

    func testLoggingEnginePassthroughWhenDisabled() async throws {
        var recorded: [LocalModelLogEntry] = []
        let mock = MockEngine(chunks: [.answer("Hello world")])
        let loggingEngine = LoggingEngine(
            inner: mock,
            isLoggingEnabled: { false },
            getActiveModelID: { "test-model" },
            onLogEntry: { recorded.append($0) }
        )

        var output = ""
        for try await delta in loggingEngine.generate(messages: [ChatTurn(role: .user, content: "hi")], params: Sampling()) {
            if case .answer(let text) = delta {
                output += text
            }
        }

        XCTAssertEqual(output, "Hello world")
        XCTAssertTrue(recorded.isEmpty)
    }

    func testLoggingEngineCapturesRequestAndResponseWithLoadedModel() async throws {
        var recorded: [LocalModelLogEntry] = []
        let mock = MockEngine(chunks: [
            .reasoning("Let me think..."),
            .answer("4"),
            .done(Stats(promptTokens: 5, completionTokens: 1, tokPerSec: 10.0, totalTime: 0.1))
        ])
        let loggingEngine = LoggingEngine(
            inner: mock,
            isLoggingEnabled: { true },
            getActiveModelID: { "fallback-default" },
            onLogEntry: { recorded.append($0) }
        )

        // Simulate model load
        let testModel = LLMCatalog.qwen35_4b
        let testVariant = testModel.defaultVariantValue
        try await loggingEngine.load(model: testModel, variant: testVariant, weightsDir: tempDir, progress: { _ in })

        var output = ""
        for try await delta in loggingEngine.generate(messages: [ChatTurn(role: .user, content: "2+2=")], params: Sampling()) {
            if case .answer(let text) = delta {
                output += text
            }
        }

        XCTAssertEqual(output, "4")

        // Wait brief moment for the completion handler task
        for _ in 0..<10 {
            if !recorded.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(recorded.count, 1)
        let entry = recorded[0]
        // Must use loaded model ID, not fallback
        XCTAssertTrue(entry.modelID.contains(testModel.id))
        XCTAssertEqual(entry.messages.first?.content, "2+2=")
        XCTAssertEqual(entry.reasoning, "Let me think...")
        XCTAssertEqual(entry.response, "4")
        XCTAssertEqual(entry.stats?.completionTokens, 1)
    }

    func testSettingsPersistence() {
        let defaults = UserDefaults(suiteName: "LocalModelLogStoreSettingsTests")!
        defaults.removePersistentDomain(forName: "LocalModelLogStoreSettingsTests")
        defer { defaults.removePersistentDomain(forName: "LocalModelLogStoreSettingsTests") }

        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.localModelLoggingEnabled)

        settings.localModelLoggingEnabled = true
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.localModelLoggingEnabled)
    }
}

private final class MockEngine: LLMEngine, @unchecked Sendable {
    let chunks: [EngineDelta]

    init(chunks: [EngineDelta]) {
        self.chunks = chunks
    }

    func load(model: LLMModel, variant: LLMVariant, weightsDir: URL, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func unload() async {}

    func generate(messages: [ChatTurn], params: Sampling) -> AsyncThrowingStream<EngineDelta, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}
