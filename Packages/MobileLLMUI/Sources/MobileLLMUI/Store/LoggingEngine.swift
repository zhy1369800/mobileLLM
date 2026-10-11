// SPDX-License-Identifier: MIT

import Foundation
import LLMCore

/// A decorator over an `LLMEngine` that captures requests, responses, and metrics
/// into `LocalModelLogStore` when enabled in settings.
public final class LoggingEngine: LLMEngine, @unchecked Sendable {
    private let inner: any LLMEngine
    private let isLoggingEnabled: @Sendable () -> Bool
    private let getActiveModelID: @Sendable () -> String
    private let onLogEntry: @Sendable (LocalModelLogEntry) -> Void
    private let lock = NSLock()
    private var loadedModelID: String?

    public init(
        inner: any LLMEngine,
        isLoggingEnabled: @escaping @Sendable () -> Bool,
        getActiveModelID: @escaping @Sendable () -> String,
        onLogEntry: @escaping @Sendable (LocalModelLogEntry) -> Void
    ) {
        self.inner = inner
        self.isLoggingEnabled = isLoggingEnabled
        self.getActiveModelID = getActiveModelID
        self.onLogEntry = onLogEntry
    }

    public func load(
        model: LLMModel,
        variant: LLMVariant,
        weightsDir: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await inner.load(model: model, variant: variant, weightsDir: weightsDir, progress: progress)
        lock.lock()
        loadedModelID = "\(model.id) · \(variant.id)"
        lock.unlock()
    }

    public func unload() async {
        await inner.unload()
        lock.lock()
        loadedModelID = nil
        lock.unlock()
    }

    public func generate(
        messages: [ChatTurn],
        params: Sampling
    ) -> AsyncThrowingStream<EngineDelta, Error> {
        guard isLoggingEnabled() else {
            return inner.generate(messages: messages, params: params)
        }

        lock.lock()
        let activeID = loadedModelID
        lock.unlock()
        let fallbackID = getActiveModelID()
        let resolvedModelID = activeID ?? (fallbackID.isEmpty ? "local-model" : fallbackID)
        let logID = UUID()
        let startTime = Date()

        return AsyncThrowingStream { continuation in
            let task = Task {
                var reasoningAccumulator = ""
                var answerAccumulator = ""
                var statsResult: Stats?
                var streamError: Error?

                do {
                    for try await delta in inner.generate(messages: messages, params: params) {
                        switch delta {
                        case .reasoning(let text):
                            reasoningAccumulator += text
                        case .answer(let text):
                            answerAccumulator += text
                        case .done(let stats):
                            statsResult = stats
                        }
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    streamError = error
                    continuation.finish(throwing: error)
                }

                let entry = LocalModelLogEntry(
                    id: logID,
                    timestamp: startTime,
                    modelID: resolvedModelID,
                    sampling: params,
                    messages: messages,
                    reasoning: reasoningAccumulator.isEmpty ? nil : reasoningAccumulator,
                    response: answerAccumulator,
                    stats: statsResult,
                    error: streamError?.localizedDescription
                )
                onLogEntry(entry)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
