// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import LLMCore

/// Settings → Behavior → System prompt.
/// Manages system prompt presets, sets the global default, and allows creating, editing, and deleting presets.
struct SystemPromptManagementView: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var editingPreset: SystemPromptPreset?
    @State private var isCreatingNew = false
    @State private var pendingDelete: SystemPromptPreset?

    var body: some View {
        List {
            Section {
                Text("System prompts guide the model's tone and rules. Pick a preset as your global default, "
                     + "or customize prompts per conversation in conversation settings.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Color.clear)
            }

            Section {
                ForEach(settings.systemPromptPresets) { preset in
                    presetRow(preset)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !preset.isBuiltin {
                                Button(role: .destructive) {
                                    pendingDelete = preset
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(Theme.danger)
                            }
                        }
                }
            } header: {
                Text("PRESETS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("System prompt")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreatingNew = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add system prompt")
            }
        }
        .sheet(item: $editingPreset) { preset in
            NavigationStack {
                SystemPromptEditSheet(preset: preset, isNew: false, onSave: { updated in
                    settings.updateSystemPromptPreset(id: updated.id, name: updated.name, prompt: updated.prompt)
                }, onDelete: { id in
                    settings.deleteSystemPromptPreset(id: id)
                })
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 460)
            #endif
        }
        .sheet(isPresented: $isCreatingNew) {
            NavigationStack {
                SystemPromptEditSheet(
                    preset: SystemPromptPreset(name: "", prompt: ""),
                    isNew: true,
                    onSave: { newPreset in
                        let created = settings.addSystemPromptPreset(name: newPreset.name, prompt: newPreset.prompt)
                        settings.selectedSystemPromptID = created.id
                    }
                )
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 460)
            #endif
        }
        .alert("Delete Preset", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let target = pendingDelete {
                    settings.deleteSystemPromptPreset(id: target.id)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Delete \"\(pendingDelete?.name ?? "")\"? This cannot be undone.")
        }
    }

    private func presetRow(_ preset: SystemPromptPreset) -> some View {
        let isSelected = settings.selectedSystemPromptID == preset.id
        let snippet = preset.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        return HStack(spacing: Theme.Space.sm) {
            Button {
                settings.selectedSystemPromptID = preset.id
            } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Theme.Space.xs) {
                            Text(preset.name.isEmpty ? "Untitled" : preset.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)

                            if preset.isBuiltin {
                                Text("Standard")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.surface2, in: Capsule())
                            }
                        }

                        Text(snippet.isEmpty ? "No prompt text" : snippet)
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                editingPreset = preset
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit preset \(preset.name)")
        }
        .padding(.vertical, 2)
    }
}

/// Sheet for editing or creating a system prompt preset.
struct SystemPromptEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    let originalPreset: SystemPromptPreset
    let isNew: Bool
    var onSave: (SystemPromptPreset) -> Void
    var onDelete: ((String) -> Void)?

    @State private var name: String
    @State private var prompt: String
    @State private var showDeleteConfirm = false

    init(preset: SystemPromptPreset, isNew: Bool,
         onSave: @escaping (SystemPromptPreset) -> Void,
         onDelete: ((String) -> Void)? = nil) {
        self.originalPreset = preset
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: preset.name)
        _prompt = State(initialValue: preset.prompt)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("NAME")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)

                    if originalPreset.isBuiltin {
                        Text(name)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.vertical, Theme.Space.xs)
                    } else {
                        TextField("e.g. Code Reviewer, Translator", text: $name)
                            .font(.subheadline)
                            .textFieldStyle(.plain)
                            .padding(Theme.Space.sm)
                            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
                    }
                }

                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("PROMPT")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)

                    TextEditor(text: $prompt)
                        .font(.callout)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(minHeight: 260)
                        .scrollContentBackground(.hidden)
                        .padding(Theme.Space.xs)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))

                    Text("Keep it short — small models follow concise rules better than complex instructions.")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }

                if originalPreset.isBuiltin && !SystemPrompt.isStandard(prompt) {
                    Button("Reset to standard prompt") {
                        prompt = SystemPrompt.standard
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accent)
                }

                if !isNew && !originalPreset.isBuiltin {
                    Divider().background(Theme.hairline)

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Delete Preset")
                        }
                        .font(.subheadline)
                        .foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg)
        .navigationTitle(isNew ? "New Preset" : "Edit Preset")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let updated = SystemPromptPreset(
                        id: originalPreset.id,
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        prompt: prompt,
                        isBuiltin: originalPreset.isBuiltin
                    )
                    onSave(updated)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
        .alert("Delete Preset", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                onDelete?(originalPreset.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \"\(name)\"? This cannot be undone.")
        }
    }
}
