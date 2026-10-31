// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
import LLMCore

/// A blinking caret shown at the tail of a streaming answer. Reduce-Motion → a steady bar.
struct TypingCaret: View {
    @State private var on = true
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.accent)
            .frame(width: 8, height: 16)
            .opacity(on ? 1 : 0.15)
            .onAppear {
                guard !Motion.reduce else { on = true; return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { on = false }
            }
            .accessibilityHidden(true)
    }
}

/// The user turn — a right-aligned accent bubble (DESIGN §4), with any attached image thumbnails stacked
/// above the text. An image-only turn (no text) shows just the thumbnails.
struct UserBubble: View {
    let message: Message
    var onEdit: (() -> Void)?
    var onCopy: (() -> Void)?
    /// Loads a committed attachment's bytes from the store (nil on the previews/paths that don't render them).
    var attachmentLoader: ((ImageRef) async -> Data?)?

    private var attachments: [ImageRef] { message.attachments ?? [] }

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                if !attachments.isEmpty, let attachmentLoader {
                    AttachmentThumbnails(refs: attachments, load: attachmentLoader)
                }
                if !message.answer.isEmpty {
                    Text(message.answer)
                        .font(.body)
                        .foregroundStyle(Theme.onAccent)
                        .textSelection(.enabled)
                        .padding(.horizontal, Theme.Space.md)
                        .padding(.vertical, Theme.Space.sm)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .contextMenu {
                            Button { onCopy?() } label: { Label("Copy", systemImage: "doc.on.doc") }
                            if onEdit != nil {
                                Button { onEdit?() } label: { Label("Edit & resend", systemImage: "pencil") }
                            }
                        }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You said")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard !attachments.isEmpty else { return message.answer }
        let noun = attachments.count == 1 ? "attached image" : "\(attachments.count) attached images"
        return message.answer.isEmpty ? noun : "\(noun). \(message.answer)"
    }
}

/// The image attachments on a user turn — one thumbnail up to ~200pt, or a 2-up grid for several.
struct AttachmentThumbnails: View {
    let refs: [ImageRef]
    let load: (ImageRef) async -> Data?

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Space.xs),
                            count: refs.count == 1 ? 1 : 2)
        LazyVGrid(columns: columns, alignment: .trailing, spacing: Theme.Space.xs) {
            ForEach(refs) { ref in
                AttachmentThumbnail(ref: ref, load: load)
            }
        }
        .frame(maxWidth: refs.count == 1 ? 200 : 220)
    }
}

/// One attachment thumbnail — loads its bytes lazily from the store, decodes, and renders rounded.
struct AttachmentThumbnail: View {
    let ref: ImageRef
    let load: (ImageRef) async -> Data?
    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                Rectangle().fill(Theme.surface2)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
        .task(id: ref.id) {
            guard image == nil else { return }
            // Asynchronous disk write may take 10-50ms after the turn is appended to the message list.
            // Retry with a short backoff so the freshly sent image renders as soon as it lands on disk.
            for attempt in 0..<15 {
                if let data = await load(ref), let decoded = Image(attachmentData: data) {
                    image = decoded
                    break
                }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: attempt == 0 ? 50_000_000 : 100_000_000)
            }
        }
        .accessibilityLabel("attached image")
    }
}

/// Pure display policy for a tool run. A memory's canonical English sentence is internal data: chat shows
/// whether it was saved, while Settings → Memory remains the transparent, editable source of truth.
struct ToolActivityPresentation: Equatable {
    enum State: Equatable { case running, succeeded, failed }

    let state: State
    let title: String
    let detail: String?
    let accessibilityLabel: String

    init(run: ToolRun) {
        if run.name == ToolID.remember.rawValue {
            if run.result == nil {
                state = .running
                title = "Saving to memory…"
            } else if run.result.map(Self.isFailureResult) == true {
                state = .failed
                title = "Couldn't save to memory"
            } else if run.result == "Already in memory." {
                state = .succeeded
                title = "Already in memory"
            } else {
                state = .succeeded
                title = "Saved to memory"
            }
            detail = nil
            accessibilityLabel = title
            return
        }

        let prettyName = run.name.replacingOccurrences(of: "_", with: " ").capitalized
        let summary = Self.argumentSummary(run.arguments)
        let invocation = prettyName + (summary.isEmpty ? "" : "(\(summary))")
        if let result = run.result {
            let failed = Self.isFailureResult(result)
            state = failed ? .failed : .succeeded
            title = failed ? "\(invocation) failed" : invocation
            detail = "→ \(result)"
            accessibilityLabel = failed ? "\(prettyName) failed. \(result)" : "\(prettyName) returned \(result)"
        } else {
            state = .running
            title = "Using \(prettyName)…"
            detail = nil
            accessibilityLabel = "Using \(prettyName)"
        }
    }

