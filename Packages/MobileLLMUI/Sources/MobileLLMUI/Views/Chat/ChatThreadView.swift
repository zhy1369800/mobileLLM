// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import LLMCore
#if canImport(UIKit)
import UIKit
#endif

/// The message list + streaming surface (DESIGN §4). User turns are right-aligned bubbles; assistant
/// turns are full-width document text. History ALWAYS renders (a suspended/absent model never hides the
/// thread); a distinct loading state owns a cold-start load; sticky-bottom autoscroll with a "⌄ new"
/// pill when scrolled away.
struct ChatThreadView: View {
    let chat: ChatStore
    let displayMode: ThinkingDisplayMode
    /// A model is loading (cold start / switch) — shown as its own state, never as "no model".
    var isLoadingModel: Bool = false
    /// Best-effort name of the model being loaded (for the loading state).
    var loadingModelName: String = "your model"
    var onOpenModels: () -> Void
    /// Open the quick model switcher (the empty state's title is the picker).
    var onSwitchModel: () -> Void = {}
    /// The durable agent runtime projection surface; nil in legacy/preview layouts.
    var agentRuns: AgentRunStore? = nil

    @State private var atBottom = true
    @State private var editing: Message?
    @State private var editText = ""
    /// A mid-history regenerate awaiting confirmation (nil = none pending).
    @State private var regenTarget: Message?
    private let bottomID = "thread-bottom"

    private var conversation: Conversation? { chat.activeConversation }
    /// Stable across tokens (only flips at generation start/stop), so reading it here never makes the
    /// whole thread re-diff mid-stream — the live row observes `streaming` on its own.
    private var isBusy: Bool { chat.streamingMessageID != nil }

