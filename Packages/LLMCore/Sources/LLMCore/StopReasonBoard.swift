// SPDX-License-Identifier: MIT

import Foundation

/// Side channel that carries the local engine's real `StopReason` past the agent-runtime usage
/// contract (which has no stop-reason field) so the chat UI can tell a token-limit truncation from
/// a natural EOS. Keyed by `runID` so concurrent background workflows and foreground chats never
/// cross-contaminate; each slot is consumed once on commit and bounded against unbounded growth.
public final class StopReasonBoard: @unchecked Sendable {
    public static let shared = StopReasonBoard()

    private let lock = NSLock()
    private var values: [String: StopReason] = [:]
    private var insertionOrder: [String] = []
    private let maxEntries: Int

    public init(maxEntries: Int = 64) {
        self.maxEntries = max(1, maxEntries)
    }

    public func record(_ reason: StopReason, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if values[key] == nil {
            insertionOrder.append(key)
            if insertionOrder.count > maxEntries {
                let oldest = insertionOrder.removeFirst()
                values.removeValue(forKey: oldest)
            }
        }
        values[key] = reason
    }

    /// Returns the last recorded reason for `key` and removes it.
    public func take(for key: String) -> StopReason? {
        lock.lock(); defer { lock.unlock() }
        guard let current = values.removeValue(forKey: key) else { return nil }
        insertionOrder.removeAll { $0 == key }
        return current
    }

    public func clear(for key: String) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
        insertionOrder.removeAll { $0 == key }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        values.removeAll()
        insertionOrder.removeAll()
    }
}
