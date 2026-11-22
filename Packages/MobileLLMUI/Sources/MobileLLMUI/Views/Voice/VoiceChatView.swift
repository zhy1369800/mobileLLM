// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// Full-screen immersive real-time voice conversation view (Phase 1).
/// Integrates directly with `ChatStore` (models, tools, thinking, conversation history)
/// and `VoiceChatSession` (full-duplex audio, VAD endpointing, barge-in).
public struct VoiceChatView: View {
    @Bindable var container: AppContainer
    var onOpenModels: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var showModelSwitcher = false
    @State private var showToolsSheet = false

    public init(container: AppContainer, onOpenModels: @escaping () -> Void) {
        self.container = container
        self.onOpenModels = onOpenModels
    }

    private var session: VoiceChatSession { container.voiceChat }
    private var chat: ChatStore { container.chat }

    public var body: some View {
        ZStack {
            // Deep obsidian backdrop matching the immersive voice call mode.
            Color(red: 0.04, green: 0.04, blue: 0.06)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

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
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                Spacer(minLength: 20)

                bottomActionSection
                    .padding(.bottom, 24)
            }
        }
        .environment(\.colorScheme, .dark)
        #if os(iOS)
        .toolbarColorScheme(.dark, for: .tabBar)
        #endif
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .sheet(isPresented: $showModelSwitcher) {
            ModelSwitcherSheet(container: container, onOpenModels: onOpenModels)
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
    }

    // MARK: - Top Control Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                if session.isActive {
                    session.stop()
                }
                _ = chat.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New voice conversation")

            Spacer()

            Button {
                showModelSwitcher = true
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(chat.hasModel ? Color.green : Color.gray)
                        .frame(width: 7, height: 7)
                    Text(chat.activeModelLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch model")

            Spacer()

            Menu {
                Toggle(isOn: Binding(
                    get: { chat.toolsEnabled },
                    set: { chat.toolsEnabled = $0 }
                )) {
                    Label("Enable Tools", systemImage: "wrench.and.screwdriver")
                }

                Button {
                    showToolsSheet = true
                } label: {
                    Label("Configure Tools & MCP…", systemImage: "slider.horizontal.3")
                }

                Divider()

                Toggle(isOn: Binding(
                    get: { chat.thinkingEnabled },
                    set: { chat.thinkingEnabled = $0 }
                )) {
                    Label("Thinking Mode", systemImage: "brain")
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
                Image(systemName: chat.toolsEnabled ? "wrench.and.screwdriver.fill" : "ellipsis.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(chat.toolsEnabled ? Color(red: 0.42, green: 0.90, blue: 0.72) : .white.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .accessibilityLabel("Voice call options")
        }
    }

    // MARK: - Status, Tool Capsules & Live Subtitles

    private var statusAndSubtitleSection: some View {
        VStack(spacing: 12) {
            if let latestTool = session.activeToolRuns.last {
                toolActivityPill(latestTool)
            }

            if !subtitleText.isEmpty {
                ScrollView {
                    Text(subtitleText)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: 110)
                .scrollIndicators(.hidden)
            }

            Text(statusHintText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(minHeight: 90)
    }

    private func toolActivityPill(_ tool: ToolRun) -> some View {
        HStack(spacing: 6) {
            if tool.result == nil {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white.opacity(0.85))
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.42, green: 0.90, blue: 0.72))
            }
            Text(tool.name)
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white.opacity(0.12), in: Capsule())
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
            return chat.hasModel ? "点击下方按钮或球体开始语音对话" : "请先选择或加载一个模型"
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
                        .foregroundStyle(.white)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 10)
                        .background(Color(red: 0.86, green: 0.22, blue: 0.24), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!chat.hasModel)
                .opacity(chat.hasModel ? 1.0 : 0.5)
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
