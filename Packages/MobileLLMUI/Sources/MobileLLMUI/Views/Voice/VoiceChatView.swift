// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// Full-screen real-time voice conversation view styled with mobileLLM's ink-wash palette (水墨).
/// Pushed natively onto `NavigationStack` like `ChatDetailView` so interactive pop swipe-back
/// and tab-bar hiding behave identically to the chat thread.
public struct VoiceChatView: View {
    @Bindable var container: AppContainer
    var onOpenModels: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var showModelSwitcher = false
    @State private var showToolPicker = false
    @State private var showToolsSheet = false
    @State private var showSkillPicker = false
    @State private var showSkillsManage = false

    public init(container: AppContainer, onOpenModels: @escaping () -> Void) {
        self.container = container
        self.onOpenModels = onOpenModels
    }

    private var session: VoiceChatSession { container.voiceChat }
    private var chat: ChatStore { container.chat }

    private var thinkingCapable: Bool {
        chat.isOnlineActive || (chat.activeModel?.model.architecture.thinkingCapable ?? true)
    }

    public var body: some View {
        ZStack {
            // Adaptive ink-wash background: warm rice-paper (light) / wet ink night (dark).
            Theme.bg
                .ignoresSafeArea()

            RadialGradient(
                colors: [Theme.surface.opacity(0.45), .clear],
                center: .center,
                startRadius: 20,
                endRadius: 340
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                if !chat.activeSkills.isEmpty {
                    activeSkillChips
                        .padding(.horizontal, Theme.Space.lg)
                        .padding(.top, Theme.Space.xs)
                }

                Spacer(minLength: 12)

                VoiceOrbView(
                    state: session.state,
                    isPaused: !session.isActive || !isVisible || scenePhase != .active,
                    levelProvider: { session.currentAudioLevel() },
                    onTap: handleOrbTap
                )
                .frame(maxWidth: 300, maxHeight: 300)
                .aspectRatio(1, contentMode: .fit)

                Spacer(minLength: 16)

                statusAndSubtitleSection
                    .padding(.horizontal, 24)

                if let agentRuns = container.agentRuns, let activeID = chat.activeID {
                    AgentDockedBar(store: agentRuns, conversationID: activeID)
                        .padding(.horizontal, Theme.Space.lg)
                        .padding(.top, Theme.Space.xs)
                }

                Spacer(minLength: 20)

                bottomActionSection
                    .padding(.bottom, 24)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) { modelHeader }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if session.isActive {
                        session.stop()
                    }
                    _ = chat.newConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New voice conversation")
            }
            ToolbarItem(placement: .primaryAction) { optionsMenu }
        }
        .onAppear {
            isVisible = true
            session.isScreenVisible = true
        }
        .onDisappear {
            isVisible = false
            session.isScreenVisible = false
        }
        .sheet(isPresented: $showModelSwitcher) {
            ModelSwitcherSheet(container: container, onOpenModels: onOpenModels)
        }
        .sheet(isPresented: $showToolPicker) {
            NavigationStack {
                QuickToolsPickerSheet(
                    chat: chat,
                    settings: container.settings,
                    toolEventStore: container.toolEventStore,
                    toolLocationProvider: container.toolLocationProvider,
                    toolShortcutExecutor: container.toolShortcutExecutor,
                    onOpenToolSettings: { showToolsSheet = true },
                    onDone: { showToolPicker = false }
                )
            }
            #if os(iOS)
                .presentationDetents([.medium, .large])
            #else
                .frame(minWidth: 420, minHeight: 460)
            #endif
        }
        .sheet(isPresented: $showToolsSheet) {
            NavigationStack {
                ToolsView(
                    settings: container.settings,
                    eventStore: container.toolEventStore,
                    locationProvider: container.toolLocationProvider,
                    shortcutExecutor: container.toolShortcutExecutor
                )
                #if os(macOS)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showToolsSheet = false }
                    }
                }
                #endif
            }
        }
        .sheet(isPresented: $showSkillPicker) {
            NavigationStack {
                QuickSkillsPickerSheet(
                    chat: chat,
                    onManageSkills: { showSkillsManage = true },
                    onDone: { showSkillPicker = false }
                )
            }
            #if os(iOS)
                .presentationDetents([.medium, .large])
            #else
                .frame(minWidth: 420, minHeight: 440)
            #endif
        }
        .sheet(isPresented: $showSkillsManage) {
            if let store = chat.skillStore {
                NavigationStack { SkillsView(store: store) }
                #if os(macOS)
                    .frame(minWidth: 520, minHeight: 560)
                #endif
            }
        }
    }

    // MARK: - Toolbar Controls

    private var modelHeader: some View {
        Button { showModelSwitcher = true } label: {
            HStack(spacing: 4) {
                Circle().fill(chat.hasModel ? Theme.fitGreen : Theme.fitGray).frame(width: 6, height: 6)
                Text(chat.activeModelLabel)
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(Theme.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Active model")
        .accessibilityValue(chat.activeModel?.subtitle ?? "No model loaded")
        .accessibilityHint("Switch model")
    }

    private var optionsMenu: some View {
        let capabilitiesActive = chat.toolsEnabled
            || (thinkingCapable && chat.composerThinkingEnabled)
            || !chat.activeSkills.isEmpty

        return Menu {
            if thinkingCapable {
                Toggle(isOn: Binding(
                    get: { chat.composerThinkingEnabled },
                    set: { chat.composerThinkingEnabled = $0 }
                )) {
                    Label("Thinking", systemImage: "brain")
                }
            }

            Button {
                showToolPicker = true
            } label: {
                Label("Tools", systemImage: "wrench.and.screwdriver")
            }

            if chat.skillStore != nil {
                Button {
                    showSkillPicker = true
                } label: {
                    let count = chat.activeSkills.count
                    Label(count > 0 ? "Skills (\(count))" : "Skills", systemImage: "sparkles")
                }
            }

            Divider()

            Menu("Dictation Language") {
                ForEach(Composer.dictationLanguages, id: \.label) { lang in
                    Button {
                        chat.dictationLocale = lang.id
                    } label: {
                        if chat.dictationLocale == lang.id {
                            Label(lang.label, systemImage: "checkmark")
                        } else {
                            Text(lang.label)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: capabilitiesActive ? "slider.horizontal.3" : "ellipsis.circle")
                .foregroundStyle(capabilitiesActive ? Theme.accent : Theme.textSecondary)
        }
        .accessibilityLabel("Voice call options")
    }

    // MARK: - Active Skill Chips

    private var activeSkillChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.xs) {
                ForEach(chat.activeSkills) { skill in
                    HStack(spacing: Theme.Space.xs) {
                        Text(skill.emoji).font(.caption).accessibilityHidden(true)
                        Text(skill.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                        Button {
                            chat.removeActiveSkill(skill.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Theme.accent, Theme.accentSoft)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Deactivate \(skill.name)")
                    }
                    .padding(.leading, Theme.Space.sm)
                    .padding(.trailing, Theme.Space.xs)
                    .padding(.vertical, Theme.Space.xs)
                    .background(Theme.accentSoft, in: Capsule())
                }
            }
        }
    }

    // MARK: - Status, Tool Capsules & Live Subtitles

    private var statusAndSubtitleSection: some View {
        VStack(spacing: Theme.Space.md) {
            if let latestTool = session.activeToolRuns.last {
                toolActivityPill(latestTool)
            }

            if !subtitleText.isEmpty {
                streamingSubtitleCard
            }

            Text(statusHintText)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(minHeight: 90)
    }

    private func toolActivityPill(_ tool: ToolRun) -> some View {
        HStack(spacing: 6) {
            if tool.result == nil {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.accent)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.fitGreen)
            }
            Text(tool.name)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private var streamingSubtitleCard: some View {
        let lines = subtitleText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let parseMarkdown = (session.state != .listening)

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        VoiceSubtitleLineRow(
                            text: line.isEmpty ? " " : line,
                            parseMarkdown: parseMarkdown
                        )
                        .equatable()
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("voice-subtitle-bottom")
                }
                .padding(.top, 8)
            }
            .frame(maxHeight: 116)
            .scrollIndicators(.hidden)
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 10)
                    Rectangle().fill(.black)
                }
            )
            .onAppear {
                proxy.scrollTo("voice-subtitle-bottom", anchor: .bottom)
            }
            .onChange(of: subtitleText) { _, _ in
                withAnimation(.easeOut(duration: 0.10)) {
                    proxy.scrollTo("voice-subtitle-bottom", anchor: .bottom)
                }
            }
        }
        .padding(.leading, Theme.Space.md)
        .overlay(alignment: .leading) {
            Capsule().fill(Theme.accentSoft).frame(width: 2)
        }
        .padding(Theme.Space.md)
        .background(
            Theme.surface2.opacity(0.5),
            in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
        )
    }

    private var subtitleText: String {
        switch session.state {
        case .listening:
            return session.liveUserTranscript
        case .thinking, .speaking:
            return session.liveAssistantText
        case .idle, .denied, .unavailable:
            return ""
        }
    }

    private var statusHintText: String {
        switch session.state {
        case .idle:
            return chat.hasModel ? "点击下方按钮或水墨球体开始语音对话" : "请先选择或加载一个模型"
        case .listening:
            return session.liveUserTranscript.isEmpty ? "我在听…" : "停顿后自动发送"
        case .thinking:
            return "让我想想…（点击球体可打断）"
        case .speaking:
            return "随时打断（开口说话或点击球体）"
        case .denied:
            return "请在系统设置中允许麦克风与语音识别权限"
        case .unavailable:
            return "当前语言或设备暂不支持离线语音识别"
        }
    }

    // MARK: - Bottom Action Controls

    private var bottomActionSection: some View {
        Group {
            if session.isActive {
                Button {
                    session.stop()
                } label: {
                    Text("结束")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(
                            Theme.danger,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End voice call")
            } else {
                Button {
                    session.start()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                        Text("开始语音对话")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!chat.hasModel)
                .opacity(chat.hasModel ? 1.0 : 0.45)
                .accessibilityLabel("Start voice call")
            }
        }
    }

    // MARK: - Interactions

    private func handleOrbTap() {
        switch session.state {
        case .speaking, .thinking:
            session.interruptAndListen()
        case .idle, .denied, .unavailable:
            if chat.hasModel {
                session.start()
            } else {
                showModelSwitcher = true
            }
        case .listening:
            break
        }
    }
}

private struct VoiceSubtitleLineRow: View, Equatable {
    let text: String
    let parseMarkdown: Bool

    var body: some View {
        renderedText
            .font(.callout)
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.leading)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var renderedText: some View {
        if !parseMarkdown {
            Text(text)
        } else if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
        } else {
            Text(text)
        }
    }
}
