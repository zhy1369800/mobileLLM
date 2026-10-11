// SPDX-License-Identifier: MIT

import Foundation
import Observation
import LLMCore

/// A recorded local model request and response log entry.
public struct LocalModelLogEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let modelID: String
    public let sampling: Sampling
    public let messages: [ChatTurn]
    public var reasoning: String?
    public var response: String
    public var stats: Stats?
    public var error: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        modelID: String,
        sampling: Sampling,
        messages: [ChatTurn],
        reasoning: String? = nil,
        response: String = "",
        stats: Stats? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.modelID = modelID
        self.sampling = sampling
        self.messages = messages
        self.reasoning = reasoning
        self.response = response
        self.stats = stats
        self.error = error
    }
}

/// Stores and manages local model request/response logs in the app sandbox.
@MainActor
@Observable
public final class LocalModelLogStore {
    /// Maximum number of log entries to retain before evicting the oldest.
    public static let maxEntriesLimit = 100

    public private(set) var entries: [LocalModelLogEntry] = []
    public let directory: URL

    public init(directory: URL? = nil, autoReload: Bool = false) {
        if let directory {
            self.directory = directory
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = docs.appendingPathComponent("local_model_logs", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        if autoReload {
            reload()
        }
    }

    /// Asynchronously reloads all log entries from the directory in the background,
    /// sorting newest first and trimming to `maxEntriesLimit`.
    public func reloadAsync() async {
        let dir = directory
        let limit = Self.maxEntriesLimit
        let loaded = await Task.detached(priority: .utility) { () -> [LocalModelLogEntry] in
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { return [] }

            var entries: [LocalModelLogEntry] = []
            let jsonFiles = files.filter { $0.pathExtension == "json" }
            for file in jsonFiles {
                if let data = try? Data(contentsOf: file),
                   let entry = try? JSONDecoder().decode(LocalModelLogEntry.self, from: data) {
                    entries.append(entry)
                }
            }
            let sorted = entries.sorted(by: { $0.timestamp > $1.timestamp })
            if sorted.count > limit {
                // Asynchronously evict overflow files from disk
                let evicted = sorted.suffix(from: limit)
                for item in evicted {
                    let file = dir.appendingPathComponent("\(item.id.uuidString).json")
                    try? FileManager.default.removeItem(at: file)
                }
                return Array(sorted.prefix(limit))
            }
            return sorted
        }.value

        self.entries = loaded
    }

    /// Synchronously reloads log entries (used primarily for deterministic unit testing).
    public func reload() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            entries = []
            return
        }
        var loaded: [LocalModelLogEntry] = []
        let jsonFiles = files.filter { $0.pathExtension == "json" }
        for file in jsonFiles {
            if let data = try? Data(contentsOf: file),
               let entry = try? JSONDecoder().decode(LocalModelLogEntry.self, from: data) {
                loaded.append(entry)
            }
        }
        let sorted = loaded.sorted(by: { $0.timestamp > $1.timestamp })
        if sorted.count > Self.maxEntriesLimit {
            self.entries = Array(sorted.prefix(Self.maxEntriesLimit))
        } else {
            self.entries = sorted
        }
    }

    /// Appends a new entry in-memory, evicts oldest if above limit, and asynchronously saves to disk.
    public func append(_ entry: LocalModelLogEntry) {
        entries.insert(entry, at: 0)

        // Evict overflow entries
        var evictedID: UUID?
        if entries.count > Self.maxEntriesLimit {
            let last = entries.removeLast()
            evictedID = last.id
        }

        let file = directory.appendingPathComponent("\(entry.id.uuidString).json")
        let evictedFile = evictedID.map { directory.appendingPathComponent("\($0.uuidString).json") }

        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(entry) {
                try? data.write(to: file, options: .atomic)
            }
            if let evictedFile {
                try? FileManager.default.removeItem(at: evictedFile)
            }
        }
    }

    /// Deletes a single entry by ID.
    public func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        let file = directory.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: file)
    }

    /// Clears all log entries in-memory and on disk.
    public func clearAll() {
        entries.removeAll()
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
