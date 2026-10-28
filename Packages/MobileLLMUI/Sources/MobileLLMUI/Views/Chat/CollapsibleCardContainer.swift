// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI
#if os(iOS)
import UIKit
import Photos
#endif

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
    @StateObject private var snapshotController = WebViewSnapshotController()
    @State private var saving: Bool = false
    @State private var saved: Bool = false
    @State private var sharing: Bool = false
    @State private var errorMessage: String? = nil
    @State private var showErrorAlert: Bool = false

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
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
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
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
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
                .environment(\.webViewSnapshotController, snapshotController)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") {
                            showFullScreenSheet = false
                        }
                    }

                    ToolbarItemGroup(placement: .primaryAction) {
                        #if os(iOS)
                        Button {
                            downloadImage()
                        } label: {
                            if saving {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: saved ? "checkmark.circle.fill" : "arrow.down.circle")
                                    .foregroundStyle(saved ? Color.green : Theme.textPrimary)
                            }
                        }
                        .disabled(saving)
                        .accessibilityLabel("保存图片到相册")

                        Button {
                            shareImage()
                        } label: {
                            if sharing {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundStyle(Theme.textPrimary)
                            }
                        }
                        .disabled(sharing)
                        .accessibilityLabel("分享图片")
                        #endif

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
                                    .foregroundStyle(copied ? Color.green : Theme.textPrimary)
                            }
                            .accessibilityLabel("复制代码")
                        }
                    }
                }
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .alert("提示", isPresented: $showErrorAlert) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "操作失败，请重试")
                }
        }
    }

    #if os(iOS)
    private func downloadImage() {
        guard !saving else { return }
        saving = true
        Task { @MainActor in
            guard let image = await snapshotController.captureImage() else {
                saving = false
                errorMessage = "生成图表快照失败，请稍后重试。"
                showErrorAlert = true
                return
            }
            saveImageToPhotos(image)
        }
    }

    private func saveImageToPhotos(_ uiImage: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized, .limited:
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAsset(from: uiImage)
                    }) { success, error in
                        DispatchQueue.main.async {
                            saving = false
                            if success {
                                saved = true
                                Task {
                                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                                    saved = false
                                }
                            } else {
                                errorMessage = error?.localizedDescription ?? "保存图片失败。"
                                showErrorAlert = true
                            }
                        }
                    }
                case .denied, .restricted:
                    saving = false
                    errorMessage = "未获得相册权限，请在系统“设置”中允许 mobileLLM 访问相册。"
                    showErrorAlert = true
                case .notDetermined:
                    saving = false
                @unknown default:
                    saving = false
                }
            }
        }
    }

    private func shareImage() {
        guard !sharing else { return }
        sharing = true
        Task { @MainActor in
            guard let image = await snapshotController.captureImage() else {
                sharing = false
                errorMessage = "生成图表快照失败，请稍后重试。"
                showErrorAlert = true
                return
            }
            sharing = false
            presentShareSheet(items: [image])
        }
    }

    private func presentShareSheet(items: [Any]) {
        guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene ?? UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? windowScene.windows.first?.rootViewController else {
            return
        }

        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        topVC.present(activityVC, animated: true)
    }
    #endif
}

public struct ContentHeightPreferenceKey: PreferenceKey {
    public static var defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}
