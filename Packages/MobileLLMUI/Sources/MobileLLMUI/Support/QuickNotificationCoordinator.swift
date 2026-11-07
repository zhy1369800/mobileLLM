// SPDX-License-Identifier: MIT

import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Coordinates actionable notifications with text input (Quick Notification Assistant).
/// Allows the user to pull down a system notification anywhere in iOS to ask questions and receive in-place answers
/// across multiple conversation turns without foregrounding the app.
public enum QuickNotificationCoordinator {
    public static let standbyCategoryIdentifier = "mobilellm.quick_chat.category.standby"
    public static let responseCategoryIdentifier = "mobilellm.quick_chat.category.response"
    public static var categoryIdentifier: String { standbyCategoryIdentifier }

    public static let actionIdentifier = "mobilellm.quick_chat.reply"
    public static let continueActionIdentifier = "mobilellm.quick_chat.continue"
    public static let copyActionIdentifier = "mobilellm.quick_chat.copy"
    public static let explainClipboardActionIdentifier = "mobilellm.quick_chat.explain_clipboard"
    public static let notificationIdentifier = "mobilellm.quick_chat.banner"

    /// Sets up notification action categories for both standby and response states.
    public static func registerCategory() {
        #if canImport(UserNotifications)
        // Standby actions: [快捷提问, 解释粘贴]
        let replyAction = UNTextInputNotificationAction(
            identifier: actionIdentifier,
            title: "快捷提问",
            options: [],
            textInputButtonTitle: "发送",
            textInputPlaceholder: "问点什么..."
        )
        let clipboardAction = UNNotificationAction(
            identifier: explainClipboardActionIdentifier,
            title: "解释粘贴",
            options: []
        )
        let standbyCategory = UNNotificationCategory(
            identifier: standbyCategoryIdentifier,
            actions: [replyAction, clipboardAction],
            intentIdentifiers: [],
            options: []
        )

        // Response actions: [继续追问, 复制回复, 解释粘贴]
        let continueAction = UNTextInputNotificationAction(
            identifier: continueActionIdentifier,
            title: "继续追问",
            options: [],
            textInputButtonTitle: "发送",
            textInputPlaceholder: "针对上述回答继续追问..."
        )
        let copyAction = UNNotificationAction(
            identifier: copyActionIdentifier,
            title: "复制回复",
            options: []
        )
        let responseCategory = UNNotificationCategory(
            identifier: responseCategoryIdentifier,
            actions: [continueAction, copyAction, clipboardAction],
            intentIdentifiers: [],
            options: []
        )

        // Legacy fallback category to ensure seamless transitions
        let legacyCategory = UNNotificationCategory(
            identifier: "mobilellm.quick_chat.category",
            actions: [replyAction, clipboardAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([standbyCategory, responseCategory, legacyCategory])
        #endif
    }

    /// Requests user notification permission if not yet determined.
    public static func requestAuthorization() async -> Bool {
        #if canImport(UserNotifications)
        do {
            let center = UNUserNotificationCenter.current()
            var options: UNAuthorizationOptions = [.alert, .sound]
            if #available(iOS 15.0, *) {
                options.insert(.timeSensitive)
            }
            let granted = try await center.requestAuthorization(options: options)
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
            body: "已就绪。下拉或长按通知即可提问对话。",
            categoryIdentifier: standbyCategoryIdentifier
        )
    }

    /// Updates the notification to indicate thinking state.
    public static func postThinkingNotification() {
        postNotification(
            title: "mobileLLM 快捷助手",
            body: "正在思考中，请稍候...",
            categoryIdentifier: standbyCategoryIdentifier
        )
    }

    /// Updates the notification when clipboard is empty.
    public static func postEmptyClipboardNotification() {
        postNotification(
            title: "mobileLLM 快捷助手",
            body: "剪贴板未检测到文本内容，请先复制后再试。",
            categoryIdentifier: standbyCategoryIdentifier
        )
    }

    /// Updates the notification with the model's complete response and dynamic response actions.
    public static func postResponseNotification(text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = clean.isEmpty ? "生成完毕。" : clean
        postNotification(
            title: "mobileLLM 回复",
            body: body,
            categoryIdentifier: responseCategoryIdentifier
        )
    }

    /// Updates the notification title to indicate that the response has been copied to the clipboard.
    public static func postCopiedNotification(text: String) {
        postNotification(
            title: "mobileLLM 已复制到剪贴板 ✓",
            body: text,
            categoryIdentifier: responseCategoryIdentifier
        )
    }

    /// Active notification dispatch task to serialize updates and cancel stale intermediate posts.
    private static var activePostTask: Task<Void, Never>?

    /// Posts or in-place updates the quick chat banner notification.
    /// When `reAlert` is true, explicitly removes existing delivered notifications and waits 100ms
    /// so that iOS SpringBoard never suppresses new banners under Persistent Banner settings.
    public static func postNotification(
        title: String,
        body: String,
        categoryIdentifier: String = standbyCategoryIdentifier,
        reAlert: Bool = true
    ) {
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = categoryIdentifier
        content.sound = nil
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }

        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: nil // Deliver immediately
        )

        activePostTask?.cancel()
        activePostTask = Task {
            let center = UNUserNotificationCenter.current()
            if reAlert {
                // 显式注销当前展示在屏幕上的悬停通知，消除 iOS 在“持续（Persistent）”样式下抑制同名新横幅弹出的问题
                center.removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
                center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !Task.isCancelled else { return }
            try? await center.add(request)
        }
        #endif
    }

    /// Dismisses the quick chat notification banner.
    public static func dismissNotification() {
        activePostTask?.cancel()
        activePostTask = nil
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        #endif
    }
}