    /// Tools intentionally report recoverable failures as strings so the model can correct its call. Keep
    /// that transport contract, but do not paint those results with a green success seal in chat.
    private static func isFailureResult(_ result: String) -> Bool {
        let normalized = result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("error:")
            || normalized.hasPrefix("tool error:")
            || (normalized.hasPrefix("mcp tool ") && normalized.contains(" failed:"))
            || normalized.hasPrefix("couldn't ")
            || normalized.hasPrefix("search failed")
            || normalized.hasPrefix("web search failed")
            || normalized.hasPrefix("calendar access is off")
            || normalized.hasPrefix("reminders access is off")
            || normalized.hasPrefix("location access is off")
            || normalized.hasPrefix("location is unavailable")
    }

    private static func argumentSummary(_ arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !obj.isEmpty else { return "" }
        return obj.map { "\($0.value)" }.joined(separator: ", ")
    }
}

/// A single tool the assistant invoked — a running spinner while it works, the seal (✓) + result when
/// it returns. Tapping the row opens a bottom sheet with complete arguments and results.
struct ToolActivityRow: View {
    let run: ToolRun
    var onSelect: (() -> Void)? = nil
    @State private var showingDetail = false

    var body: some View {
        let presentation = ToolActivityPresentation(run: run)
        Button {
            if let onSelect {
                onSelect()
            } else {
                showingDetail = true
            }
        } label: {
            HStack(spacing: Theme.Space.sm) {
                if presentation.state == .running {
                    ProgressView().controlSize(.mini).tint(Theme.accent)
                } else {
                    Image(systemName: presentation.state == .failed
                          ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(presentation.state == .failed ? Theme.danger : Theme.accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(presentation.title)
                        .font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    if let detail = presentation.detail {
                        Text(detail).font(.caption2.monospaced()).foregroundStyle(Theme.textTertiary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier("assistant.tool.run")
        .sheet(isPresented: Binding(
            get: { onSelect == nil && showingDetail },
            set: { showingDetail = $0 }
        )) {
            ToolDetailSheet(run: run)
        }
    }
}

enum ToolFormatting {
    static func prettyJSON(orRaw raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: prettyData, encoding: .utf8)
        else {
            return raw
        }
        return str
    }
}

/// Bottom sheet detail view for a tool execution, inspired by Kelivo.
/// Displays pretty-printed arguments and result in scrollable, selectable blocks with one-tap copy.
struct ToolDetailSheet: View {
    let run: ToolRun
    @State private var copiedArguments = false
    @State private var copiedResult = false

    private var prettyArguments: String {
        ToolFormatting.prettyJSON(orRaw: run.arguments)
    }

    private var prettyResult: String? {
        run.result.map { ToolFormatting.prettyJSON(orRaw: $0) }
    }

    private var displayName: String {
        run.name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    sectionBlock(
                        title: "Arguments",
                        content: prettyArguments,
                        isCopied: copiedArguments,
                        onCopy: {
                            Clipboard.copy(prettyArguments)
                            copiedArguments = true
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                copiedArguments = false
                            }
                        }
                    )

                    if let result = prettyResult {
                        sectionBlock(
                            title: "Result",
                            content: result,
                            isCopied: copiedResult,
                            onCopy: {
                                Clipboard.copy(result)
                                copiedResult = true
                                Task {
                                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                                    copiedResult = false
                                }
                            }
                        )
                    } else {
                        runningBlock
                    }
                }
                .padding(Theme.Space.md)
            }
            .background(Theme.bg)
            .navigationTitle(displayName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif

        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 400)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private func sectionBlock(
        title: String,
        content: String,
        isCopied: Bool,
        onCopy: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(action: onCopy) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "Copied" : "Copy")
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isCopied ? Theme.accent : Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }

            Text(content.isEmpty ? "(Empty)" : content)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.sm)
                .background(Theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                        .strokeBorder(Theme.hairline)
                )
        }
    }

    private var runningBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Result")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: Theme.Space.sm) {
                ProgressView().controlSize(.small).tint(Theme.accent)
                Text("Executing tool…")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.sm)
            .background(Theme.surface2)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .strokeBorder(Theme.hairline)
            )
        }
    }
}

/// A committed assistant turn that produced no answer — the user tapped Stop, or generation failed.
/// A compact, honest row with a working Retry, in place of the old "0 tok · stop: cancelled" ghost.
struct EmptyReplyRow: View {
    let outcome: Message.EmptyOutcome
    var onRetry: (() -> Void)?

