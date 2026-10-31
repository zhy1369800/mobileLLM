// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// Fixed-size (~1.2 KB newline-aligned) chunk of reasoning text so even a 15,000-word reasoning trace
/// produces only ~10 lightweight Text views instead of hundreds of per-line nodes during scrolling.
private struct ThinkingChunk: Identifiable, Equatable {
    let id: Int
    let text: String
}

private enum IncrementalThinkingSplitter {
    private static let chunkByteThreshold = 1_200
    private static let lock = NSLock()
    private static var cachedSourcePrefix: String = ""
    private static var cachedStableByteCount: Int = 0
    private static var cachedStableChunks: [ThinkingChunk] = []

    /// Splits reasoning text into ~1.2 KB blocks.
    /// Non-streaming (historical) traces use a pure stateless function so multiple thinking cards
    /// never contend for locks or thrash global cache. Live streaming traces incrementally reuse
    /// completed stable blocks and strictly verify full UTF-8 prefixes.
    static func split(text: String, isStreaming: Bool) -> [ThinkingChunk] {
        guard !text.isEmpty else { return [] }
        guard isStreaming else {
            return splitStatic(text)
        }

        lock.lock()
        defer { lock.unlock() }

        let totalBytes = text.utf8.count
        if totalBytes < cachedStableByteCount || !hasMatchingPrefix(text) {
            cachedSourcePrefix = ""
            cachedStableByteCount = 0
            cachedStableChunks.removeAll(keepingCapacity: true)
        }

        while true {
            let startIdx = text.utf8.index(text.utf8.startIndex, offsetBy: cachedStableByteCount)
            let unscanned = text[startIdx...]
            guard unscanned.utf8.count >= chunkByteThreshold else { break }

            let searchLimit = unscanned.index(
                unscanned.startIndex,
                offsetBy: 600,
                limitedBy: unscanned.endIndex
            ) ?? unscanned.endIndex
            let window = unscanned[..<searchLimit]

            if let newlineIdx = window.lastIndex(of: "\n"), newlineIdx > unscanned.startIndex {
                let chunkText = String(unscanned[..<newlineIdx])
                cachedStableChunks.append(ThinkingChunk(id: cachedStableChunks.count, text: chunkText))
                let afterNewline = unscanned.index(after: newlineIdx)
                cachedStableByteCount = text[..<afterNewline].utf8.count
                cachedSourcePrefix = String(text[..<afterNewline])
            } else if unscanned.utf8.count >= chunkByteThreshold * 2 {
                let cutIdx = unscanned.index(unscanned.startIndex, offsetBy: 600, limitedBy: unscanned.endIndex) ?? unscanned.endIndex
                let chunkText = String(unscanned[..<cutIdx])
                cachedStableChunks.append(ThinkingChunk(id: cachedStableChunks.count, text: chunkText))
                cachedStableByteCount = text[..<cutIdx].utf8.count
                cachedSourcePrefix = String(text[..<cutIdx])
            } else {
                break
            }
        }

        let tailStart = text.utf8.index(text.utf8.startIndex, offsetBy: cachedStableByteCount)
        let tail = String(text[tailStart...])
        var result = cachedStableChunks
        if !tail.isEmpty {
            result.append(ThinkingChunk(id: result.count, text: tail))
        }
        return result
    }

    /// Pure stateless chunker for finalized historical messages — zero locks, zero memory retention.
    private static func splitStatic(_ text: String) -> [ThinkingChunk] {
        guard text.utf8.count >= chunkByteThreshold else {
            return [ThinkingChunk(id: 0, text: text)]
        }
        var chunks: [ThinkingChunk] = []
        var remainder = text[...]
        while remainder.utf8.count >= chunkByteThreshold {
            let limit = remainder.index(
                remainder.startIndex,
                offsetBy: chunkByteThreshold,
                limitedBy: remainder.endIndex
            ) ?? remainder.endIndex
            let window = remainder[..<limit]
            if let newline = window.lastIndex(of: "\n"), newline > remainder.startIndex {
                chunks.append(ThinkingChunk(id: chunks.count, text: String(remainder[..<newline])))
                remainder = remainder[remainder.index(after: newline)...]
            } else {
                chunks.append(ThinkingChunk(id: chunks.count, text: String(remainder[..<limit])))
                remainder = remainder[limit...]
            }
        }
        if !remainder.isEmpty {
            chunks.append(ThinkingChunk(id: chunks.count, text: String(remainder)))
        }
        return chunks
    }

