// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import LLMCore

/// Settings → Behavior → Local model logs.
/// Shows request/response history for on-device models, newest first.
struct LocalModelLogsView: View {
    @Bindable var logStore: LocalModelLogStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClearAll = false
    @State private var pendingDeleteID: UUID?

    var body: some View {
        List {
            Section {
                Text("When enabled, full prompts, generation parameters, and responses for local "
                     + "models are recorded here. Everything stays on this device and can be cleared at any time.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Color.clear)
            }

            Section {
                if logStore.entries.isEmpty {
                    Text("No logs recorded yet. Send a message to a local model to see request and response details here.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(logStore.entries) { entry in
                        NavigationLink {
                            LocalModelLogDetailView(entry: entry)
                        } label: {
                            logEntryRow(entry)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeleteID = entry.id
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(Theme.danger)
                        }
                    }
                }
            } header: {
                Text(logStore.entries.isEmpty ? "Logs" : "\(logStore.entries.count) Recorded")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }

            if !logStore.entries.isEmpty {
                Section {
                    Button(role: .destructive) { confirmClearAll = true } label: {
                        Label("Clear all logs", systemImage: "trash")
                            .foregroundStyle(Theme.danger)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .task { await logStore.reloadAsync() }
        .navigationTitle("Local Model Logs")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
                    .foregroundStyle(Theme.accent)
            }
            if !logStore.entries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) { confirmClearAll = true } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
        }
        .alert("Clear all logs?", isPresented: $confirmClearAll) {
            Button("Clear all", role: .destructive) { logStore.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently removes every recorded local model log on this device. This can't be undone.")
        }
        .alert("Delete log?", isPresented: Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteID {
                    logStore.delete(id: id)
                    pendingDeleteID = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text("Permanently removes this recorded log entry.")
        }
    }

    private func logEntryRow(_ entry: LocalModelLogEntry) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text(entry.modelID)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }

            if let stats = entry.stats {
                HStack(spacing: Theme.Space.sm) {
                    Label("\(stats.genTokens) tok", systemImage: "number")
                    Label(String(format: "%.1f tok/s", stats.tokensPerSecond), systemImage: "bolt.fill")
                    if let ttft = stats.ttftSeconds, ttft > 0 {
                        let ms = Int(round(ttft * 1000))
                        Label("\(ms)ms", systemImage: "stopwatch")
                    }
                    if let cached = stats.cachedPromptTokens, cached > 0 {
                        let pct = Int(round(stats.cacheHitRate * 100))
                        Label("Hit \(pct)%", systemImage: "sparkles")
                            .foregroundStyle(Theme.accent)
                    }
                    if let spec = stats.speculativeStats, spec.draftedTokens > 0 {
                        let pct = Int(round(spec.acceptanceRate * 100))
                        Label("\(spec.driver) \(pct)%", systemImage: "bolt.badge.checkmark")
                            .foregroundStyle(Theme.accent)
                    }
                    Label(stats.stopReason.rawValue, systemImage: "flag")
                }
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            }

            if let err = entry.error {
                Text("Error: \(err)")
                    .font(.caption2)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(1)
            } else {
                Text(entry.response.isEmpty ? "(Empty response)" : entry.response)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(Theme.surface)
    }
}

/// Detailed inspector for a single local model request & response log entry.
struct LocalModelLogDetailView: View {
    let entry: LocalModelLogEntry
    @State private var showCopiedPromptToast = false
    @State private var showCopiedResponseToast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                metadataSection
                messagesSection
                if let reasoning = entry.reasoning, !reasoning.isEmpty {
                    reasoningSection(reasoning)
                }
                responseSection
            }
            .padding(Theme.Space.lg)
        }
        .background(Theme.bg)
        .navigationTitle(entry.modelID)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Sections

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("METRICS & PARAMETERS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                metricRow("Timestamp", value: entry.timestamp.formatted(date: .complete, time: .complete))
                metricRow("Model", value: entry.modelID)
                metricRow("Temperature", value: String(format: "%.2f", entry.sampling.temperature))
                metricRow("Top P / Top K", value: "\(entry.sampling.topP) / \(entry.sampling.topK)")
                metricRow("Max Tokens", value: "\(entry.sampling.maxTokens)")
                metricRow("Speculative Mode", value: entry.sampling.speculativeMode.displayName)
                if let stats = entry.stats {
                    Divider().background(Theme.hairline)
                    metricRow("Prompt Tokens", value: "\(stats.promptTokens)")
                    if let cached = stats.cachedPromptTokens {
                        if cached > 0 {
                            let pct = String(format: "%.1f%%", stats.cacheHitRate * 100)
                            metricRow("Prompt Cache Hit", value: "\(pct) (\(cached) / \(cached + stats.promptTokens) tok)")
                        } else {
                            metricRow("Prompt Cache Hit", value: "0% (全量预填充)")
                        }
                    }
                    metricRow("Gen Tokens", value: "\(stats.genTokens)")
                    metricRow("Speed", value: String(format: "%.1f tok/s", stats.tokensPerSecond))
                    if let ttft = stats.ttftSeconds {
                        metricRow("TTFT (First Token)", value: "\(Int(round(ttft * 1000))) ms (\(String(format: "%.2f", ttft)) s)")
                    }
                    if stats.promptTPS > 0 {
                        metricRow("Prefill Speed", value: String(format: "%.1f tok/s", stats.promptTPS))
                    }
                    if let spec = stats.speculativeStats {
                        Divider().background(Theme.hairline)
                        metricRow("Speculative Driver", value: spec.driver)
                        metricRow("Speculative Acceptance", value: "\(spec.acceptedTokens) / \(spec.draftedTokens) (\(String(format: "%.1f%%", spec.acceptanceRate * 100)))")
                    }
                    metricRow("Stop Reason", value: stats.stopReason.rawValue)
                }
                if let err = entry.error {
                    Divider().background(Theme.hairline)
                    metricRow("Failure", value: err, isError: true)
                }
            }
            .padding(Theme.Space.md)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var messagesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text("REQUEST (PROMPTS & MESSAGES)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    copyRequestText()
                } label: {
                    Label(showCopiedPromptToast ? "Copied" : "Copy All", systemImage: showCopiedPromptToast ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                ForEach(Array(entry.messages.enumerated()), id: \.offset) { index, turn in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(turn.role.rawValue.uppercased())
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(roleBadgeColor(turn.role).opacity(0.15))
                                .foregroundStyle(roleBadgeColor(turn.role))
                                .clipShape(Capsule())
                            Spacer()
                            Text("#\(index + 1)")
                                .font(.caption2)
                                .foregroundStyle(Theme.textTertiary)
                        }

                        Text(turn.content)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                    if index < entry.messages.count - 1 {
                        Divider().background(Theme.hairline)
                    }
                }
            }
            .padding(Theme.Space.md)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func reasoningSection(_ reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("REASONING (THOUGHT TRACE)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)

            Text(reasoning)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var responseSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text("RESPONSE (OUTPUT)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    copyResponseText()
                } label: {
                    Label(showCopiedResponseToast ? "Copied" : "Copy", systemImage: showCopiedResponseToast ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }

            Text(entry.response.isEmpty ? "(No response generated)" : entry.response)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func metricRow(_ title: String, value: String, isError: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isError ? Theme.danger : Theme.textPrimary)
        }
    }

    private func roleBadgeColor(_ role: ChatTurn.Role) -> Color {
        switch role {
        case .system: return Theme.accent
        case .user: return .blue
        case .assistant: return .green
        }
    }

    private func copyRequestText() {
        let full = entry.messages.map { "[\($0.role.rawValue.uppercased())]\n\($0.content)" }.joined(separator: "\n\n")
        Clipboard.copy(full)
        showCopiedPromptToast = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            showCopiedPromptToast = false
        }
    }

    private func copyResponseText() {
        Clipboard.copy(entry.response)
        showCopiedResponseToast = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            showCopiedResponseToast = false
        }
    }
}
