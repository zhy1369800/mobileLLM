// SPDX-License-Identifier: MIT

import SwiftUI
import Combine
import AppUI
import LLMCore

/// Settings (DESIGN §4): assistant, models/connections, conversation/reasoning, generation/engine,
/// app/system, data & privacy, and about. Section/row builders in a clean studio style.
struct SettingsView: View {
    let container: AppContainer
    @Bindable var settings: AppSettings
    @State private var confirmDeleteChats = false
    @State private var confirmEraseAll = false
    @State private var eraseError: String?
    @State private var storageBytes: Int64 = 0
    @State private var showTools = false
    @State private var showSystemPrompt = false
    @State private var showSkills = false
    @State private var showMemory = false
    @State private var showOpenAI = false
    @State private var showShortcuts = false
    @State private var showLocalLogs = false

    init(container: AppContainer) {
        self.container = container
        self._settings = Bindable(wrappedValue: container.settings)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                assistantSection
                modelsSection
                conversationSection
                samplingSection
                systemSection
                privacySection
                aboutSection
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(Theme.Space.xl)
        }
        .background(Theme.bg)
        .task {
            storageBytes = await container.conversationStore.storageBytes()
            await container.localModelLogs.reloadAsync()
        }
        .alert("Delete all chats?", isPresented: $confirmDeleteChats) {
            Button("Delete all chats", role: .destructive) { deleteAllChats() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every conversation and image attachment on this device. Models, memory, skills, "
                 + "settings, and MCP credentials are kept. This can't be undone.")
        }
        .alert("Erase all app data?", isPresented: $confirmEraseAll) {
            Button("Erase everything", role: .destructive) { eraseAllAppData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Returns mobileLLM to a fresh install. It permanently removes chats and attachments, "
                 + "memory, custom skills, settings, MCP credentials, community-model records, and every "
                 + "downloaded model. Calendar events or reminders already created outside the app are "
                 + "not changed. This can't be undone.")
        }
        .alert("Some data wasn't erased",
               isPresented: Binding(get: { eraseError != nil },
                                    set: { if !$0 { eraseError = nil } })) {
            Button("OK", role: .cancel) { eraseError = nil }
        } message: {
            Text(eraseError ?? "Try the erase again.")
        }
        // A sheet, not a push: the macOS detail column isn't inside a NavigationStack.
        .sheet(isPresented: $showTools) {
            NavigationStack {
                ToolsView(settings: settings,
                          eventStore: container.toolEventStore,
                          locationProvider: container.toolLocationProvider,
                          shortcutExecutor: container.toolShortcutExecutor)
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #endif
        }
        .sheet(isPresented: $showSystemPrompt) {
            NavigationStack { SystemPromptManagementView(settings: settings) }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 520)
            #endif
        }
        .sheet(isPresented: $showSkills) {
            NavigationStack { SkillsView(store: container.skills) }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #endif
        }
        .sheet(isPresented: $showMemory) {
            NavigationStack { MemoryView(book: container.memory, settings: settings) }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #endif
        }
        .sheet(isPresented: $showOpenAI) {
            NavigationStack {
                OnlineServicesView(settings: settings, store: container.openAICredentials)
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 440)
            #endif
        }
        .sheet(isPresented: $showShortcuts) {
            NavigationStack {
                ShortcutsServicesSheet(settings: settings)
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 440)
            #endif
        }
        .sheet(isPresented: $showLocalLogs) {
            NavigationStack {
                LocalModelLogsView(logStore: container.localModelLogs)
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #endif
        }
    }

