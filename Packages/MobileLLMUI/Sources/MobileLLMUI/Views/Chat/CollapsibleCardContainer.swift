// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// A versatile card container for rich content (HTML preview, Mermaid diagrams, long tables)
/// featuring ink-wash aesthetics, collapsed height capping, gradient mask, "View Full Content" button,
/// and full-screen inspection sheet.
public struct CollapsibleCardContainer<Content: View, ExpandedContent: View>: View {
    public let title: String
    public let iconName: String
    public let collapsedHeight: CGFloat
    public let sourceCode: String?
    @ViewBuilder public let content: () -> Content
    @ViewBuilder public let expandedContent: () -> ExpandedContent

    @State private var measuredContentHeight: CGFloat = 0
    @State private var isExpandedInPlace: Bool = false
    @State private var showFullScreenSheet: Bool = false
    @State private var showSourceCode: Bool = false
    @State private var copied: Bool = false

    public init(
        title: String,
        iconName: String = "doc.richtext",
        collapsedHeight: CGFloat = 260,
        sourceCode: String? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder expandedContent: @escaping () -> ExpandedContent
    ) {
        self.title = title
        self.iconName = iconName
        self.collapsedHeight = collapsedHeight
        self.sourceCode = sourceCode
        self.content = content
        self.expandedContent = expandedContent
    }

    private var isOverflowing: Bool {
        measuredContentHeight > collapsedHeight + 20
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Bar
            headerBar

            Divider().overlay(Theme.hairline)

            // Content Area
            if showSourceCode, let code = sourceCode {
                sourceCodeView(code)
            } else {
                contentBody
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
        .sheet(isPresented: $showFullScreenSheet) {
            fullScreenSheetView
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            if sourceCode != nil {
                // Toggle Preview / Code
                Picker("", selection: $showSourceCode) {
                    Text("预览").tag(false)
                    Text("代码").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }

            if let code = sourceCode {
                Button {
                    #if os(iOS)
                    UIPasteboard.general.string = code
                    #elseif os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    #endif
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(copied ? Theme.fitGreen : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("复制代码")
            }

            Button {
                showFullScreenSheet = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("全屏查看")
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(Theme.surface2.opacity(0.6))
    }

    // MARK: - Content Body with Collapse / Mask

    private var contentBody: some View {
        ZStack(alignment: .bottom) {
            content()
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: ContentHeightPreferenceKey.self, value: geo.size.height)
                    }
                )
                .frame(
                    maxHeight: (!isExpandedInPlace && isOverflowing) ? collapsedHeight : nil,
                    alignment: .topLeading
                )
                .clipped()

            // Gradient Mask & "View Full Content" button
            if isOverflowing && !isExpandedInPlace {
                VStack(spacing: Theme.Space.xs) {
                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isExpandedInPlace = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("查看完整内容")
                                .font(.subheadline.weight(.medium))
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Theme.Space.md)
                        .padding(.vertical, 6)
                        .background(Theme.surface)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Theme.hairline))
                        .shadow(color: Color.black.opacity(0.06), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, Theme.Space.sm)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 90)
                .background(
                    LinearGradient(
                        colors: [Theme.surface.opacity(0), Theme.surface.opacity(0.9), Theme.surface],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .onPreferenceChange(ContentHeightPreferenceKey.self) { height in
            measuredContentHeight = height
        }
    }

    // MARK: - Source Code View

    private func sourceCodeView(_ code: String) -> some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            Text(code)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.md)
                .textSelection(.enabled)
        }
        .frame(maxHeight: collapsedHeight)
        .background(Theme.surface2.opacity(0.4))
    }

    // MARK: - Full Screen Sheet

    private var fullScreenSheetView: some View {
        NavigationStack {
            expandedContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") {
                            showFullScreenSheet = false
                        }
                    }
                    if let code = sourceCode {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                #if os(iOS)
                                UIPasteboard.general.string = code
                                #elseif os(macOS)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                                #endif
                                copied = true
                                Task {
                                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                                    copied = false
                                }
                            } label: {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            }
                        }
                    }
                }
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
    }
}

public struct ContentHeightPreferenceKey: PreferenceKey {
    public static var defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}
