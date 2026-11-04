// SPDX-License-Identifier: MIT

import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Coordinates actionable notifications with text input (Quick Notification Assistant).
/// Allows the user to pull down a system notification anywhere in iOS to ask questions and receive in-place answers
/// across multiple conversation turns without foregrounding the app.
public enum QuickNotificationCoordinator {
    public static let categoryIdentifier = "mobilellm.quick_chat.category"
    public static let actionIdentifier = "mobilellm.quick_chat.reply"
    public static let explainClipboardActionIdentifier = "mobilellm.quick_chat.explain_clipboard"
    public static let notificationIdentifier = "mobilellm.quick_chat.banner"

    /// Sets up notification action category with text input and registers with the system.
    public static func registerCategory() {
        #if canImport(UserNotifications)
        let replyAction = UNTextInputNotificationAction(
            identifier: actionIdentifier,
            title: "快捷回复",
            options: [],
            textInputButtonTitle: "发送",
            textInputPlaceholder: "问点什么..."
        )
        let clipboardAction = UNNotificationAction(
            identifier: explainClipboardActionIdentifier,
            title: "📋 解释剪贴板",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [replyAction, clipboardAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        #endif
    }

    /// Requests user notification permission if not yet determined.
    public static func requestAuthorization() async -> Bool {
        #if canImport(UserNotifications)
        do {
            let center = UNUserNotificationCenter.current()
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            if granted {
                registerCategory()
            }
            return granted
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    /// Posts the initial standby notification when backgrounded.
    public static func postStandbyNotification() {
        postNotification(
            title: "mobileLLM 快捷助手",
            body: "已就绪。下拉或长按通知即可提问对话。"
        )
    }

    /// Updates the notification to indicate thinking state.
    public static func postThinkingNotification() {
        postNotification(
            title: "mobileLLM 快捷助手",
            body: "正在思考中，请稍候..."
        )
    }

    /// Updates the notification when clipboard is empty.
    public static func postEmptyClipboardNotification() {
        postNotification(
            title: "mobileLLM 快捷助手",
            body: "剪贴板未检测到文本内容，请先复制后再试。"
        )
    }

    /// Updates the notification with the model's response and prompts for next turn.
    public static func postResponseNotification(text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview: String
        if clean.count > 150 {
            preview = String(clean.prefix(150)) + "..."
        } else {
            preview = clean
        }
        let body = preview.isEmpty ? "生成完毕。" : "\(preview)\n\n(下拉或长按可继续追问)"
        postNotification(
            title: "mobileLLM 回复",
            body: body
        )
    }

    /// Posts or in-place updates the quick chat banner notification.
    public static func postNotification(title: String, body: String) {
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = categoryIdentifier
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: nil // Deliver immediately
        )

        Task {
            try? await UNUserNotificationCenter.current().add(request)
        }
        #endif
    }

    /// Dismisses the quick chat notification banner.
    public static func dismissNotification() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        #endif
    }
}
