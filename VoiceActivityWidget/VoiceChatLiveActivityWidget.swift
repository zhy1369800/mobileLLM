// SPDX-License-Identifier: MIT

import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/// Dynamic Island & Lock Screen Live Activity for real-time voice conversations,
/// styled with mobileLLM's ink-wash palette (青瓷玉绿 / 暖赭石 / 印章朱砂 / 宣纸 / 夜墨).
struct VoiceChatLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceChatActivityAttributes.self) { context in
            LockScreenVoiceCardView(state: context.state)
                .widgetURL(VoiceInkTheme.deepLinkURL)
                .activityBackgroundTint(VoiceInkTheme.lockScreenCardBackground)
                .activitySystemActionForegroundColor(VoiceInkTheme.lockScreenPrimaryText)
        } dynamicIsland: { context in
            let state = context.state
            let style = PhaseStyle(phase: state.phase)

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: style.iconName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(style.accentColor)
                        Text(style.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.modelName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    let hasToolBadge = (state.toolName?.isEmpty == false)
                    VStack(alignment: .leading, spacing: 7) {
                        if let toolName = state.toolName, !toolName.isEmpty {
                            IslandToolBadge(toolName: toolName, isRunning: state.toolRunning)
                        }

                        Text(style.displaySubtitle(for: state.subtitle))
                            .font(.footnote)
                            .lineSpacing(2)
                            .foregroundStyle(state.subtitle.isEmpty ? .white.opacity(0.62) : .white.opacity(0.94))
                            .lineLimit(hasToolBadge ? 3 : 4)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 8) {
                            Text(style.footerHint)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)

                            Spacer(minLength: 6)

                            if state.phase == .thinking || state.phase == .speaking {
                                Button(intent: InterruptVoiceChatIntent()) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "hand.raised.fill")
                                        Text("打断")
                                    }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 5)
                                    .background(VoiceInkTheme.ochre.opacity(0.92), in: Capsule())
                                    .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }

                            Button(intent: StopVoiceChatIntent()) {
                                HStack(spacing: 4) {
                                    Image(systemName: "phone.down.fill")
                                    Text("挂断")
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .background(VoiceInkTheme.cinnabar, in: Capsule())
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 2)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
            } compactLeading: {
                Image(systemName: style.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(style.accentColor)
                    .padding(.leading, 2)
            } compactTrailing: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(style.accentColor)
                        .frame(width: 6, height: 6)
                    Text(style.compactLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.trailing, 2)
            } minimal: {
                Image(systemName: style.iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(style.accentColor)
            }
            .widgetURL(VoiceInkTheme.deepLinkURL)
            .keylineTint(style.accentColor)
        }
    }
}

// MARK: - Lock Screen & Banner Presentation

private struct LockScreenVoiceCardView: View {
    let state: VoiceChatActivityAttributes.ContentState
    @Environment(\.colorScheme) private var colorScheme

    private var style: PhaseStyle { PhaseStyle(phase: state.phase) }

    private var primaryInk: Color {
        colorScheme == .dark
            ? Color(red: 0.95, green: 0.93, blue: 0.89)
            : Color(red: 0.11, green: 0.10, blue: 0.09)
    }

    private var secondaryInk: Color {
        colorScheme == .dark
            ? Color(red: 0.68, green: 0.66, blue: 0.62)
            : Color(red: 0.42, green: 0.40, blue: 0.37)
    }

    private var pillBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(style.accentColor)
                    .frame(width: 8, height: 8)

                Text(style.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(primaryInk)
                    .lineLimit(1)
                    .fixedSize()

                Text(state.modelName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(secondaryInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(pillBackground, in: Capsule())

                Spacer(minLength: 6)

                if state.phase == .thinking || state.phase == .speaking {
                    Button(intent: InterruptVoiceChatIntent()) {
                        HStack(spacing: 4) {
                            Image(systemName: "hand.raised.fill")
                            Text("打断")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(VoiceInkTheme.ochre, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button(intent: StopVoiceChatIntent()) {
                    HStack(spacing: 4) {
                        Image(systemName: "phone.down.fill")
                        Text("挂断")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(VoiceInkTheme.cinnabar, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if let toolName = state.toolName, !toolName.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: state.toolRunning ? "gearshape.2.fill" : "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(state.toolRunning ? VoiceInkTheme.ochre : VoiceInkTheme.celadon)
                    Text(state.toolRunning ? "\(toolName) · 执行中" : toolName)
                        .font(.caption2.monospaced())
                        .foregroundStyle(secondaryInk)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(pillBackground, in: Capsule())
            }

            Text(style.displaySubtitle(for: state.subtitle))
                .font(.footnote)
                .lineSpacing(2)
                .foregroundStyle(state.subtitle.isEmpty ? secondaryInk : primaryInk)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct IslandToolBadge: View {
    let toolName: String
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isRunning ? "gearshape.2.fill" : "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(isRunning ? VoiceInkTheme.ochre : VoiceInkTheme.celadon)
            Text(isRunning ? "\(toolName) · 执行中" : toolName)
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.12), in: Capsule())
    }
}

// MARK: - Ink-Wash Theme Tokens & Phase Helpers

private enum VoiceInkTheme {
    static let deepLinkURL = URL(string: "mobilellm://voice")
    static var celadon: Color { Color(red: 0.24, green: 0.68, blue: 0.49) }
    static var ochre: Color { Color(red: 0.84, green: 0.54, blue: 0.24) }
    static var cinnabar: Color { Color(red: 0.78, green: 0.28, blue: 0.22) }

    static var lockScreenCardBackground: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.10, green: 0.10, blue: 0.09, alpha: 0.94)
                : UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 0.96)
        })
    }

    static var lockScreenPrimaryText: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.95, green: 0.93, blue: 0.89, alpha: 1.0)
                : UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1.0)
        })
    }
}

private struct PhaseStyle {
    let phase: VoiceChatActivityAttributes.ContentState.Phase

    var title: String {
        switch phase {
        case .listening: return "聆听中"
        case .thinking: return "思考中"
        case .speaking: return "回复中"
        }
    }

    var compactLabel: String {
        switch phase {
        case .listening: return "聆听"
        case .thinking: return "思考"
        case .speaking: return "回复"
        }
    }

    var iconName: String {
        switch phase {
        case .listening: return "mic.fill"
        case .thinking: return "sparkles"
        case .speaking: return "waveform"
        }
    }

    var accentColor: Color {
        switch phase {
        case .listening: return VoiceInkTheme.celadon
        case .thinking: return VoiceInkTheme.ochre
        case .speaking: return VoiceInkTheme.cinnabar
        }
    }

    func displaySubtitle(for subtitle: String) -> String {
        guard subtitle.isEmpty else { return subtitle }
        switch phase {
        case .listening: return "正在聆听，请随时开口…"
        case .thinking: return "正在整理思路…"
        case .speaking: return "正在语音播报…"
        }
    }

    var footerHint: String {
        switch phase {
        case .listening: return "说话后停顿自动发送"
        case .thinking: return "思考中可点击右侧打断"
        case .speaking: return "可随时开口打断"
        }
    }
}
