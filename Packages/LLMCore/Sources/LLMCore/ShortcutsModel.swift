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

    /// Formats tool schemas into structured declarations with parameters and return value descriptions.
    public static func formatToolDeclarations(_ tools: [ToolSchema]) -> String {
        guard !tools.isEmpty else { return "" }
        return tools.map { tool -> String in
            var lines = ["- \(tool.name): \(tool.description)"]
            if !tool.parameters.isEmpty {
                lines.append("  * 参数:")
                for param in tool.parameters {
                    let reqText = param.required ? "必填" : "选填"
                    lines.append("    - \(param.name) (\(param.kind.rawValue), \(reqText)): \(param.description)")
                }
            } else {
                lines.append("  * 参数: 无")
            }
            lines.append("  * 返回: 工具执行结果文本（若失败则返回以 \"Error:\" 开头的错误说明）")
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

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
                let cleanContent = item.role == "user" ? item.content : extractResultContent(from: item.content)
                historyText += "\n\(roleName): \(cleanContent)"
            }
            sections.append(historyText)
        }

        let trimmedCurrent = currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolConstraint = !trimmedTools.isEmpty
            ? "\n\n##重要重要!!! 你不需要执行工具，只用决策返回工具格式就好##"
            : ""
        let promptWithConstraint = trimmedCurrent + toolConstraint

        if sections.isEmpty {
            return promptWithConstraint
        } else {
            sections.append("【当前提问】\n\(promptWithConstraint)")
            return sections.joined(separator: "\n\n")
        }
    }

    /// Extracts the real answer content from the shortcut automation executor's raw response.
    /// The raw response is typically wrapped in `{"action":"exec","result":"...","status":"completed",...}`.
    /// If wrapped, returns the inner `result` string; otherwise returns the input text.
    public static func extractResultContent(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") && trimmed.hasSuffix("}"),
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultValue = json["result"] else {
            return text
        }
        if let str = resultValue as? String {
            return str
        }
        if let data = try? JSONSerialization.data(withJSONObject: resultValue, options: []),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return text
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
    /// Supports:
    /// 1. Markdown code blocks: ```tool_call { ... } ``` or ```json { ... } ```
    /// 2. Tagged blocks: <tool_call> { ... } </tool_call> or <call> ... </call>
    /// 3. Prefixes: tool_call { ... } or tool_call: { ... } or call: { ... }
    /// 4. Embedded or bare JSON with "tool" (or "name") and "arguments" (or "args")
    public static func parseToolCall(from text: String) -> ParsedToolCall? {
        // 1. Markdown code block: ```tool_call { ... } ``` or ```json { ... } ```
        let codeBlockPattern = #"(?s)```(?:tool_call|json)?\s*(\{[\s\S]*?\})\s*```"#
        if let regex = try? NSRegularExpression(pattern: codeBlockPattern) {
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches where match.numberOfRanges > 1 {
                let jsonString = nsText.substring(with: match.range(at: 1))
                if let parsed = parseToolJSON(jsonString) {
                    return parsed
                }
            }
        }

        // 2. Tagged block: <tool_call> { ... } </tool_call> or <call> ... </call>
        let tagPattern = #"(?s)<(?:tool_call|call)>\s*(\{[\s\S]*?\})\s*</(?:tool_call|call)>"#
        if let regex = try? NSRegularExpression(pattern: tagPattern) {
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches where match.numberOfRanges > 1 {
                let jsonString = nsText.substring(with: match.range(at: 1))
                if let parsed = parseToolJSON(jsonString) {
                    return parsed
                }
            }
        }

        // 3. Prefixed: tool_call { ... } or tool_call: { ... } or call: { ... }
        let prefixPattern = #"(?s)(?:tool_call|call)\s*:?\s*(\{[\s\S]*?\})"#
        if let regex = try? NSRegularExpression(pattern: prefixPattern) {
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches where match.numberOfRanges > 1 {
                let jsonString = nsText.substring(with: match.range(at: 1))
                if let parsed = parseToolJSON(jsonString) {
                    return parsed
                }
            }
        }

        // 4. Scan any balanced JSON object inside text
        var searchIndex = text.startIndex
        while searchIndex < text.endIndex, let openBrace = text[searchIndex...].firstIndex(of: "{") {
            if let closeBrace = balancedEnd(of: text[openBrace...]) {
                let candidate = String(text[openBrace..<closeBrace])
                if let parsed = parseToolJSON(candidate) {
                    return parsed
                }
                searchIndex = closeBrace
            } else {
                break
            }
        }

        return nil
    }

    /// Finds index just past the matching closing brace '}', honoring quotes and escapes.
    private static func balancedEnd(of s: some StringProtocol) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { return s.index(after: i) }
            }
            i = s.index(after: i)
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
        var args: [String: Any] = [:]
        if let directArgs = (json["arguments"] as? [String: Any]) ?? (json["args"] as? [String: Any]) {
            args = directArgs
        } else if let argsString = (json["arguments"] as? String) ?? (json["args"] as? String),
                  let argsData = argsString.data(using: .utf8),
                  let parsedArgs = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
            args = parsedArgs
        }
        return ParsedToolCall(tool: toolName, arguments: args)
    }
}
