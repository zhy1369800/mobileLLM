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
    private var fileAttachments: [FileAttachment] { message.fileAttachments ?? [] }

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                if !attachments.isEmpty, let attachmentLoader {
                    AttachmentThumbnails(refs: attachments, load: attachmentLoader)
                }
                if !fileAttachments.isEmpty {
                    FileAttachmentPills(files: fileAttachments)
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
        var parts: [String] = []
        if !attachments.isEmpty {
            parts.append(attachments.count == 1 ? "attached image" : "\(attachments.count) attached images")
        }
        if !fileAttachments.isEmpty {
            parts.append(fileAttachments.map(\.fileName).joined(separator: ", "))
        }
        if !message.answer.isEmpty {
            parts.append(message.answer)
        }
        return parts.joined(separator: ", ")
    }
}

private struct FileAttachmentPills: View {
    let files: [FileAttachment]

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(files) { file in
                HStack(spacing: 6) {
                    Image(systemName: file.fileExtension == "pdf" ? "doc.richtext" : "doc.text")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                    Text(file.fileName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if file.isTruncated {
                        Text("\(file.retainedPercent)%")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, Theme.Space.sm)
                .padding(.vertical, 6)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
            }
        }
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
            } else if run.result.map({ Self.isFailureResult($0.prefix(256)) }) == true {
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
            let failed = Self.isFailureResult(result.prefix(256))
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
    private static func isFailureResult(_ result: Substring) -> Bool {
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
    var stackCount: Int? = nil
    var onSelect: (() -> Void)? = nil
    @State private var showingDetail = false

    private func displaySubtitle(for presentation: ToolActivityPresentation) -> String {
        if let detail = presentation.detail {
            let snippet = detail.prefix(256).replacingOccurrences(of: "\n", with: " ")
            return snippet.isEmpty ? " " : snippet
        }
        return presentation.state == .running ? "Executing…" : " "
    }

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
                Group {
                    if presentation.state == .running {
                        ProgressView().controlSize(.mini).tint(Theme.accent)
                    } else {
                        Image(systemName: presentation.state == .failed
                              ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(presentation.state == .failed ? Theme.danger : Theme.fitGreen)
                    }
                }
                .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Text(displaySubtitle(for: presentation))
                        .font(.caption2.monospaced())
                        .foregroundStyle(presentation.state == .running ? Theme.textTertiary.opacity(0.8) : Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let count = stackCount {
                    HStack(spacing: 3) {
                        Text("\(count)")
                            .font(.caption2.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
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

/// An iOS lock-screen-notification style stacked container for multiple tool invocations.
/// When collapsed (default for >= 2 tools), displays the top card with adaptive stacked cards behind it and a count badge.
/// Tapping it expands into the full list with a smooth spring animation.
struct StackedToolActivityView: View {
    let runs: [ToolRun]
    var onSelect: (ToolRun) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if runs.count <= 1 {
                if let single = runs.first {
                    ToolActivityRow(run: single) {
                        onSelect(single)
                    }
                }
            } else if isExpanded {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(runs) { run in
                        ToolActivityRow(run: run) {
                            onSelect(run)
                        }
                    }
                }
                .transition(.opacity)

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        isExpanded = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up")
                            .font(.caption2.weight(.bold))
                        Text("Fold \(runs.count) tools")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Space.sm)
                    .padding(.vertical, 4)
                    .background(Theme.surface2, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
            } else {
                let displayRun = runs.first(where: { $0.result == nil }) ?? runs.last ?? runs[0]
                let hiddenRuns = runs.filter { $0.id != displayRun.id }
                ToolActivityRow(run: displayRun, stackCount: runs.count) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        isExpanded = true
                    }
                }
                .background {
                    ZStack {
                        ForEach(hiddenRuns) { hiddenRun in
                            Color.clear
                                .frame(width: 0, height: 0)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(ToolActivityPresentation(run: hiddenRun).accessibilityLabel)
                                .accessibilityIdentifier("assistant.tool.run")
                        }
                        if runs.count >= 3 {
                            RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                                .fill(Theme.surface2.opacity(0.45))
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline.opacity(0.6)))
                                .scaleEffect(x: 0.90, y: 1.0, anchor: .top)
                                .offset(y: 8)
                        }

                        RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                            .fill(Theme.surface2.opacity(0.75))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous).strokeBorder(Theme.hairline))
                            .scaleEffect(x: 0.95, y: 1.0, anchor: .top)
                            .offset(y: 4)
                    }
                }
                .padding(.bottom, runs.count >= 3 ? 8 : 4)
            }
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
    var onShowRunTrace: (() -> Void)? = nil
    var isSpeakingThisMessage: Bool = false
    var onSpeak: (() -> Void)? = nil

    @State private var activeModalSheet: AssistantModalSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if reasoning.contains(where: { !$0.isWhitespace }) {
                ThinkingDisclosure(reasoning: reasoning, phase: disclosurePhase, displayMode: displayMode,
                                   isLive: isStreaming)
            }
            if !toolRuns.isEmpty {
                StackedToolActivityView(runs: toolRuns) { run in
                    activeModalSheet = .tool(run)
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
                Button { onCopy() } label: {
                    Image(systemName: "doc.on.doc")
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                .accessibilityLabel("Copy answer")
            }
            if let onSpeak {
                Button { onSpeak() } label: {
                    Image(systemName: isSpeakingThisMessage ? "stop.circle.fill" : "speaker.wave.2")
                        .font(.system(size: 15))
                        .foregroundStyle(isSpeakingThisMessage ? Theme.accent : Theme.textTertiary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSpeakingThisMessage ? "Stop speaking" : "Speak answer")
            }
            if let onRegenerate {
                Button { onRegenerate() } label: {
                    Image(systemName: "arrow.clockwise")
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                .accessibilityLabel("Regenerate answer")
            }
            if let onShowRunTrace {
                Button { onShowRunTrace() } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                .accessibilityLabel("Show agent trace")
            }
            Spacer()
        }
        .font(.footnote)
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
