// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import LLMCore

/// Persistent multi-select quick tools sheet shared by the chat composer and voice chat mode.
struct QuickToolsPickerSheet: View {
    @Bindable var chat: ChatStore
    @Bindable var settings: AppSettings
    var toolEventStore: (any EventStoring)? = nil
    var toolLocationProvider: (any LocationProviding)? = nil
    var toolShortcutExecutor: (any ShortcutAutomationExecuting)? = nil
    var onOpenToolSettings: () -> Void
    var onDone: () -> Void

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { chat.toolsEnabled },
                                     set: { newValue in
                                         chat.toolsEnabled = newValue
                                         chat.applyCurrentToolSelectionToActiveConversation()
                                     })) {
                    Label("Allow selected tools", systemImage: "hammer")
                }
                .tint(Theme.accent)
            }

            Section("Network") {
                ForEach(Self.networkToolRows) { toolToggle($0).tint(Theme.accent) }
            }
            Section("On device") {
                ForEach(Self.onDeviceToolRows) { toolToggle($0).tint(Theme.accent) }
            }
            Section("Personal data") {
                ForEach(Self.personalToolRows) { toolToggle($0).tint(Theme.accent) }
            }

            if !settings.mcpServers.isEmpty {
                Section("MCP servers") {
                    ForEach(settings.mcpServers) { server in
                        Toggle(isOn: mcpServerBinding(server.id)) {
                            Label(server.name, systemImage: "server.rack")
                        }
                        .tint(Theme.accent)
                    }
                }
            }

            Section {
                Button {
                    onDone()
                    Task { @MainActor in
                        onOpenToolSettings()
                    }
                } label: {
                    Label("Tool Settings…", systemImage: "gearshape")
                }
            }
        }
        .navigationTitle("Tools")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { onDone() }
            }
        }
    }

    private static let networkToolRows =
        BuiltInToolRow.all.filter { ["web_search", "fetch_webpage", "wikipedia"].contains($0.id) }
    private static let onDeviceToolRows =
        BuiltInToolRow.all.filter { ["calculator", "clock", "memory"].contains($0.id) }
    private static let personalToolRows =
        BuiltInToolRow.all.filter { ["calendar", "reminders", "location", "shortcut_automation"].contains($0.id) }

    private func toolToggle(_ row: BuiltInToolRow) -> some View {
        Toggle(isOn: Binding(
            get: { row.isOn(in: settings) },
            set: { enabled in
                var disabled = settings.disabledBuiltInTools
                for id in row.toolIDs {
                    if enabled { disabled.remove(id.rawValue) } else { disabled.insert(id.rawValue) }
                }
                settings.disabledBuiltInTools = disabled
                chat.applyCurrentToolSelectionToActiveConversation()
                if enabled, row.privacy {
                    Task { @MainActor in
                        if await row.requestPermission(eventStore: toolEventStore,
                                                       locationProvider: toolLocationProvider,
                                                       shortcutExecutor: toolShortcutExecutor) == .denied {
                            chat.showToast(Toast(
                                "\(row.title) is selected, but access is off in system Settings.",
                                kind: .warning, autoDismiss: 5
                            ))
                        }
                    }
                }
            }
        )) {
            Label(row.title, systemImage: row.icon)
        }
    }

    private func mcpServerBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.mcpServers.first(where: { $0.id == id })?.isEnabled ?? false },
            set: { enabled in
                var servers = settings.mcpServers
                guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
                servers[index].isEnabled = enabled
                settings.mcpServers = servers
                chat.applyCurrentToolSelectionToActiveConversation()
            }
        )
    }
}

/// Persistent multi-select quick skills sheet shared by the chat composer and voice chat mode.
struct QuickSkillsPickerSheet: View {
    @Bindable var chat: ChatStore
    var onManageSkills: () -> Void
    var onDone: () -> Void

    var body: some View {
        List {
            if chat.availableSkills.isEmpty {
                Text("No skills yet. Tap Manage Skills… below to create or import one.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Section {
                    ForEach(chat.availableSkills) { skill in
                        let selected = chat.activeSkills.contains(where: { $0.id == skill.id })
                        Button {
                            chat.toggleActiveSkill(skill.id)
                        } label: {
                            HStack(spacing: Theme.Space.sm) {
                                Text(skill.emoji).font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skill.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.textPrimary)
                                    if !skill.summary.isEmpty {
                                        Text(skill.summary)
                                            .font(.caption)
                                            .foregroundStyle(Theme.textTertiary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !chat.activeSkills.isEmpty {
                Section {
                    Button("Clear selected skills", role: .destructive) {
                        chat.setActiveSkill(nil)
                    }
                }
            }

            Section {
                Button {
                    onDone()
                    Task { @MainActor in
                        onManageSkills()
                    }
                } label: {
                    Label("Manage Skills…", systemImage: "slider.horizontal.3")
                }
            }
        }
        .navigationTitle("Skills")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { onDone() }
            }
        }
    }
}
