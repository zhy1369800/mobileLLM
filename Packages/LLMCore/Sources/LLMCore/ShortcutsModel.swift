// SPDX-License-Identifier: MIT

import Foundation

/// Helper for constructing parameters sent to external shortcuts (e.g. Doubao/Kimi).
public enum ShortcutsModelPromptBuilder {

    /// Formats system prompt, history, and current user prompt into a cohesive `msg` string.
    public static func buildMessage(
        systemPrompt: String = "",
        history: [(role: String, content: String)] = [],
        currentPrompt: String
    ) -> String {
        var sections: [String] = []

        let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            sections.append("【系统提示】\n\(trimmedSystem)")
        }

        let nonTrivialHistory = history.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !nonTrivialHistory.isEmpty {
            var historyText = "【历史对话】"
            for item in nonTrivialHistory {
                let roleName = item.role == "user" ? "用户" : "助手"
                historyText += "\n\(roleName): \(item.content)"
            }
            sections.append(historyText)
        }

        let trimmedCurrent = currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if sections.isEmpty {
            return trimmedCurrent
        } else {
            sections.append("【当前提问】\n\(trimmedCurrent)")
            return sections.joined(separator: "\n\n")
        }
    }

    /// Constructs the parameters dictionary matching the shortcut automation schema.
    /// - Parameters:
    ///   - msg: The combined message string to send.
    ///   - fileName: Optional filename for images or attachments.
    public static func buildParams(msg: String, fileName: String? = nil) -> [String: Any] {
        var params: [String: Any] = ["msg": msg]
        if let fileName = fileName, !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["fileName"] = fileName
        }
        return params
    }
}
