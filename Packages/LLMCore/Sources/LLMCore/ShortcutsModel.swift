// SPDX-License-Identifier: MIT

import Foundation

/// Represents a configured iOS Shortcuts automation service (e.g. "豆包", "Kimi").
public struct ShortcutsService: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var shortcutName: String
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString, name: String, shortcutName: String, isEnabled: Bool = false) {
        self.id = id
        self.name = name
        self.shortcutName = shortcutName
        self.isEnabled = isEnabled
    }

    public func withEnabled(_ enabled: Bool) -> ShortcutsService {
        var copy = self
        copy.isEnabled = enabled
        return copy
    }
}

/// Helper for constructing parameters and parsing tool calls for external shortcuts.
public enum ShortcutsModelPromptBuilder {

    /// Formats system prompt, tools, history, and current user prompt into a cohesive `msg` string.
    public static func buildMessage(
        systemPrompt: String = "",
        toolDescriptions: String = "",
        history: [(role: String, content: String)] = [],
        currentPrompt: String
    ) -> String {
        var sections: [String] = []

        var combinedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTools = toolDescriptions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTools.isEmpty {
            let toolInstructions = """
            【可用工具说明】
            你可以调用以下工具来获取信息或完成操作：
            \(trimmedTools)

            【工具调用格式规范】
            如果你需要调用工具，请务必严格输出以下格式的 Markdown 代码块，不要附带多余文字：
            ```tool_call
            {"tool": "工具名", "arguments": {"参数名": "参数值"}}
            ```
            当你获得【工具执行结果】后，请结合结果以自然语言给出最终回复，不要再次输出相同的工具调用。
            """
            if combinedSystem.isEmpty {
                combinedSystem = toolInstructions
            } else {
                combinedSystem += "\n\n" + toolInstructions
            }
        }

        if !combinedSystem.isEmpty {
            sections.append("【系统提示】\n\(combinedSystem)")
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
    public static func buildParams(msg: String, fileName: String? = nil) -> [String: Any] {
        var params: [String: Any] = ["msg": msg]
        if let fileName = fileName, !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["fileName"] = fileName
        }
        return params
    }

    public struct ParsedToolCall: Equatable {
        public let tool: String
        public let arguments: [String: Any]

        public init(tool: String, arguments: [String: Any]) {
            self.tool = tool
            self.arguments = arguments
        }

        public static func == (lhs: ParsedToolCall, rhs: ParsedToolCall) -> Bool {
            lhs.tool == rhs.tool && NSDictionary(dictionary: lhs.arguments).isEqual(to: rhs.arguments)
        }
    }

    /// Parses a tool call from the model's response text.
    /// Supports ```tool_call { ... } ``` as well as bare JSON with "tool" and "arguments" / "args".
    public static func parseToolCall(from text: String) -> ParsedToolCall? {
        let pattern = #"(?s)```(?:tool_call|json)?\s*(\{[\s\S]*?\})\s*```"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                if match.numberOfRanges > 1 {
                    let jsonString = nsText.substring(with: match.range(at: 1))
                    if let parsed = parseToolJSON(jsonString) {
                        return parsed
                    }
                }
            }
        }

        // Fallback: try parsing the entire text as JSON
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            if let parsed = parseToolJSON(trimmed) {
                return parsed
            }
        }

        return nil
    }

    private static func parseToolJSON(_ jsonString: String) -> ParsedToolCall? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let toolName = (json["tool"] as? String) ?? (json["name"] as? String),
              !toolName.isEmpty else {
            return nil
        }
        let args = (json["arguments"] as? [String: Any]) ?? (json["args"] as? [String: Any]) ?? [:]
        return ParsedToolCall(tool: toolName, arguments: args)
    }
}