    /// One-line status for the system-prompt row: the active preset and preview.
    private var systemPromptSummary: String {
        let preset = settings.selectedSystemPromptPreset
        let text = preset.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "\(preset.name) · Off" }
        if preset.isBuiltin && SystemPrompt.isStandard(text) { return "Standard prompt" }
        let preview = text.replacingOccurrences(of: "\n", with: " ").prefix(40)
        return "\(preset.name) · \(preview)"
    }

    // MARK: Model

    // There is deliberately NO "default model" or "engine preference" here anymore: conversations
    // remember their own model, an explicitly opened thread restores its choice, and a new chat uses the
    // last-used identity. Launch restores that identity without loading weights and leaves history
    // unselected. `settings.defaultModelID` is the auto-tracked fallback, never user-facing.

    // MARK: Assistant & Capabilities

    private var assistantSection: some View {
        section("Assistant & Capabilities", icon: "sparkles") {
            // A row, not an inline editor — the full-height TextEditor ate half the settings screen.
            navRow("System prompt", subtitle: systemPromptSummary, icon: "text.quote") {
                showSystemPrompt = true
            }
            hairline
            navRow("Skills", subtitle: SkillsView.summary(for: container.skills), icon: "sparkles") {
                showSkills = true
            }
            hairline
            navRow("Memory", subtitle: MemoryView.summary(book: container.memory, settings: settings), icon: "bookmark") {
                showMemory = true
            }
            // The count comes from a mirror of the durable store; a chat that saved a fact while Settings was
            // on screen must not leave the row reading "Nothing saved yet".
            .task { await container.memory.refresh() }
            hairline
            toggleRow("Allow selected tools", isOn: $settings.toolsEnabled)
            hairline
            navRow("Choose tools", subtitle: ToolsView.summary(for: settings), icon: "wrench.and.screwdriver") {
                showTools = true
            }
        }
    }

    // MARK: Models & Connections

    private var modelsSection: some View {
        section("Models & Connections", icon: "network") {
            navRow("Online services", subtitle: onlineSummary, icon: "key.horizontal") {
                showOpenAI = true
            }
            .accessibilityLabel("Online services")
            .accessibilityValue("\(settings.onlineServices.count) services")
            hairline
            navRow("Shortcuts models", subtitle: shortcutsSummary, icon: "command") {
                showShortcuts = true
            }
            .accessibilityLabel("Shortcuts models")
            .accessibilityValue("\(settings.shortcutsServices.count) models")
            hairline
            toggleRow(
                "Use domestic mirror for models",
                subtitle: "Accelerate model downloads via hf-mirror.com.",
                isOn: $settings.useHuggingFaceMirror
            )
        }
    }

    private var onlineSummary: String {
        if let service = settings.onlineActiveService {
            return "\(settings.onlineServices.count) service\(settings.onlineServices.count == 1 ? "" : "s") · On · \(service.name)"
        }
        if settings.onlineServices.isEmpty {
            return "No services configured"
        }
        return "\(settings.onlineServices.count) service\(settings.onlineServices.count == 1 ? "" : "s") · Off"
    }

    private var shortcutsSummary: String {
        let count = settings.shortcutsServices.count
        if count == 0 {
            return "No shortcut models configured"
        }
        return "\(count) shortcut model\(count == 1 ? "" : "s")"
    }

    // MARK: Conversation & Reasoning

    private var conversationSection: some View {
        section("Conversation & Reasoning", icon: "text.bubble") {
            toggleRow("Thinking mode by default", isOn: $settings.thinkingDefault)
            VStack(alignment: .leading, spacing: 6) {
                Text("Show reasoning").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Segmented(selection: $settings.thinkingDisplay, options: ThinkingDisplayMode.allCases) { $0.label }
            }
            hairline
            toggleRow("Auto-compact conversations", isOn: $settings.autoCompactionEnabled)
            if settings.autoCompactionEnabled {
                compactionModelPickerRow
            }
            hairline
            contextRow
        }
    }

    private var isCompactionTargetMissing: Bool {
        !settings.isCompactionTargetAvailable
    }

    private var compactionModelLabel: String {
        switch settings.compactionModelTarget {
        case .followCurrent:
            return "Follow active model"
        case .shortcut(let id):
            if let svc = settings.shortcutsServices.first(where: { $0.id == id }) {
                return svc.name
            }
            return "Shortcut missing (reselect)"
        case .online(let serviceID):
            if let svc = settings.onlineServices.first(where: { $0.id == serviceID }) {
                return svc.name.isEmpty ? (svc.modelID ?? "Online API") : svc.name
            }
            return "Online service missing (reselect)"
        }
    }

    @ViewBuilder private var compactionModelPickerRow: some View {
        HStack {
            Text("Compaction model").font(.subheadline).foregroundStyle(Theme.textSecondary)
            Spacer()
            Menu {
                if isCompactionTargetMissing {
                    Button(role: .destructive) {
                        settings.compactionModelTarget = .followCurrent
                    } label: {
                        Label("Target unavailable — tap to reset", systemImage: "exclamationmark.triangle")
                    }
                    Divider()
                }

                Button {
                    settings.compactionModelTarget = .followCurrent
                } label: {
                    if settings.compactionModelTarget == .followCurrent {
                        Label("Follow active model", systemImage: "checkmark")
                    } else {
                        Text("Follow active model")
                    }
                }

                if !settings.shortcutsServices.isEmpty {
                    Divider()
                    ForEach(settings.shortcutsServices) { service in
                        Button {
                            settings.compactionModelTarget = .shortcut(id: service.id)
                        } label: {
                            let isSelected = settings.compactionModelTarget == .shortcut(id: service.id)
                            if isSelected {
                                Label("Shortcut: \(service.name)", systemImage: "checkmark")
                            } else {
                                Text("Shortcut: \(service.name)")
                            }
                        }
                    }
                }

                if !settings.onlineServices.isEmpty {
                    Divider()
                    ForEach(settings.onlineServices) { service in
                        Button {
                            settings.compactionModelTarget = .online(serviceID: service.id)
                        } label: {
                            let title = service.name.isEmpty ? (service.modelID ?? "Online") : service.name
                            let isSelected = settings.compactionModelTarget == .online(serviceID: service.id)
                            if isSelected {
                                Label("Online: \(title)", systemImage: "checkmark")
                            } else {
                                Text("Online: \(title)")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if isCompactionTargetMissing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                    }
                    Text(compactionModelLabel)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .foregroundStyle(isCompactionTargetMissing ? Color.orange : Theme.accent)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var localModelLogsRow: some View {
        navRow("Local model request logs", subtitle: localLogsSummary, icon: "doc.text.magnifyingglass") {
            showLocalLogs = true
        }
    }

    private var localLogsSummary: String {
        let count = container.localModelLogs.entries.count
        return count == 0 ? "No logs recorded" : "\(count) logged"
    }

    // MARK: Generation & Engine

    private var samplingSection: some View {
        section("Generation & Engine", icon: "slider.horizontal.3") {
            sliderRow("Temperature", value: $settings.temperature, range: 0...1.5, step: 0.05, format: "%.2f")
            hairline
            sliderRow("Top-p", value: $settings.topP, range: 0...1, step: 0.01, format: "%.2f")
            hairline
            stepperRow("Max tokens", value: $settings.maxTokens, range: 128...4096, step: 128)
            hairline
            HStack {
                Text("Thinking budget").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                Menu {
                    ForEach([256, 512, 1_024, 2_048, 4_096], id: \.self) { value in
                        Button("\(value) tokens") { settings.thinkingBudget = value }
                    }
                    Divider()
                    Button("Auto (up to Max tokens)") { settings.thinkingBudget = 0 }
                } label: {
                    menuLabel(settings.thinkingBudget == 0 ? "Auto" : "\(settings.thinkingBudget)")
                }
                .fixedSize()
            }
            if settings.openAIOnlineEnabled {
                hairline
                HStack {
                    Text("Online max output").font(.subheadline).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Menu {
                        Button("Auto (model max)") { settings.onlineMaxTokens = 0 }
                        Divider()
                        ForEach([512, 1_024, 2_048, 4_096, 8_192, 16_384, 32_768, 65_536],
                                id: \.self)
                        { value in
                            Button("\(value)") { settings.onlineMaxTokens = value }
                        }
                    } label: {
                        menuLabel(settings.onlineMaxTokens == 0 ? "Auto" : "\(settings.onlineMaxTokens)")
                    }
                    .fixedSize()
                }
            }
            hairline
            DisclosureGroup("Advanced & Diagnostics") {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    stepperRow("Top-k", value: $settings.topK, range: 0...100, step: 5)
                    hairline
                    sliderRow("Repetition penalty", value: $settings.repetitionPenalty, range: 1...1.5, step: 0.01, format: "%.2f")
                    hairline
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("KV cache").font(.subheadline).foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Menu {
                                Button("Full (unquantized)") { settings.kvBits = 0 }
                                Button("4-bit") { settings.kvBits = 4 }
                                Button("6-bit (K4+V8)") { settings.kvBits = 6 }
                                Button("8-bit") { settings.kvBits = 8 }
                            } label: {
                                menuLabel(settings.kvBits == 0 ? "Full"
                                     : settings.kvBits == 6 ? "6-bit (K4+V8)"
                                     : "\(settings.kvBits)-bit")
                            }
                            .fixedSize()
                        }
                        Text("8-bit recommended (balanced quality & RAM); 4-bit saves memory.")
                            .font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                    hairline
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Speculative decoding").font(.subheadline).foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Menu {
                                Button(SpeculativeMode.off.displayName) { settings.speculativeMode = .off }
                                Button(SpeculativeMode.promptLookup.displayName) { settings.speculativeMode = .promptLookup }
                                Button(SpeculativeMode.mtp.displayName) { settings.speculativeMode = .mtp }
                            } label: {
                                menuLabel(settings.speculativeMode.displayName)
                            }
                            .fixedSize()
                        }
                        Text("Accelerates generation speed via draft token speculation.")
                            .font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                    hairline
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Prefill Batch").font(.subheadline).foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Menu {
                                ForEach([256, 512, 1_024], id: \.self) { value in
                                    Button("\(value)") { settings.prefillBatchSize = value }
                                }
                            } label: {
                                menuLabel("\(settings.prefillBatchSize)")
                            }
                            .fixedSize()
                        }
                        Text("Larger batch speeds up prompt evaluation but increases peak memory.")
                            .font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                    hairline
                    toggleRow(
                        "KV Checkpoints",
                        subtitle: "Cache KV snapshots to disk for instant multi-turn editing reuse.",
                        isOn: $settings.kvCheckpointsEnabled
                    )
                    hairline
                    toggleRow("Record local model logs", isOn: $settings.localModelLoggingEnabled)
                    localModelLogsRow
                }
                .padding(.top, Theme.Space.sm)
            }
            .tint(Theme.accent)
        }
    }

    // MARK: Context length

    /// Context is only meaningful **relative to a model**: the ladder stops at what the default model was
    /// trained for, and each rung carries the fit dot for this device — because the ceiling that actually
    /// binds is RAM, not the checkpoint. (A 9B trained to 256K still only fits ~16K on an 8 GB phone.)
    @ViewBuilder private var contextRow: some View {
        let online = container.chat.isOnlineActive
        let model = contextModel
        let options = online
            ? OnlineModelIdentity.contextLadder
            : (model.map { ContextPolicy.options(for: $0) } ?? ContextPolicy.ladder)
        let shown = online
            ? min(settings.onlineContextLength, OnlineModelIdentity.maximumContextTokens)
            : (model.map { ContextPolicy.effective(requested: settings.contextLength, model: $0) }
                ?? settings.contextLength)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Context length").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                Menu {
                    ForEach(options, id: \.self) { n in
                        Button {
                            if online { settings.onlineContextLength = n } else { settings.contextLength = n }
                        } label: {
                            // The dot is the point: it says which rungs this device can actually hold.
                            Label(Format.shortCount(n), systemImage: fitSymbol(n))
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(Format.shortCount(shown)).font(.subheadline).foregroundStyle(Theme.accent)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .fixedSize()
            }
            Text(contextFootnote).font(.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    /// The model the ladder is measured against — whatever a new chat will actually load (adopted too).
    private var contextModel: LLMModel? {
        container.models.active?.model ?? container.models.model(id: settings.defaultModelID)
    }

    /// Green / amber / red per rung. `.tight` alone isn't the answer — it's returned both for "runs, but
    /// deep into the budget" and for "that context is way over the ceiling", so ask `ContextPolicy.fits`.
    private func fitSymbol(_ n: Int) -> String {
        // Online inference owns no device KV cache: every rung up to the service window fits.
        if container.chat.isOnlineActive { return "circle.fill" }
        guard let model = contextModel else { return "circle" }
        let device = container.models.device
        let variant = AppSettings.preferredVariant(for: model, device: device,
                                                   preference: settings.enginePreference, context: n)
        if LLMMemoryGovernor.plan(model: model, variant: variant, device: device, context: n) == .comfortable {
            return "circle.fill"
        }
        return ContextPolicy.fits(model: model, variant: variant, device: device, context: n)
            ? "exclamationmark.circle" : "xmark.circle"
    }

    private var contextFootnote: String {
        if container.chat.isOnlineActive {
            return "Longer context uses more tokens on the service."
        }
        return "Longer context uses more memory and increases initial latency."
    }

    // MARK: App & System

    private var systemSection: some View {
        section("App & System", icon: "gearshape") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Appearance").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Segmented(selection: $settings.appearance, options: AppearanceMode.allCases) { $0.label }
            }
            #if os(iOS)
            hairline
            toggleRow(
                "Keep screen awake",
                subtitle: "Prevent the device from sleeping while mobileLLM is in the foreground.",
                isOn: $settings.keepScreenAwake
            )
            hairline
            toggleRow(
                "Continue work in background (iOS 26)",
                subtitle: "Keep active generation runs processing after leaving the app.",
                isOn: Binding(
                    get: { settings.continuedProcessingEnabled },
                    set: { newValue in
                        settings.continuedProcessingEnabled = newValue
                        container.continuedProcessing.setEnabled(
                            newValue,
                            activeConversationID: container.chat.activeID
                        )
                    }
                )
            )
            if let status = continuedProcessingStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(continuedProcessingHasError ? Theme.danger : Theme.textTertiary)
            }
            hairline
            toggleRow(
                "Quick notification assistant",
                subtitle: "Interactive notification for multi-turn chat when in background.",
                isOn: Binding(
                    get: { settings.quickNotificationEnabled },
                    set: { newValue in
                        settings.quickNotificationEnabled = newValue
                        if newValue {
                            Task { await QuickNotificationCoordinator.requestAuthorization() }
                        } else {
                            QuickNotificationCoordinator.dismissNotification()
                        }
                    }
                )
            )
            hairline
            toggleRow(
                "Picture-in-Picture floating window",
                subtitle: "Floating window showing live thinking and response.",
                isOn: Binding(
                    get: { settings.pipWindowEnabled },
                    set: { newValue in
                        settings.pipWindowEnabled = newValue
                        PiPCoordinator.shared.setEnabled(newValue)
                        if !newValue {
                            PiPCoordinator.shared.stopPiP()
                        }
                    }
                )
            )
            #endif
        }
    }

    #if os(iOS)
    private var continuedProcessingStatus: String? {
        let coordinator = container.continuedProcessing
        switch coordinator.phase {
        case .idle, .finished:
            return nil
        case .submitted:
            return "Waiting for the system to grant continued processing…"
        case .running:
            return "A run is continuing in the background; the system shows its progress."
        case .rejected(let diagnostic):
            return "Not started: \(diagnostic)"
        case .expired:
            return "The system ended background processing; the run is paused and can be resumed."
        case .cancelled:
            return "Background continuation was cancelled."
        }
    }

    private var continuedProcessingHasError: Bool {
        switch container.continuedProcessing.phase {
        case .rejected, .expired, .cancelled: true
        case .idle, .submitted, .running, .finished: false
        }
    }
    #endif

    // MARK: Data & Privacy

    private var privacySection: some View {
        section("Data & Privacy", icon: "lock.shield") {
            Text(privacyBlurb)
                .font(.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            row("Conversations on disk", Format.bytes(storageBytes))
            Divider().background(Theme.hairline)
            Button { Task { await exportAll() } } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline).foregroundStyle(Theme.accent).frame(width: 22)
                    Text("Export all chats").font(.subheadline).foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().background(Theme.hairline)
            Button(role: .destructive) { confirmDeleteChats = true } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "trash")
                        .font(.subheadline).foregroundStyle(Theme.danger).frame(width: 22)
                    Text("Delete all chats").font(.subheadline).foregroundStyle(Theme.danger)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().background(Theme.hairline)
            Button { confirmEraseAll = true } label: {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "externaldrive.badge.xmark")
                        .font(.subheadline).foregroundStyle(Theme.accent).frame(width: 22)
                    Text("Erase all data").font(.subheadline).foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var privacyBlurb: String {
        let base = "Your chats, prompts, and models stay on this device — no account and no telemetry."
        var additions: [String] = []
        if settings.toolsEnabled {
            additions.append("Tools allow the model to query external sources (web search, Wikipedia, MCP, system calendars) when explicitly invoked.")
        }
        if !settings.onlineServices.isEmpty {
            additions.append("Online model requests are sent to configured provider endpoints.")
        }
        guard !additions.isEmpty else { return base }
        return base + " " + additions.joined(separator: " ")
    }

    // MARK: About

    private var aboutSection: some View {
        section("About", icon: "info.circle") {
            row("Version", appVersion)
            hairline
            row("Engine", "MLX · LLaMA")
            hairline
            Text("A private, open-source LLM & agent runner for iOS and macOS.")
                .font(.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    // MARK: Actions

    private func deleteAllChats() {
        Task {
            do {
                try await container.deleteAllChats()
                storageBytes = await container.conversationStore.storageBytes()
                container.chat.showToast(Toast("All chats and attachments deleted", kind: .success))
            } catch {
                container.chat.showToast(Toast("Chats couldn't be deleted: \(error.localizedDescription)",
                                               kind: .error, autoDismiss: nil))
            }
        }
    }

    private func eraseAllAppData() {
        Task {
            do {
                try await container.eraseAllAppData()
                storageBytes = 0
                container.chat.showToast(Toast("All mobileLLM data erased", kind: .success))
            } catch {
                eraseError = error.localizedDescription
                storageBytes = await container.conversationStore.storageBytes()
            }
        }
    }

    private func exportAll() async {
        // MVP export: copy a JSON bundle of every chat to the clipboard. File/share export is TODO(v1.0).
        let convos = await container.conversationStore.loadAllLive()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(convos), let json = String(data: data, encoding: .utf8) {
            Clipboard.copy(json)
            container.chat.showToast(Toast("Copied \(convos.count) chats as JSON", kind: .success))
        }
    }

    // MARK: Builders

    private var hairline: some View {
        Divider().background(Theme.hairline)
    }

    private func navRow(
        _ title: String,
        subtitle: String? = nil,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: icon)
                    .font(.subheadline).foregroundStyle(Theme.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline).foregroundStyle(Theme.textPrimary)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            if let subtitle {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline).foregroundStyle(Theme.textPrimary)
                    Text(subtitle).font(.caption).foregroundStyle(Theme.textTertiary)
                }
            } else {
                Text(title).font(.subheadline).foregroundStyle(Theme.textPrimary)
            }
        }
        .tint(Theme.accent)
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.subheadline).foregroundStyle(Theme.accent)
            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(Theme.textTertiary)
        }
    }

    private func sectionLabel(_ title: String, icon: String) -> some View {
        Label { Text(title.uppercased()) } icon: { Image(systemName: icon) }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.textTertiary)
            .accessibilityAddTraits(.isHeader)
    }

    private func section(_ title: String, icon: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            sectionLabel(title, icon: icon)
            VStack(alignment: .leading, spacing: Theme.Space.md) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .studioCard()
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Text(key).font(.subheadline).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Theme.Space.md)
            Text(value).font(.subheadline).foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(key).accessibilityValue(value)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           step: Double, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.textPrimary)
            }
            Slider(value: value, in: range, step: step).tint(Theme.accent)
                .accessibilityLabel(title)
                .accessibilityValue(String(format: format, value.wrappedValue))
        }
    }

    private func stepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(value.wrappedValue)").font(.caption.monospacedDigit()).foregroundStyle(Theme.textPrimary)
            }
        }
        .accessibilityValue("\(value.wrappedValue)")
    }
}

