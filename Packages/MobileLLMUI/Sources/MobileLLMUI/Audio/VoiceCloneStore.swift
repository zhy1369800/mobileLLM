// SPDX-License-Identifier: MIT

import Foundation
import Observation

/// Persistent metadata for a user-created zero-shot voice cloning profile.
public struct ClonedVoiceProfile: Identifiable, Codable, Hashable, Sendable {
    public static let voiceIDPrefix = "clone:"

    public let id: String
    public var name: String
    public let audioFilename: String
    public var referenceTranscript: String
    public let durationSeconds: Double
    public let createdAt: Date

    public init(
        id: String = ClonedVoiceProfile.voiceIDPrefix + UUID().uuidString,
        name: String,
        audioFilename: String,
        referenceTranscript: String,
        durationSeconds: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.audioFilename = audioFilename
        self.referenceTranscript = referenceTranscript
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
    }

    public static func isClonedVoiceID(_ voiceID: String?) -> Bool {
        guard let voiceID else { return false }
        return voiceID.hasPrefix(voiceIDPrefix)
    }
}

public enum VoiceCloneStoreError: LocalizedError, Sendable {
    case emptyName
    case invalidDuration(Double)
    case profileNotFound

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Please enter a name for the cloned voice."
        case .invalidDuration(let seconds):
            return String(format: "Reference audio must be between 1.5s and 30s (got %.1fs).", seconds)
        case .profileNotFound:
            return "The selected cloned voice profile no longer exists."
        }
    }
}

/// Stores reference audio clips and transcripts for zero-shot CosyVoice3 voice cloning
/// inside the app's durable storage directory (`voice_clones/`).
@MainActor
@Observable
public final class VoiceCloneStore {
    public let directory: URL
    public private(set) var profiles: [ClonedVoiceProfile] = []

    @ObservationIgnored public var onProfileDeleted: ((_ profileID: String) -> Void)?

    private var manifestURL: URL {
        directory.appending(component: "profiles.json")
    }

    public init(directory: URL) {
        self.directory = directory
        load()
    }

    public func profile(id: String) -> ClonedVoiceProfile? {
        profiles.first { $0.id == id }
    }

    public func audioURL(for profile: ClonedVoiceProfile) -> URL {
        directory.appending(component: profile.audioFilename)
    }

    @discardableResult
    public func addProfile(
        name: String,
        sourceAudioURL: URL,
        referenceTranscript: String,
        durationSeconds: Double
    ) throws -> ClonedVoiceProfile {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw VoiceCloneStoreError.emptyName }
        guard durationSeconds >= 1.5, durationSeconds <= 30.5 else {
            throw VoiceCloneStoreError.invalidDuration(durationSeconds)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let ext = sourceAudioURL.pathExtension.isEmpty ? "wav" : sourceAudioURL.pathExtension.lowercased()
        let filename = "\(UUID().uuidString).\(ext)"
        let destination = directory.appending(component: filename)

        let scoped = sourceAudioURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceAudioURL.stopAccessingSecurityScopedResource() } }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: sourceAudioURL, to: destination)

        let profile = ClonedVoiceProfile(
            name: trimmedName,
            audioFilename: filename,
            referenceTranscript: referenceTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
            durationSeconds: durationSeconds
        )
        profiles.insert(profile, at: 0)
        try saveManifest()
        return profile
    }

    public func updateProfile(id: String, name: String, referenceTranscript: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw VoiceCloneStoreError.emptyName }
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else {
            throw VoiceCloneStoreError.profileNotFound
        }
        profiles[idx].name = trimmedName
        profiles[idx].referenceTranscript = referenceTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        try saveManifest()
    }

    public func delete(id: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        let removed = profiles.remove(at: idx)
        try? FileManager.default.removeItem(at: audioURL(for: removed))
        try? saveManifest()
        onProfileDeleted?(id)
    }

    public func eraseAllData() throws {
        profiles.removeAll()
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        try fm.removeItem(at: directory)
    }

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([ClonedVoiceProfile].self, from: data) else {
            profiles = []
            return
        }
        profiles = decoded.filter { fm.fileExists(atPath: audioURL(for: $0).path) }
    }

    private func saveManifest() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)
        try data.write(to: manifestURL, options: [.atomic])
    }
}