    private var label: String {
        switch outcome {
        case .stopped: "Stopped"
        case .noReply: "The model didn't reply"
        case .failed: "Couldn't generate a reply"
        }
    }
    private var icon: String { outcome == .stopped ? "stop.circle" : "exclamationmark.triangle" }
    private var tint: Color { outcome == .stopped ? Theme.textTertiary : Theme.danger }

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: icon).font(.caption).foregroundStyle(tint)
            Text(label).font(.subheadline).foregroundStyle(Theme.textSecondary)
            if let onRetry {
                Button { onRetry() } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.md).padding(.vertical, Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
        // Retry is an action, not descriptive text. Keep it independently focusable for VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// Lifted modal state for assistant messages, preventing multiple sheet collision in a single view node.
enum AssistantModalSheet: Identifiable {
    case tool(ToolRun)
    case image(PlatformImage, Data, String?)

    var id: String {
        switch self {
        case .tool(let run):
            return "tool_\(run.id)"
        case .image(_, let data, let alt):
            return "image_\(alt ?? "")_\(data.count)"
        }
    }
}

/// The assistant turn — full-width document text (no bubble) so markdown + code read cleanly
/// (DESIGN §4). Drives the thinking disclosure, an optional streaming caret, and a quiet action bar.
struct AssistantView: View {
    let reasoning: String
    let answer: String
    let disclosurePhase: ThinkingDisclosure.Phase
    let displayMode: ThinkingDisplayMode
    let isStreaming: Bool
    let stats: Stats?
    let modelName: String
    var toolRuns: [ToolRun] = []
    /// Set when a completed turn produced no answer (stopped / failed) — renders the Retry row instead of
    /// a ghost stats line.
    var emptyOutcome: Message.EmptyOutcome?
    var onCopy: (() -> Void)?
    var onRegenerate: (() -> Void)?

    @State private var activeModalSheet: AssistantModalSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if !reasoning.isEmpty {
                ThinkingDisclosure(reasoning: reasoning, phase: disclosurePhase, displayMode: displayMode)
            }
            if !toolRuns.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(toolRuns) { run in
                        ToolActivityRow(run: run) {
                            activeModalSheet = .tool(run)
                        }
                    }
                }
            }
            if !answer.isEmpty {
                answerBody
            } else if !isStreaming, let emptyOutcome {
                // Interrupted/failed before the first token: an honest, retryable row — not a "0 tok" ghost.
                EmptyReplyRow(outcome: emptyOutcome, onRetry: onRegenerate)
            } else if isStreaming && reasoning.isEmpty {
                // Warming: nothing to show yet — the composer owns the shimmer; keep a caret anchor.
                HStack(spacing: 4) { TypingCaret() }
            }
            if !isStreaming, let stats {
                statsFooter(stats)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.onPreviewMarkdownImage) { image, data, alt in
            activeModalSheet = .image(image, data, alt)
        }
        .sheet(item: $activeModalSheet) { sheet in
            switch sheet {
            case .tool(let run):
                ToolDetailSheet(run: run)
            case .image(let image, let data, let alt):
                MarkdownImageViewerSheet(image: image, rawData: data, alt: alt)
            }
        }
    }

    private var answerBody: some View {
        Group {
            if isStreaming {
                // Streaming: throttled markdown (~20 fps) with an inline block caret riding the tail —
                // a separate caret view can't sit at the end of block-rendered markdown, so the glyph is
                // appended to the text itself.
                StreamingMarkdown(text: answer)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Assistant answer")
                    .accessibilityIdentifier("assistant.answer")
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    MarkdownMessage(text: answer)
                        // Markdown rendering may consume underscores or split one answer into several
                        // accessibility nodes. Keep the exact raw answer available as one value.
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Assistant answer")
                        .accessibilityValue(answer)
                        .accessibilityIdentifier("assistant.answer")
                    actionBar
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: Theme.Space.md) {
            if let onCopy {
                Button { onCopy() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel("Copy answer")
            }
            if let onRegenerate {
                Button { onRegenerate() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel("Regenerate answer")
            }
            Spacer()
        }
        .font(.caption)
        .padding(.top, 2)
    }

    private func statsFooter(_ stats: Stats) -> some View {
        Text(Format.statsFooter(stats, modelName: modelName))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Theme.textTertiary)
            .accessibilityLabel("Generation stats")
            .accessibilityValue(Format.statsFooter(stats, modelName: modelName))
            .accessibilityIdentifier("assistant.stats")
    }
}
