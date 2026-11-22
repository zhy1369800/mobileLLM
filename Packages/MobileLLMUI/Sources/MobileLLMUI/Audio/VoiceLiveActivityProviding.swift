// SPDX-License-Identifier: MIT

import Foundation

/// Phase displayed on the iOS Live Activity / Dynamic Island during an active voice conversation.
public enum VoiceLiveActivityPhase: String, Equatable, Sendable {
    case listening
    case thinking
    case speaking
}

/// Framework-agnostic snapshot pushed from `VoiceChatSession` to the iOS Live Activity bridge.
public struct VoiceLiveActivitySnapshot: Equatable, Sendable {
    public let phase: VoiceLiveActivityPhase
    public let subtitle: String
    public let toolName: String?
    public let toolRunning: Bool
    public let modelName: String

    public init(
        phase: VoiceLiveActivityPhase,
        subtitle: String,
        toolName: String? = nil,
        toolRunning: Bool = false,
        modelName: String
    ) {
        self.phase = phase
        self.subtitle = Self.sanitizedSubtitle(subtitle)
        self.toolName = toolName
        self.toolRunning = toolRunning
        self.modelName = modelName
    }

    /// Normalizes newlines/whitespace and retains the latest trailing characters within `maxLength`
    /// so `ActivityKit` state payloads stay compact and well under the 4 KB system limit.
    /// Slices a bounded tail window first so long streaming replies stay O(1) instead of O(N).
    public static func sanitizedSubtitle(_ raw: String, maxLength: Int = 120) -> String {
        guard maxLength > 0 else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let windowLimit = max(maxLength * 4, 256)
        let windowStart = trimmed.index(
            trimmed.endIndex,
            offsetBy: -windowLimit,
            limitedBy: trimmed.startIndex
        )
        let wasWindowSliced = (windowStart != nil && windowStart != trimmed.startIndex)
        let windowText = windowStart.map { String(trimmed[$0...]) } ?? trimmed

        let collapsed = windowText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if collapsed.count <= maxLength && !wasWindowSliced {
            return collapsed
        }
        guard maxLength > 1 else { return String(collapsed.suffix(maxLength)) }
        return "…" + String(collapsed.suffix(maxLength - 1))
    }
}

/// Abstracts iOS `ActivityKit` lifecycle updates away from `MobileLLMUI` so macOS and SwiftPM tests
/// stay free of platform-only Live Activity imports.
@MainActor
public protocol VoiceLiveActivityProviding: AnyObject {
    func start(with snapshot: VoiceLiveActivitySnapshot)
    func update(with snapshot: VoiceLiveActivitySnapshot)
    func end()
}
