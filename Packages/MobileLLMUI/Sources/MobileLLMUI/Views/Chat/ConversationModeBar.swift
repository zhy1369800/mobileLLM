// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import LLMCore
import AgentContracts
import AgentRuntime

/// The persistent top status bar above the composer: approval mode, reasoning effort, and live context meter.
struct ConversationModeBar: View {
    let chat: ChatStore

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Menu {
                approvalOption("Ask", mode: .ask)
                approvalOption("Safe preset", mode: .safePreset)
                approvalOption("Full access", mode: .fullAccess)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "lock.shield")
                    Text(approvalLabel)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline))
            }
            .accessibilityLabel(approvalLabel)

            Menu {
                ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                    Button {
                        chat.conversationReasoningEffort = effort
                    } label: {
                        if chat.effectiveReasoningEffort == effort {
                            Label(effort.rawValue.capitalized, systemImage: "checkmark")
                        } else {
                            Text(effort.rawValue.capitalized)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                    Text("Effort: \(chat.effectiveReasoningEffort.rawValue.capitalized)")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline))
            }

            Spacer(minLength: 0)

            ContextMeterBar(chat: chat)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private var approvalLabel: String {
        switch chat.effectiveApprovalMode {
        case .ask: "Approval: Ask"
        case .safePreset: "Approval: Safe preset"
        case .fullAccess: "Approval: Full access"
        }
    }

    @ViewBuilder
    private func approvalOption(_ title: String, mode: AgentApprovalMode?) -> some View {
        let isSelected = mode.map { chat.effectiveApprovalMode == $0 } ?? false
        Button {
            chat.conversationApprovalMode = mode
        } label: {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// Isolated subview for the context meter so `chat.contextUsage()` reading `chat.streaming` only
/// invalidates this 14pt gauge row during streaming generation, rather than re-evaluating the entire
/// `Composer` body on every 20fps flush.
struct ContextMeterBar: View {
    let chat: ChatStore

    private func meterColor(for usage: (used: Int, cap: Int)) -> Color {
        let ratio = usage.cap > 0 ? Double(usage.used) / Double(usage.cap) : 0
        if ratio >= 0.98 { return Theme.danger }
        if ratio >= 0.85 { return Theme.fitAmber }
        return Theme.textTertiary
    }

    var body: some View {
        let currentUsage = chat.contextUsage()
        let color = meterColor(for: currentUsage)
        HStack(spacing: 4) {
            if currentUsage.used > 0 {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.caption2).foregroundStyle(color)
                Text(Format.context(currentUsage.used, currentUsage.cap))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(color)
                    .accessibilityLabel("Context used")
                    .accessibilityValue("\(currentUsage.used) of \(currentUsage.cap) tokens")
            }
        }
    }
}
