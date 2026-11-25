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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var showModelSwitcher = false
    @State private var showToolPicker = false
    @State private var showToolsSheet = false
    @State private var showSkillPicker = false
    @State private var showSkillsManage = false
    @State private var showBargeInSettings = false
    @State private var isSubtitleExpanded = false
    @State private var subtitleUserScrolledUp = false
    @State private var subtitleAtBottom = true
    @State private var isSubtitleDragging = false
    @State private var subtitleMatchCursor = 0
    @State private var lastAutoScrolledLine: Int? = nil
    @State private var subtitleContentHeight: CGFloat = 0
    @State private var subtitleViewportHeight: CGFloat = 0
    @State private var didCopySubtitle = false
    @State private var copyResetTask: Task<Void, Never>? = nil

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
        let showingExpandedSubtitle = isSubtitleExpanded
            && container.settings.showVoiceSubtitles
            && subtitleSource != .none

        return ZStack {
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

                if showingExpandedSubtitle {
                    Color.clear.frame(height: 8)
                } else {
                    Spacer(minLength: 12)
                }

                VoiceOrbView(
                    state: session.state,
                    isPaused: !session.isActive || !isVisible || scenePhase != .active,
                    levelProvider: { session.currentAudioLevel() },
                    onTap: handleOrbTap
                )
                .frame(
                    maxWidth: showingExpandedSubtitle ? 112 : 300,
                    maxHeight: showingExpandedSubtitle ? 112 : 300
                )
                .aspectRatio(1, contentMode: .fit)
                .layoutPriority(showingExpandedSubtitle ? 0 : 1)

                if showingExpandedSubtitle {
                    Color.clear.frame(height: 10)
                } else {
                    Spacer(minLength: 16)
                }

                statusAndSubtitleSection(expanded: showingExpandedSubtitle)
                    .padding(.horizontal, 24)
                    .frame(maxHeight: showingExpandedSubtitle ? .infinity : nil)

                if let agentRuns = container.agentRuns, let activeID = chat.activeID {
                    AgentDockedBar(store: agentRuns, conversationID: activeID)
                        .padding(.horizontal, Theme.Space.lg)
                        .padding(.top, Theme.Space.xs)
                }

                if showingExpandedSubtitle {
                    Color.clear.frame(height: 12)
                } else {
                    Spacer(minLength: 20)
                }

                bottomActionSection
                    .padding(.bottom, 24)
            }
        }
        .onChange(of: subtitleSource) { _, newSource in
            if newSource == .none {
                isSubtitleExpanded = false
                subtitleUserScrolledUp = false
                subtitleAtBottom = true
                subtitleMatchCursor = 0
                lastAutoScrolledLine = nil
                subtitleContentHeight = 0
                subtitleViewportHeight = 0
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
            copyResetTask?.cancel()
            copyResetTask = nil
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
        .sheet(isPresented: $showBargeInSettings) {
            NavigationStack {
                VoiceBargeInSettingsSheet(
                    settings: container.settings,
                    onChanged: { session.refreshBargeInSettings() }
                )
            }
            #if os(iOS)
            .presentationDetents([.medium])
            #else
            .frame(minWidth: 380, minHeight: 320)
            #endif
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

            Button {
                showBargeInSettings = true
            } label: {
                Label(bargeInMenuLabel, systemImage: "hand.raised")
            }

            if container.settings.showVoiceSubtitles {
                Toggle(isOn: Binding(
                    get: { container.settings.autoFollowVoiceSubtitles },
                    set: { newValue in
                        withAnimation(Motion.spring) {
                            container.settings.autoFollowVoiceSubtitles = newValue
                            if newValue {
                                subtitleUserScrolledUp = false
                            }
                        }
                    }
                )) {
                    Label("Auto-Follow", systemImage: "arrow.down.to.line")
                }
            }

            Menu("Language") {
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

    private var bargeInMenuLabel: String {
        switch container.settings.voiceBargeInMode {
        case .free:
            return "Barge-in: Free"
        case .keyword:
            let keywords = container.settings.parsedVoiceBargeInKeywords
            if keywords.isEmpty {
                return "Barge-in: Manual"
            }
            return "Barge-in: Keyword (\(keywords.count))"
        }
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

    private enum SubtitleSource: Equatable {
        case none
        case userListening
        case assistantThinking
        case assistantSpeaking
        case assistantPreviousTurn
    }

    private func statusAndSubtitleSection(expanded: Bool) -> some View {
        VStack(spacing: Theme.Space.md) {
            if let latestTool = session.activeToolRuns.last {
                toolActivityPill(latestTool)
            }

            if subtitleSource != .none && container.settings.showVoiceSubtitles {
                streamingSubtitleCard(expanded: expanded)
                    .frame(maxHeight: expanded ? .infinity : nil)
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

    private func streamingSubtitleCard(expanded: Bool) -> some View {
        let spokenSentence = activeSpokenSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFollowingSpokenAudio = (subtitleSource == .assistantSpeaking)
            && container.settings.autoFollowVoiceSubtitles
        let isFocusedSpokenMode = !expanded
            && isFollowingSpokenAudio
            && !spokenSentence.isEmpty
        let displayedText = isFocusedSpokenMode ? spokenSentence : subtitleText
        let lines = displayedText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let parseMarkdown = (subtitleSource != .userListening && !isFocusedSpokenMode)
        let progress: VoiceSubtitleProgressResult
        if isFocusedSpokenMode {
            progress = VoiceSubtitleProgressResult(
                emphases: Array(repeating: .active, count: lines.count),
                activeLineRange: lines.isEmpty ? nil : 0...(lines.count - 1),
                matchedStartOffset: nil
            )
        } else if isFollowingSpokenAudio && !spokenSentence.isEmpty {
            progress = VoiceSubtitleProgress.match(
                lines: lines,
                spokenSentence: spokenSentence,
                searchFrom: subtitleMatchCursor
            )
        } else {
            progress = VoiceSubtitleProgressResult(
                emphases: Array(repeating: .normal, count: lines.count),
                activeLineRange: nil,
                matchedStartOffset: nil
            )
        }
        let totalContentHeight = subtitleContentHeight + 6
        let collapsedSubtitleHeight: CGFloat? = subtitleContentHeight > 0
            ? min(max(totalContentHeight, 28), 116)
            : nil
        let focusedSpokenTransitionID = isFocusedSpokenMode ? "focused-\(spokenSentence)" : "stream"
        let subtitleSwapAnimation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.22)
        let isSubtitleOverflowing = subtitleViewportHeight > 0
            && totalContentHeight > subtitleViewportHeight + 2
        let shouldAutoScrollCurrent = !subtitleUserScrolledUp && !isSubtitleDragging

        return ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Space.xs) {
                    Circle()
                        .fill(subtitleBadgeColor)
                        .frame(width: 6, height: 6)
                    Text(subtitleBadgeTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)

                    Spacer()

                    Button {
                        copySubtitleText()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: didCopySubtitle ? "checkmark" : "doc.on.doc")
                            if didCopySubtitle {
                                Text("已复制")
                            }
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(didCopySubtitle ? Theme.fitGreen : Theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("复制字幕")

                    Button {
                        withAnimation(Motion.spring) {
                            isSubtitleExpanded.toggle()
                        }
                    } label: {
                        Image(
                            systemName: expanded
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right"
                        )
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "收起字幕" : "展开字幕")
                }
                .padding(.bottom, 6)

                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            VoiceSubtitleLineRow(
                                text: line.isEmpty ? " " : line,
                                parseMarkdown: parseMarkdown,
                                emphasis: progress.emphases.indices.contains(index) ? progress.emphases[index] : .normal,
                                reduceMotion: reduceMotion
                            )
                            .equatable()
                            .id("voice-subtitle-line-\(index)")
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("voice-subtitle-bottom")
                            .onAppear { subtitleAtBottom = true }
                            .onDisappear { subtitleAtBottom = false }
                    }
                    .id(focusedSpokenTransitionID)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 6)),
                                removal: .opacity.combined(with: .offset(y: -4))
                            )
                    )
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear {
                                    let h = geo.size.height
                                    if abs(subtitleContentHeight - h) > 0.5 {
                                        subtitleContentHeight = h
                                    }
                                }
                                .onChange(of: geo.size.height) { _, newHeight in
                                    if abs(subtitleContentHeight - newHeight) > 0.5 {
                                        subtitleContentHeight = newHeight
                                    }
                                }
                        }
                    )
                }
                .id(subtitleScrollScope(focusedSpoken: isFocusedSpokenMode))
                .contentMargins(.top, 6, for: .scrollContent)
                .scrollBounceBehavior(.basedOnSize)
                .frame(
                    minHeight: expanded ? 180 : collapsedSubtitleHeight,
                    maxHeight: expanded ? .infinity : (collapsedSubtitleHeight ?? 116)
                )
                .clipped()
                .animation(subtitleSwapAnimation, value: focusedSpokenTransitionID)
                .animation(subtitleSwapAnimation, value: collapsedSubtitleHeight)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                let h = geo.size.height
                                if abs(subtitleViewportHeight - h) > 0.5 {
                                    subtitleViewportHeight = h
                                }
                            }
                            .onChange(of: geo.size.height) { _, newHeight in
                                if abs(subtitleViewportHeight - newHeight) > 0.5 {
                                    subtitleViewportHeight = newHeight
                                }
                            }
                    }
                )
                .scrollIndicators(.hidden)
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 6)
                        Rectangle().fill(.black)
                    }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { value in
                            if !isSubtitleDragging { isSubtitleDragging = true }
                            guard !isFocusedSpokenMode, isSubtitleOverflowing else { return }
                            if isFollowingSpokenAudio {
                                if abs(value.translation.height) > 10 && !subtitleUserScrolledUp {
                                    subtitleUserScrolledUp = true
                                }
                            } else if value.translation.height > 6 && !subtitleUserScrolledUp {
                                subtitleUserScrolledUp = true
                            } else if value.translation.height < -16 && subtitleAtBottom && subtitleUserScrolledUp {
                                subtitleUserScrolledUp = false
                            }
                        }
                        .onEnded { value in
                            isSubtitleDragging = false
                            if !isFollowingSpokenAudio && value.translation.height < 0 && subtitleAtBottom && subtitleUserScrolledUp {
                                subtitleUserScrolledUp = false
                            }
                        }
                )
                .onChange(of: isSubtitleOverflowing) { _, overflowing in
                    if !overflowing && subtitleUserScrolledUp {
                        subtitleUserScrolledUp = false
                    }
                }
                .onAppear {
                    if isFocusedSpokenMode {
                        lastAutoScrolledLine = 0
                        proxy.scrollTo("voice-subtitle-line-0", anchor: .top)
                    } else if isFollowingSpokenAudio {
                        if let activeRange = progress.activeLineRange {
                            lastAutoScrolledLine = activeRange.lowerBound
                            proxy.scrollTo("voice-subtitle-line-\(activeRange.lowerBound)", anchor: .top)
                        }
                    } else {
                        proxy.scrollTo("voice-subtitle-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: subtitleText) { _, _ in
                    guard shouldAutoScrollCurrent, !isFocusedSpokenMode else { return }
                    if isFollowingSpokenAudio {
                        guard let activeRange = progress.activeLineRange else { return }
                        if lastAutoScrolledLine != activeRange.lowerBound {
                            lastAutoScrolledLine = activeRange.lowerBound
                            withAnimation(.easeOut(duration: 0.14)) {
                                proxy.scrollTo("voice-subtitle-line-\(activeRange.lowerBound)", anchor: .top)
                            }
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.10)) {
                            proxy.scrollTo("voice-subtitle-bottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: spokenSentence) { _, _ in
                    guard isFollowingSpokenAudio else { return }
                    if isFocusedSpokenMode {
                        subtitleUserScrolledUp = false
                        lastAutoScrolledLine = 0
                        withAnimation(.easeOut(duration: 0.14)) {
                            proxy.scrollTo("voice-subtitle-line-0", anchor: .top)
                        }
                        return
                    }
                    if let start = progress.matchedStartOffset, start != subtitleMatchCursor {
                        subtitleMatchCursor = start
                    }
                    guard shouldAutoScrollCurrent,
                          let activeRange = progress.activeLineRange
                    else { return }
                    lastAutoScrolledLine = activeRange.lowerBound
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("voice-subtitle-line-\(activeRange.lowerBound)", anchor: .top)
                    }
                }
                .onChange(of: subtitleSource) { oldSource, newSource in
                    if (oldSource == .userListening) != (newSource == .userListening) {
                        subtitleContentHeight = 0
                        subtitleViewportHeight = 0
                    }
                    if newSource == .none {
                        return
                    }
                    if oldSource == .assistantSpeaking && newSource == .assistantPreviousTurn {
                        if container.settings.autoFollowVoiceSubtitles {
                            subtitleUserScrolledUp = false
                        }
                        subtitleMatchCursor = 0
                        lastAutoScrolledLine = nil
                    } else if newSource == .assistantSpeaking && container.settings.autoFollowVoiceSubtitles {
                        subtitleUserScrolledUp = false
                        if isFocusedSpokenMode {
                            subtitleMatchCursor = 0
                            lastAutoScrolledLine = 0
                            proxy.scrollTo("voice-subtitle-line-0", anchor: .top)
                        } else if let activeRange = progress.activeLineRange {
                            subtitleMatchCursor = progress.matchedStartOffset ?? 0
                            lastAutoScrolledLine = activeRange.lowerBound
                            proxy.scrollTo("voice-subtitle-line-\(activeRange.lowerBound)", anchor: .top)
                        } else {
                            subtitleMatchCursor = 0
                            lastAutoScrolledLine = nil
                        }
                    } else {
                        subtitleUserScrolledUp = false
                        subtitleAtBottom = true
                        subtitleMatchCursor = 0
                        lastAutoScrolledLine = nil
                        proxy.scrollTo("voice-subtitle-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: container.settings.autoFollowVoiceSubtitles) { _, enabled in
                    guard subtitleSource != .userListening else { return }
                    subtitleUserScrolledUp = false
                    withAnimation(Motion.canvas) {
                        if enabled {
                            if isFocusedSpokenMode {
                                lastAutoScrolledLine = 0
                                proxy.scrollTo("voice-subtitle-line-0", anchor: .top)
                            } else if isFollowingSpokenAudio {
                                if let activeRange = progress.activeLineRange {
                                    lastAutoScrolledLine = activeRange.lowerBound
                                    proxy.scrollTo("voice-subtitle-line-\(activeRange.lowerBound)", anchor: .top)
                                }
                            } else {
                                subtitleAtBottom = true
                                proxy.scrollTo("voice-subtitle-bottom", anchor: .bottom)
                            }
                        } else {
                            subtitleMatchCursor = 0
                            lastAutoScrolledLine = nil
                            subtitleAtBottom = true
                            proxy.scrollTo("voice-subtitle-bottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isSubtitleExpanded) { _, isNowExpanded in
                    guard isNowExpanded,
                          subtitleSource == .assistantSpeaking,
                          container.settings.autoFollowVoiceSubtitles
                    else { return }
                    subtitleUserScrolledUp = false
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isFocusedSpokenMode
                        && subtitleUserScrolledUp
                        && isSubtitleOverflowing
                    {
                        Button {
                            subtitleUserScrolledUp = false
                            withAnimation(Motion.canvas) {
                                if isFollowingSpokenAudio,
                                   let activeRange = progress.activeLineRange
                                {
                                    lastAutoScrolledLine = activeRange.lowerBound
                                    proxy.scrollTo("voice-subtitle-line-\(activeRange.lowerBound)", anchor: .top)
                                } else {
                                    subtitleAtBottom = true
                                    proxy.scrollTo("voice-subtitle-bottom", anchor: .bottom)
                                }
                            }
                        } label: {
                            Label(
                                (isFollowingSpokenAudio && progress.activeLineRange != nil) ? "跟随朗读" : "最新",
                                systemImage: "chevron.down"
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.surface.opacity(0.95), in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                            .shadow(color: .black.opacity(0.10), radius: 4, y: 1)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 6)
                        .padding(.trailing, 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        .accessibilityLabel("回到当前字幕位置")
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
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        }
    }

    private func subtitleScrollScope(focusedSpoken: Bool) -> Int {
        if subtitleSource == .userListening { return 1 }
        return focusedSpoken ? 3 : 2
    }

    private var subtitleSource: SubtitleSource {
        switch session.state {
        case .listening:
            if !session.liveUserTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .userListening
            }
            if !session.liveAssistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .assistantPreviousTurn
            }
            return .none
        case .thinking:
            return session.liveAssistantText.isEmpty ? .none : .assistantThinking
        case .speaking:
            return session.liveAssistantText.isEmpty ? .none : .assistantSpeaking
        case .idle, .denied, .unavailable:
            return .none
        }
    }

    private var subtitleText: String {
        switch subtitleSource {
        case .userListening:
            return session.liveUserTranscript
        case .assistantThinking, .assistantSpeaking, .assistantPreviousTurn:
            return session.liveAssistantText
        case .none:
            return ""
        }
    }

    private var subtitleBadgeTitle: String {
        switch subtitleSource {
        case .userListening:
            return "我 · 正在说"
        case .assistantThinking:
            return "AI · 生成中"
        case .assistantSpeaking:
            return "AI · 朗读中"
        case .assistantPreviousTurn:
            return "AI · 上一句"
        case .none:
            return ""
        }
    }

    private var subtitleBadgeColor: Color {
        switch subtitleSource {
        case .userListening, .assistantSpeaking:
            return Theme.accent
        case .assistantThinking, .assistantPreviousTurn, .none:
            return Theme.textTertiary
        }
    }

    private var activeSpokenSentence: String {
        subtitleSource == .assistantSpeaking ? session.currentSpokenSentence : ""
    }

    private func copySubtitleText() {
        guard !subtitleText.isEmpty else { return }
        Clipboard.copy(subtitleText)
        didCopySubtitle = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            didCopySubtitle = false
        }
    }

    private var statusHintText: String {
        switch session.state {
        case .idle:
            guard chat.hasModel else { return "请先选择或加载一个模型" }
            if chat.isOnlineActive {
                return "点击下方按钮或水墨球体开始语音对话"
            }
            return "点击下方按钮或水墨球体开始语音对话\n本地模型需保持在前台对话，切后台将自动结束（云端模型支持灵动岛后台通话）"
        case .listening:
            return session.liveUserTranscript.isEmpty ? "我在听…" : "停顿后自动发送"
        case .thinking:
            return "让我想想…（点击球体可打断）"
        case .speaking:
            if session.isVerifyingBargeInKeyword {
                return "正在识别打断词…"
            }
            switch container.settings.voiceBargeInMode {
            case .free:
                return "随时打断（开口说话或点击球体）"
            case .keyword:
                let keywords = container.settings.parsedVoiceBargeInKeywords
                if keywords.isEmpty {
                    return "仅手动打断（点击球体）"
                } else if keywords.count <= 2 {
                    return "说「\(keywords.joined(separator: "」「"))」或点击球体打断"
                } else {
                    return "说「\(keywords.prefix(2).joined(separator: "」「"))」等关键词或点击球体打断"
                }
            }
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
    let emphasis: VoiceSubtitleLineEmphasis
    let reduceMotion: Bool

    var body: some View {
        renderedText
            .font(rowFont)
            .foregroundStyle(rowColor)
            .multilineTextAlignment(.leading)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: emphasis)
    }

    private var rowFont: Font {
        emphasis == .active ? .callout.weight(.medium) : .callout
    }

    private var rowColor: Color {
        switch emphasis {
        case .active:
            return Theme.textPrimary
        case .spoken:
            return Theme.textTertiary.opacity(0.75)
        case .upcoming, .normal:
            return Theme.textSecondary
        }
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

private struct VoiceBargeInSettingsSheet: View {
    @Bindable var settings: AppSettings
    var onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let parsedKeywords = settings.parsedVoiceBargeInKeywords

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Segmented(selection: $settings.voiceBargeInMode, options: VoiceBargeInMode.allCases) {
                    $0.voiceCallLabel
                }

                switch settings.voiceBargeInMode {
                case .free:
                    Text("AI 播报时直接开口说话或点击水墨球即可打断。")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)

                case .keyword:
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        HStack {
                            Text("打断关键词（英文逗号分隔）")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                            Spacer()
                            Menu {
                                Button("停一下,等等,打断") { settings.voiceBargeInKeywords = "停一下,等等,打断" }
                                Button("停,别说了,换个话题") { settings.voiceBargeInKeywords = "停,别说了,换个话题" }
                                Button("stop,wait,hold on") { settings.voiceBargeInKeywords = "stop,wait,hold on" }
                                if !settings.voiceBargeInKeywords.isEmpty {
                                    Divider()
                                    Button("清空（仅手动打断）", role: .destructive) {
                                        settings.voiceBargeInKeywords = ""
                                    }
                                }
                            } label: {
                                Text("常用词")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.accent)
                            }
                        }

                        TextField("多个关键词用英文逗号分隔，如：停一下,等等,stop", text: $settings.voiceBargeInKeywords)
                            .textFieldStyle(.roundedBorder)
                            .font(.subheadline)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()

                        if parsedKeywords.isEmpty {
                            Text("未填写关键词：当前仅支持点击水墨球手动打断")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                        } else {
                            Text("已生效关键词（\(parsedKeywords.count) 个）：\(parsedKeywords.joined(separator: " · "))")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .padding(Theme.Space.lg)
        }
        .background(Theme.bg)
        .navigationTitle("语音打断方式")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .onChange(of: settings.voiceBargeInMode) { _, _ in
            onChanged()
        }
        .onChange(of: settings.voiceBargeInKeywords) { _, _ in
            onChanged()
        }
    }
}
