// SPDX-License-Identifier: MIT

import Foundation

/// The system seam for executing shortcut automation tasks.
public protocol ShortcutAutomationExecuting: Sendable {
    /// Execute a shortcut automation task.
    /// - Parameters:
    ///   - action: Either "list" or "exec".
    ///   - shortcut: The name of the shortcut to run (required for "exec").
    ///   - params: Parameters to pass to the shortcut (plain string or serialized JSON string).
    ///   - taskId: Optional specific task UUID. If omitted/nil, an ID is generated.
    ///   - timeoutSeconds: Maximum timeout (1–25 seconds).
    /// - Returns: A JSON string result representing the outcome.
    func executeTask(
        action: String,
        shortcut: String?,
        params: String?,
        taskId: String?,
        timeoutSeconds: Int
    ) async throws -> String

    /// Current permission state for notifications/automations.
    func permissionState() async -> ToolPermission

    /// Prompt the user for permission if undetermined.
    func requestPermission() async -> ToolPermission
}

public extension ShortcutAutomationExecuting {
    func permissionState() async -> ToolPermission { .granted }
    func requestPermission() async -> ToolPermission { .granted }
}

/// Errors raised during shortcut automation execution.
public enum ShortcutAutomationError: Error, Sendable, Equatable {
    case invalidAction(String)
    case missingShortcut
    case permissionDenied
    case timeout(Int)
    case executionFailed(String)
}

/// iOS Shortcut Automation tool for querying available shortcuts or executing a specific shortcut
/// via local notification triggers and JSON file exchange.
public struct ShortcutAutomationTool: Tool {
    private let executor: (any ShortcutAutomationExecuting)?

    public init(executor: (any ShortcutAutomationExecuting)? = nil) {
        self.executor = executor
    }

    /// Schema without an executor instance, so descriptor catalogs can advertise the tool
    /// before any execution seam exists.
    public static let schema: ToolSchema = ToolSchema(
        name: "shortcut_automation_tool",
        description: "iOS Shortcut Automation tool for querying available shortcuts or executing a specific shortcut via local notification triggers and JSON file exchange (max wait: 25s).",
        parameters: [
            ToolParam(
                name: "action",
                kind: .string,
                description: "Operation to perform: \"list\" (query available shortcuts info) or \"exec\" (execute a specified shortcut). Required."
            ),
            ToolParam(
                name: "shortcut",
                kind: .string,
                description: "The name of the shortcut to execute. Required when action is \"exec\".",
                required: false
            ),
            ToolParam(
                name: "taskId",
                kind: .string,
                description: "Optional task UUID. If omitted, the tool automatically generates a unique UUID.",
                required: false
            ),
            ToolParam(
                name: "params",
                kind: .string,
                description: "Optional input parameters or text to pass to the shortcut when executing. Can be a plain string (e.g. \"Hello\") or a JSON string for multiple key-value parameters.",
                required: false
            ),
            ToolParam(
                name: "timeout",
                kind: .number,
                description: "Optional maximum timeout in seconds to wait for shortcut execution to complete. Must be between 1 and 25. Defaults to 15 seconds.",
                required: false
            ),
        ]
    )

    public var schema: ToolSchema { Self.schema }

    public func execute(argumentsJSON: String) async -> String {
        guard let executor else {
            return "Error: Shortcut automation is not available on this device."
        }

        let call = ToolCall(name: "shortcut_automation_tool", argumentsJSON: argumentsJSON)
        guard let rawAction = call.arg("action")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !rawAction.isEmpty else {
            return "Error: missing 'action'. Must be \"list\" or \"exec\"."
        }

        guard rawAction == "list" || rawAction == "exec" else {
            return "Error: invalid action \"\(rawAction)\". Must be \"list\" or \"exec\"."
        }

        let shortcut = call.arg("shortcut")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawAction == "exec" {
            guard let shortcut, !shortcut.isEmpty else {
                return "Error: 'shortcut' parameter is required when action is \"exec\"."
            }
        }

        let taskId = call.arg("taskId")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = call.arg("params")
        let requestedTimeout = call.arg("timeout").flatMap { Int(Double($0) ?? -1) } ?? 15
        let timeoutSeconds = min(25, max(1, requestedTimeout))

        do {
            return try await executor.executeTask(
                action: rawAction,
                shortcut: shortcut,
                params: params,
                taskId: taskId?.isEmpty == true ? nil : taskId,
                timeoutSeconds: timeoutSeconds
            )
        } catch ShortcutAutomationError.permissionDenied {
            return "Notification permission is off — enable Notifications in Settings to use Shortcut Automations."
        } catch ShortcutAutomationError.timeout(let seconds) {
            return "Error: Shortcut automation timed out waiting for completion (\(seconds)s)."
        } catch ShortcutAutomationError.invalidAction(let act) {
            return "Error: invalid action \"\(act)\". Must be \"list\" or \"exec\"."
        } catch ShortcutAutomationError.missingShortcut {
            return "Error: 'shortcut' parameter is required when action is \"exec\"."
        } catch ShortcutAutomationError.executionFailed(let reason) {
            return "Error: Shortcut automation execution failed: \(reason)"
        } catch {
            return "Error: Shortcut automation execution failed: \(error.localizedDescription)"
        }
    }
}
