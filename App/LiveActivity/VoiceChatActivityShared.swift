// SPDX-License-Identifier: MIT

#if os(iOS) && canImport(ActivityKit) && canImport(AppIntents)
import ActivityKit
import AppIntents
import Foundation

/// Shared ActivityKit model compiled into both the main app target and the widget extension.
struct VoiceChatActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            case listening
            case thinking
            case speaking
        }

        var phase: Phase
        var subtitle: String
        var toolName: String?
        var toolRunning: Bool
        var modelName: String
    }

    let sessionID: String
}

/// Main-app command bridge invoked directly by Live Activity intents without requiring an App Group.
@MainActor
final class VoiceLiveActivityCommandCenter {
    static let shared = VoiceLiveActivityCommandCenter()

    var onStopRequested: (@MainActor () -> Void)?
    var onInterruptRequested: (@MainActor () -> Void)?

    private init() {}

    func performStop() -> Bool {
        guard let onStopRequested else { return false }
        onStopRequested()
        return true
    }

    func performInterrupt() -> Bool {
        guard let onInterruptRequested else { return false }
        onInterruptRequested()
        return true
    }
}

/// Ends the active real-time voice conversation in the background without foregrounding the app.
struct StopVoiceChatIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "结束语音对话"
    static let description = IntentDescription("停止当前实时语音对话并关闭灵动岛")
    static let openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        _ = await MainActor.run {
            VoiceLiveActivityCommandCenter.shared.performStop()
        }
        for activity in Activity<VoiceChatActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}

/// Interrupts ongoing thinking or speech playback and immediately resumes listening in the background.
struct InterruptVoiceChatIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "打断语音回复"
    static let description = IntentDescription("打断当前思考或播报并继续聆听")
    static let openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        _ = await MainActor.run {
            VoiceLiveActivityCommandCenter.shared.performInterrupt()
        }
        return .result()
    }
}
#endif
