// SPDX-License-Identifier: MIT

#if canImport(UserNotifications)
import Foundation
import UserNotifications

/// The real, on-device `ShortcutAutomationExecuting` backed by local notifications and JSON task files
/// under `Documents/tasks/`.
public final class ShortcutAutomationService: ShortcutAutomationExecuting, @unchecked Sendable {
    private let tasksSubdirectory = "tasks"

    public init() {}

    private func getTasksDirectory() throws -> URL {
        let fm = FileManager.default
        guard let docDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw ShortcutAutomationError.executionFailed("Documents directory not available")
        }
        let tasksDir = docDir.appendingPathComponent(tasksSubdirectory, isDirectory: true)
        if !fm.fileExists(atPath: tasksDir.path) {
            try fm.createDirectory(at: tasksDir, withIntermediateDirectories: true)
        }
        let placeholder = tasksDir.appendingPathComponent(".placeholder")
        if !fm.fileExists(atPath: placeholder.path) {
            try? "mobileLLM tasks directory".data(using: .utf8)?.write(to: placeholder)
        }
        return tasksDir
    }

    public func permissionState() async -> ToolPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .granted
        @unknown default: return .denied
        }
    }

    public func requestPermission() async -> ToolPermission {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound]
            )
            return granted ? .granted : .denied
        } catch {
            return .denied
        }
    }

    public func executeTask(
        action: String,
        shortcut: String?,
        params: String?,
        taskId: String?,
        timeoutSeconds: Int
    ) async throws -> String {
        // Clean up any stale task files in background
        Task { [weak self] in
            self?.pruneOldTasks()
        }

        let effectiveTaskId = (taskId != nil && !taskId!.isEmpty) ? taskId! : UUID().uuidString
        let effectiveShortcut = shortcut ?? ""
        let tasksDir = try getTasksDirectory()
        let taskFileURL = tasksDir.appendingPathComponent("task_\(effectiveTaskId).json")

        var parsedParams: Any = ""
        if let params, !params.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = params.trimmingCharacters(in: .whitespacesAndNewlines)
            if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
                (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")),
               let data = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) {
                parsedParams = json
            } else {
                parsedParams = trimmed
            }
        }

        let initialPayload: [String: Any] = [
            "taskId": effectiveTaskId,
            "action": action,
            "shortcut": effectiveShortcut,
            "params": parsedParams,
            "status": "pending",
            "result": ""
        ]

        let fileData = try JSONSerialization.data(withJSONObject: initialPayload, options: [.prettyPrinted, .sortedKeys])
        try fileData.write(to: taskFileURL, options: .atomic)

        // Schedule local notification to trigger Shortcuts automation
        let content = UNMutableNotificationContent()
        content.title = "Automation Task"
        content.subtitle = "#\(effectiveTaskId)"
        content.body = action == "list" ? "List all shortcuts" : "Execute shortcut: \(effectiveShortcut)"
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "task_\(effectiveTaskId)",
            content: content,
            trigger: nil // deliver immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // Even if notification scheduling fails, don't immediately fail; the file is created
        }

        // Wait and poll for completion
        let result = try await waitForTaskCompletion(
            taskFileURL: taskFileURL,
            taskId: effectiveTaskId,
            action: action,
            shortcut: effectiveShortcut,
            timeoutSeconds: timeoutSeconds
        )

        return result
    }

    private func waitForTaskCompletion(
        taskFileURL: URL,
        taskId: String,
        action: String,
        shortcut: String,
        timeoutSeconds: Int
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        let fm = FileManager.default

        while Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms

            guard fm.fileExists(atPath: taskFileURL.path),
                  let data = try? Data(contentsOf: taskFileURL),
                  !data.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let status = (json["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if status == "completed" {
                let responsePayload: [String: Any] = [
                    "success": true,
                    "taskId": json["taskId"] ?? taskId,
                    "action": json["action"] ?? action,
                    "shortcut": json["shortcut"] ?? shortcut,
                    "status": "completed",
                    "result": json["result"] ?? ""
                ]
                if let responseData = try? JSONSerialization.data(withJSONObject: responsePayload, options: [.sortedKeys]),
                   let string = String(data: responseData, encoding: .utf8) {
                    return string
                }
                return #"{"success":true,"status":"completed"}"#
            } else if status == "failed" || status == "error" {
                let failMessage = (json["result"] as? String) ?? "Shortcut execution failed."
                throw ShortcutAutomationError.executionFailed(failMessage)
            }
        }

        throw ShortcutAutomationError.timeout(timeoutSeconds)
    }

    private func pruneOldTasks() {
        guard let tasksDir = try? getTasksDirectory() else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let oneDayAgo = Date().addingTimeInterval(-86400)

        for file in files where file.lastPathComponent.hasPrefix("task_") && file.pathExtension == "json" {
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let modDate = attrs[.modificationDate] as? Date,
               modDate < oneDayAgo {
                try? fm.removeItem(at: file)
            }
        }
    }
}
#endif