    var body: some View {
        Group {
            if let convo = conversation, !convo.messages.isEmpty {
                thread(convo)                                  // history first — never hidden by model state
            } else if isLoadingModel {
                centeredOrScrolling { ModelLoadingState(modelName: loadingModelName) }
            } else if !chat.hasModel {
                centeredOrScrolling { NoModelState(onOpenModels: onOpenModels) }
            } else {
                centeredOrScrolling {
                    EmptyChatState(modelName: chat.onlineModelID.map(OnlineModelIdentity.displayLabel)
                                   ?? chat.activeModel?.model.displayName ?? "your model",
                                   onExample: { prompt in
                                       chat.draft = prompt
                                       chat.send()
                                   },
                                   onSwitchModel: onSwitchModel,
                                   activeSkill: chat.activeSkill)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Tap anywhere in the thread AREA — every branch, including the suggestion/empty states, which
        // live outside the scroll view — to drop the keyboard. Simultaneous, so row buttons still work;
        // the composer is a sibling (safe-area inset), so focusing the field never self-dismisses.
        .simultaneousGesture(TapGesture().onEnded { Self.dismissKeyboard() })
        .sheet(item: $editing) { message in editSheet(message) }
        .alert("Regenerate this reply?",
               isPresented: Binding(get: { regenTarget != nil }, set: { if !$0 { regenTarget = nil } }),
               presenting: regenTarget) { message in
            let n = chat.discardedTurnCount(regeneratingFrom: message.id)
            Button("Discard \(n) later turn\(n == 1 ? "" : "s")", role: .destructive) {
                chat.regenerate(assistantMessageID: message.id)
                regenTarget = nil
            }
            Button("Cancel", role: .cancel) { regenTarget = nil }
        } message: { _ in
            Text("Regenerating an earlier reply removes every turn after it.")
        }
    }

    /// Center a placeholder (empty / loading / no-model) in the available height, but SCROLL instead of
    /// overflowing when that height is tight. With the keyboard up, the composer's safe-area inset shrinks
    /// this area by the keyboard's height; a plain centered VStack that's taller than what's left overflows
    /// symmetrically, and the top half draws OVER the nav bar — the reported "empty-state header on top of
    /// the model name". Pinning the content to at least the viewport height keeps it centered when there's
    /// room and lets it scroll (below the bar, never over it) when there isn't. Dragging also dismisses the
    /// keyboard, so the prompts a lifted keyboard covers are one swipe away.
    @ViewBuilder private func centeredOrScrolling<Content: View>(
        @ViewBuilder _ content: @escaping () -> Content) -> some View {
        GeometryReader { geo in
            ScrollView {
                content().frame(minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    // MARK: Thread

    private func thread(_ convo: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: Theme.Space.lg) {
                    ForEach(convo.messages) { message in
                        row(message).id(message.id)
                    }
                    if let agentRuns {
                        AgentRunPanelRow(store: agentRuns, conversationID: convo.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: Theme.Layout.readingColumn, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg)
            .onChange(of: convo.messages.count) { _, _ in
                // Only auto-follow when already at the bottom; yield unconditionally to user historical browsing
                if atBottom {
                    scrollToBottom(proxy, animated: false)
                }
            }
            .onChange(of: chat.activeID) { _, _ in
                scrollToBottom(proxy, animated: false)
                warmupCurrentConversation(convo)
            }
            .onAppear {
                scrollToBottom(proxy, animated: false)
                warmupCurrentConversation(convo)
            }
            .overlay(alignment: .bottom) {
                if !atBottom { scrollPill(proxy) }
            }
        }
    }

    private func warmupCurrentConversation(_ convo: Conversation) {
        let texts = convo.messages.compactMap { m -> String? in
            guard m.role == .assistant, !m.answer.isEmpty else { return nil }
            return m.answer
        }
        MarkdownBlockCache.warmup(texts: texts)
    }

    @ViewBuilder private func row(_ message: Message) -> some View {
        let isStreamingRow = message.id == chat.streamingMessageID
        MessageRowItem(
            message: message,
            isStreamingRow: isStreamingRow,
            isBusy: isBusy,
            displayMode: displayMode,
            thinkSeconds: completedThinkSeconds(message),
            onEdit: isBusy ? nil : { beginEdit(message) },
            onCopy: { Clipboard.copy(message.answer); chat.showToast(Toast("Copied")) },
            onRegenerate: isBusy ? nil : { requestRegenerate(message) },
            attachmentLoader: { await chat.attachmentData($0) },
            workflowStore: chat.workflowStore,
            activeID: chat.activeID,
            chat: chat
        )
        .equatable()
    }

    /// One-tap regenerate for the newest assistant turn; confirm first when regenerating an earlier one
    /// (it silently drops every turn after it — DESIGN §4, no unrecoverable surprise).
    private func requestRegenerate(_ message: Message) {
        guard let convo = conversation else { return }
        if chat.isLastAssistantMessage(message.id, in: convo) {
            chat.regenerate(assistantMessageID: message.id)
        } else {
            regenTarget = message
        }
    }

    /// A completed turn's thinking time — the persisted wall-clock when we have it, else estimated from
    /// stats (older records that predate `thinkingSeconds`).
    private func completedThinkSeconds(_ message: Message) -> Double? {
        if let s = message.thinkingSeconds, s > 0 { return s }
        guard let reasoning = message.reasoning, !reasoning.isEmpty,
              let tps = message.stats?.tokensPerSecond, tps > 0 else { return nil }
        return Double(max(1, reasoning.count / 4)) / tps
    }

    // MARK: Scroll-to-bottom pill

    private func scrollPill(_ proxy: ScrollViewProxy) -> some View {
        Button {
            atBottom = true
            scrollToBottom(proxy)
        } label: {
            Label(isBusy ? "New" : "Latest", systemImage: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.xs)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.bottom, Theme.Space.md)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityLabel("Scroll to latest")
    }

    /// Resign whatever is first responder (the composer field) — SwiftUI has no global "dismiss keyboard",
    /// and threading a FocusState binding up from the composer for one tap isn't worth the coupling.
    static func dismissKeyboard() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated && !Motion.reduce {
            withAnimation(Motion.canvas) { proxy.scrollTo(bottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
        atBottom = true
    }

    // MARK: Edit & resend

    private func beginEdit(_ message: Message) {
        editText = message.answer
        editing = message
    }

    private func editSheet(_ message: Message) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("Editing your message resends it and regenerates the reply.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                TextEditor(text: $editText)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minHeight: 140)
                    .padding(Theme.Space.sm)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                Spacer()
            }
            .padding(Theme.Space.lg)
            .background(Theme.bg)
            .navigationTitle("Edit message")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Resend") {
                        chat.editAndResend(userMessageID: message.id, newText: editText)
                        editing = nil
                    }
                    .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 280)
        #endif
    }
}

/// The single live assistant row — the ONLY view that observes the per-token `streaming` state, so the
/// rest of the thread stays put while it types. Reasoning is throttled to the same ~50 ms gate the
/// answer uses.
private struct StreamingRow: View {
    let chat: ChatStore
    let displayMode: ThinkingDisplayMode

    @State private var shownReasoning = ""
    @State private var targetReasoning = ""
    @State private var reasoningTicker: Task<Void, Never>?

    var body: some View {
        Group {
            if let s = chat.streaming {
                let modelName = s.generatedBy?.displayName ?? chat.activeModel?.model.displayName ?? "Model"
                if s.phase == .warming && !s.hasAnyContent {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        WarmingShimmer()
                        if let note = s.warmingNote {
                            Text(note).font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        AssistantView(
                            reasoning: displayedReasoning(s),
                            answer: s.answer,
                            disclosurePhase: s.phase == .thinking ? .thinking
                                : .answered(seconds: s.thinkingDuration),
                            displayMode: displayMode,
                            isStreaming: true,
                            stats: nil,
                            modelName: modelName,
                            toolRuns: s.toolActivity)
                        if let note = s.warmingNote {
                            HStack(spacing: Theme.Space.xs) {
                                ProgressView().controlSize(.small)
                                Text(note)
                            }
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .onAppear {
            let initial = chat.streaming?.reasoning ?? ""
            shownReasoning = initial
            targetReasoning = initial
        }
        .onChange(of: chat.streaming?.reasoning ?? "") { _, new in
            targetReasoning = new
            ensureReasoningTicker()
        }
        .onDisappear {
            reasoningTicker?.cancel()
            reasoningTicker = nil
        }
    }

    private func ensureReasoningTicker() {
        guard reasoningTicker == nil, shownReasoning != targetReasoning else { return }
        reasoningTicker = Task { @MainActor in
            while !Task.isCancelled {
                guard shownReasoning != targetReasoning else { break }
                shownReasoning = StreamingPacer.advance(visible: shownReasoning, toward: targetReasoning)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            reasoningTicker = nil
        }
    }

    /// Throttled while thinking; the full text once thinking ends, so the frozen block is exact.
    private func displayedReasoning(_ s: StreamingState) -> String {
        s.phase == .thinking ? shownReasoning : s.reasoning
    }
}

/// Isolated container for AgentRunPanel so observing `store.presentation` does not invalidate the entire ChatThreadView
private struct AgentRunPanelRow: View {
    let store: AgentRunStore
    let conversationID: UUID

    var body: some View {
        if let run = store.presentation(for: conversationID), run.needsPanel {
            AgentRunPanel(store: store, conversationID: conversationID)
                .id("agent-run-\(run.runID.description)")
        }
    }
}

/// Equatable message row to eliminate unnecessary re-renders of history cards during scrolling
private struct MessageRowItem: View, Equatable {
    let message: Message
    let isStreamingRow: Bool
    let isBusy: Bool
    let displayMode: ThinkingDisplayMode
    let thinkSeconds: Double?
    let onEdit: (() -> Void)?
    let onCopy: () -> Void
    let onRegenerate: (() -> Void)?
    let attachmentLoader: (ImageRef) async -> Data?
    let workflowStore: WorkflowStore?
    let activeID: UUID?
    let chat: ChatStore

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message.id == rhs.message.id &&
        lhs.message.answer == rhs.message.answer &&
        lhs.message.reasoning == rhs.message.reasoning &&
        lhs.isStreamingRow == rhs.isStreamingRow &&
        lhs.isBusy == rhs.isBusy &&
        lhs.displayMode == rhs.displayMode &&
        lhs.thinkSeconds == rhs.thinkSeconds &&
        lhs.message.stats == rhs.message.stats &&
        lhs.message.emptyOutcome == rhs.message.emptyOutcome &&
        lhs.message.toolRuns == rhs.message.toolRuns
    }

    var body: some View {
        if message.role == .user {
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                UserBubble(message: message,
                           onEdit: onEdit,
                           onCopy: onCopy,
                           attachmentLoader: attachmentLoader)
                if let workflow = message.workflowRecord {
                    NavigationLink {
                        WorkflowSummaryPage(
                            store: workflowStore,
                            conversationID: workflow.conversationID ?? activeID
                        )
                    } label: {
                        WorkflowMessageRow(record: workflow)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 360, alignment: .trailing)
                }
            }
        } else if isStreamingRow {
            StreamingRow(chat: chat, displayMode: displayMode)
        } else {
            AssistantView(
                reasoning: message.reasoning ?? "",
                answer: message.answer,
                disclosurePhase: .answered(seconds: thinkSeconds),
                displayMode: displayMode,
                isStreaming: false,
                stats: message.stats,
                modelName: message.generatedBy?.displayName ?? "Model",
                toolRuns: message.toolRuns ?? [],
                emptyOutcome: message.emptyOutcome,
                onCopy: onCopy,
                onRegenerate: onRegenerate)
        }
    }
}
