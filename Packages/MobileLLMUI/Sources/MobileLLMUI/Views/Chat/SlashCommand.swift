// SPDX-License-Identifier: MIT

import Foundation

/// Action executed when the user picks a `/` item from the composer palette.
public enum SlashCommandAction: Equatable, Sendable {
    case clear
    case compact
    case newConversation
    case toggleThinking
    case selectSkill(UUID)
}

/// One built-in command or configured `Skill` surfaced in the composer's `/` palette.
public struct SlashCommandItem: Identifiable, Equatable, Sendable {
    public let id: String
    /// Command keyword without the leading `/` (e.g. `"clear"` or skill name).
    public let command: String
    public let subtitle: String
    public let systemImage: String
    public let emoji: String?
    public let isSkill: Bool
    public let action: SlashCommandAction

    public init(
        id: String,
        command: String,
        subtitle: String,
        systemImage: String,
        emoji: String? = nil,
        isSkill: Bool = false,
        action: SlashCommandAction
    ) {
        self.id = id
        self.command = command
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.emoji = emoji
        self.isSkill = isSkill
        self.action = action
    }

    /// Extracts the `/` prefix query when the draft starts with `/` on a single token (no spaces or
    /// newlines yet). Returns `nil` when the palette should stay hidden.
    public static func query(from draft: String) -> String? {
        guard draft.hasPrefix("/"), !draft.contains("\n") else { return nil }
        let body = String(draft.dropFirst())
        guard !body.contains(" ") else { return nil }
        return body
    }

    public static func items(
        for query: String,
        thinkingCapable: Bool,
        thinkingEnabled: Bool,
        skills: [Skill]
    ) -> [SlashCommandItem] {
        var all: [SlashCommandItem] = [
            SlashCommandItem(
                id: "builtin.clear",
                command: "clear",
                subtitle: "Clear messages and context in this conversation",
                systemImage: "trash",
                action: .clear
            ),
            SlashCommandItem(
                id: "builtin.compact",
                command: "compact",
                subtitle: "Summarize history into compact context",
                systemImage: "arrow.down.right.and.arrow.up.left",
                action: .compact
            ),
            SlashCommandItem(
                id: "builtin.new",
                command: "new",
                subtitle: "Start a new conversation",
                systemImage: "square.and.pencil",
                action: .newConversation
            ),
        ]
        if thinkingCapable {
            all.append(SlashCommandItem(
                id: "builtin.think",
                command: "think",
                subtitle: thinkingEnabled ? "Turn off thinking mode" : "Turn on thinking mode",
                systemImage: "brain",
                action: .toggleThinking
            ))
        }
        for skill in skills {
            let trimmedName = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }
            let trimmedEmoji = skill.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            all.append(SlashCommandItem(
                id: "skill.\(skill.id.uuidString)",
                command: trimmedName,
                subtitle: skill.summary.isEmpty ? "Activate skill" : skill.summary,
                systemImage: "sparkles",
                emoji: trimmedEmoji.isEmpty ? nil : trimmedEmoji,
                isSkill: true,
                action: .selectSkill(skill.id)
            ))
        }

        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.command.lowercased().contains(needle)
                || $0.subtitle.lowercased().contains(needle)
        }
    }
}