    private static func hasMatchingPrefix(_ text: String) -> Bool {
        guard cachedStableByteCount > 0 else { return true }
        guard text.utf8.count >= cachedStableByteCount else { return false }
        return text.utf8.starts(with: cachedSourcePrefix.utf8)
    }
}

private struct ThinkingChunkRow: View, Equatable {
    let text: String
    let selectable: Bool

    var body: some View {
        if selectable {
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The signature thinking disclosure (DESIGN §4): auto-expanded while `<think>` streams; auto-collapses
/// to "Thought for Ns" when the first answer token arrives; tap to re-read. Honors the Settings
/// display mode (auto-collapse / always-expand / hidden) and Reduce Motion.
struct ThinkingDisclosure: View {
    /// The live/streaming reasoning phase, or a completed turn's frozen duration.
    enum Phase: Equatable {
        case thinking                       // reasoning actively streaming
        case answered(seconds: Double?)     // answer has begun (live) / a finished message (nil = unknown)
    }

    let reasoning: String
    let phase: Phase
    let displayMode: ThinkingDisplayMode

    @State private var timeline: ThinkingTimeline

    init(reasoning: String, phase: Phase, displayMode: ThinkingDisplayMode) {
        self.reasoning = reasoning
        self.phase = phase
        self.displayMode = displayMode
        var initial = ThinkingTimeline()
        if !reasoning.isEmpty {
            switch phase {
            case .thinking:
                initial.onReasoning()
            case let .answered(seconds):
                initial.onReasoning()
                if let seconds { initial.restoreCompleted(seconds: seconds) }
                else { initial.onAnswerStart() }
            }
        }
        _timeline = State(initialValue: initial)
    }

    var body: some View {
        if displayMode == .hidden || reasoning.isEmpty {
            EmptyView()
        } else {
            content
                .onAppear { advance() }
                .onChange(of: reasoning) { _, _ in advance() }
                .onChange(of: phase) { _, _ in advance() }
        }
    }

    /// Synchronously projects `timeline` against the current `phase` during `body` evaluation so that
    /// transitioning `.thinking -> .answered` collapses on the VERY SAME frame rather than flashing
    /// one frame of full unthrottled `s.reasoning` before `.onChange(of: phase)` fires.
    private var effectiveTimeline: ThinkingTimeline {
        guard !reasoning.isEmpty else { return timeline }
        var updated = timeline
        switch phase {
        case .thinking:
            if !updated.hasReasoning { updated.onReasoning() }
        case let .answered(seconds):
            if updated.hasReasoning {
                updated.onAnswerStart(elapsed: seconds)
            } else {
                updated.onReasoning()
                if let seconds { updated.restoreCompleted(seconds: seconds) }
                else { updated.onAnswerStart() }
            }
        }
        return updated
    }

    private var isExpanded: Bool {
        displayMode == .alwaysExpand ? true : effectiveTimeline.isExpanded
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            header
            if isExpanded {
                let isStreaming = phase == .thinking
                let chunks = IncrementalThinkingSplitter.split(text: reasoning, isStreaming: isStreaming)
                let isDone = !isStreaming
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(chunks) { chunk in
                        ThinkingChunkRow(text: chunk.text, selectable: isDone)
                            .equatable()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Theme.Space.md)
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.accentSoft).frame(width: 2)
                }
                // Expose the unformatted reasoning as one coherent value once completed. Besides improving
                // VoiceOver, this gives physical-device tests a stable raw trace instead of a set of
                // renderer-dependent text fragments.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Assistant reasoning")
                .accessibilityValue(isDone ? reasoning : "")
                .accessibilityIdentifier("assistant.reasoning")
            }
        }
        .padding(Theme.Space.md)
        .background(Theme.surface2.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
    }

    private var header: some View {
        let current = effectiveTimeline
        return Button {
            withAnimation(Motion.spring) {
                var next = current
                next.toggle()
                timeline = next
            }
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "brain")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                Text(current.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                if displayMode != .alwaysExpand {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(displayMode == .alwaysExpand)
        .accessibilityLabel(current.label)
        .accessibilityHint(isExpanded ? "Collapse reasoning" : "Expand reasoning")
    }

    /// Drive the tested `ThinkingTimeline` from the current inputs.
    private func advance() {
        let updated = effectiveTimeline
        if updated != timeline {
            timeline = updated
        }
    }
}

#if DEBUG
#Preview("Thinking — collapsed") {
    ThinkingDisclosure(reasoning: "The user wants a haiku. I should count syllables: 5-7-5.",
                       phase: .answered(seconds: 4.2), displayMode: .autoCollapse)
    .padding()
    .background(Theme.bg)
}
#endif