private struct ShortcutsServicesSheet: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var newShortcutName = ""
    @State private var newShortcutTarget = ""
    @FocusState private var isFieldFocused: Bool

    private var canAdd: Bool {
        !newShortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !newShortcutTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            Section {
                if settings.shortcutsServices.isEmpty {
                    Text("No shortcut models configured.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(settings.shortcutsServices) { service in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Shortcut: \(service.shortcutName)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                settings.removeShortcutsService(id: service.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.danger)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: {
                Text("Configured Models")
            }

            Section {
                TextField("Model name (e.g. 豆包)", text: $newShortcutName)
                    .focused($isFieldFocused)
                TextField("Shortcut (e.g. 发消息问豆包)", text: $newShortcutTarget)
                    .focused($isFieldFocused)
                Button {
                    addModel()
                } label: {
                    Label("Add Model", systemImage: "plus")
                }
                .disabled(!canAdd)
            } header: {
                Text("Add Shortcut Model")
            } footer: {
                Text("Passes message in 'msg' (and image in 'fileName') to this shortcut, with automatic tool calling loop support.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Shortcuts Models")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func addModel() {
        let name = newShortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = newShortcutTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !target.isEmpty else { return }
        settings.upsertShortcutsService(ShortcutsService(name: name, shortcutName: target))
        newShortcutName = ""
        newShortcutTarget = ""
        isFieldFocused = false
    }
}

#if os(macOS)
/// The content of the macOS Settings scene (⌘,). Public so the App's `Settings { }` scene can host the
/// (internal) `SettingsView` with the app's tint + appearance applied. `NavigationStack` gives the sheets
/// it presents (MCP servers) a bar to hang their Done button on.
public struct MacSettingsWindow: View {
    private let container: AppContainer
    public init(container: AppContainer) { self.container = container }
    public var body: some View {
        NavigationStack {
            SettingsView(container: container)
        }
        .frame(minWidth: 480, minHeight: 560)
        .tint(Theme.accent)
        .background(Theme.bg)
        .preferredColorScheme(container.settings.appearance.colorScheme)
    }
}
#endif

#if DEBUG
#Preview("Settings") {
    SettingsView(container: AppContainer.preview())
}
#endif
