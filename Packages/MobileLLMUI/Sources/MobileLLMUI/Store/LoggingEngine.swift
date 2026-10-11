// SPDX-License-Identifier: MIT

import Foundation
import LLMCore

/// A decorator over an `LLMEngine` that captures requests, responses, and metrics
/// into `LocalModelLogStore` when enabled in settings.
public final class LoggingEngine: LLMEngine, @unchecked Sendable {
    private let inner: any LLMEngine
    private let config: LoggingConfiguration
    private let onLogEntry: @Sendable (LocalModelLogEntry) -> Void
    private let lock = NSLock()
    private var loadedModelID: String?

    public init(
        inner: any LLMEngine,
        config: LoggingConfiguration,
        onLogEntry: @escaping @Sendable (LocalModelLogEntry) -> Void
    ) {
        self.inner = inner
        self.config = config
        self.onLogEntry = onLogEntry
    }

    private func setLoadedModel(_ id: String?) {
        lock.lock()
        loadedModelID = id
        lock.unlock()
    }

    private func getLoadedModel() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return loadedModelID
    }

    public func load(
        model: LLMModel,
        variant: LLMVariant,
        weightsDir: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await inner.load(model: model, variant: variant, weightsDir: weightsDir, progress: progress)
        setLoadedModel("\(model.id) · \(variant.id)")
    }

    public func unload() async {
        await inner.unload()
        setLoadedModel(nil)
    }

    public func generate(
        messages: [ChatTurn],
        params: Sampling
    ) -> AsyncThrowingStream<EngineDelta, Error> {
        guard config.isEnabled else {
            return inner.generate(messages: messages, params: params)
        }

        let activeID = getLoadedModel()
        let fallbackID = config.defaultModelID
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

                let sanitizedMessages = messages.map { turn in
                    if turn.images.isEmpty {
                        return turn
                    } else {
                        let tag = " [+\(turn.images.count) image(s)]"
                        return ChatTurn(role: turn.role, content: turn.content.isEmpty ? tag : "\(turn.content)\(tag)", images: [])
                    }
                }

                let entry = LocalModelLogEntry(
                    id: logID,
                    timestamp: startTime,
                    modelID: resolvedModelID,
                    sampling: params,
                    messages: sanitizedMessages,
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
