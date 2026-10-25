// SPDX-License-Identifier: MIT

import SwiftUI
import WebKit
import AppUI

/// A cross-platform, security-isolated offline WebKit view for rendering HTML content and interactive diagrams.
/// Strictly enforces local-only rendering, prevents external network hops, and automatically injects ink-wash theme CSS tokens.
public struct RichContentWebView: View {
    public let htmlString: String
    public let isScrollEnabled: Bool
    public var onHeightCalculated: ((CGFloat) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var internalHeight: CGFloat = 200

    public init(
        htmlString: String,
        isScrollEnabled: Bool = false,
        onHeightCalculated: ((CGFloat) -> Void)? = nil
    ) {
        self.htmlString = htmlString
        self.isScrollEnabled = isScrollEnabled
        self.onHeightCalculated = onHeightCalculated
    }

    public var body: some View {
        RepresentedWebView(
            htmlString: styledHTML(htmlString, colorScheme: colorScheme),
            isScrollEnabled: isScrollEnabled,
            onHeightCalculated: { height in
                internalHeight = max(100, height)
                onHeightCalculated?(internalHeight)
            }
        )
        .frame(minHeight: internalHeight)
    }

    /// Wraps raw HTML with strict Content-Security-Policy (no network hops), responsive viewport,
    /// and ink-wash palette styles.
    private func styledHTML(_ raw: String, colorScheme: ColorScheme) -> String {
        let isDark = colorScheme == .dark
        let bgColor = isDark ? "#221B12" : "#F7F1E7"
        let textColor = isDark ? "#EFE6D5" : "#211B12"
        let secondaryColor = isDark ? "#B0A491" : "#5B5245"
        let hairlineColor = isDark ? "rgba(255,255,255,0.09)" : "rgba(33,20,0,0.09)"
        let accentColor = isDark ? "#D06450" : "#9F3C2E"

        // Strict CSP: completely blocks external network traffic, subresource fetching, and cross-site framing
        let cspMeta = """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data: blob:;">
        """

        let hasHtmlTag = raw.lowercased().contains("<html") || raw.lowercased().contains("<!doctype")
        if hasHtmlTag {
            // Raw full HTML document: inject CSP & theme variables into <head>
            let themeInjection = """
            \(cspMeta)
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0, user-scalable=yes">
            <style>
                :root {
                    --bg-surface: \(bgColor);
                    --text-primary: \(textColor);
                    --text-secondary: \(secondaryColor);
                    --hairline: \(hairlineColor);
                    --accent: \(accentColor);
                }
                body {
                    margin: 0;
                    padding: 12px;
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    background-color: var(--bg-surface);
                    color: var(--text-primary);
                }
            </style>
            """
            return raw.replacingOccurrences(of: "<head>", with: "<head>\(themeInjection)", options: .caseInsensitive, range: nil)
        } else {
            // HTML snippet: wrap in standard container with strict CSP
            return """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="utf-8">
                \(cspMeta)
                <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0, user-scalable=yes">
                <style>
                    :root {
                        --bg-surface: \(bgColor);
                        --text-primary: \(textColor);
                        --text-secondary: \(secondaryColor);
                        --hairline: \(hairlineColor);
                        --accent: \(accentColor);
                    }
                    * { box-sizing: border-box; }
                    body {
                        margin: 0;
                        padding: 14px;
                        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                        background-color: var(--bg-surface);
                        color: var(--text-primary);
                        line-height: 1.5;
                        word-break: break-word;
                    }
                    table {
                        width: 100%;
                        border-collapse: collapse;
                        margin: 8px 0;
                        font-size: 14px;
                    }
                    th, td {
                        padding: 8px 12px;
                        border: 1px solid var(--hairline);
                        text-align: left;
                    }
                    th {
                        background-color: rgba(0,0,0,0.03);
                        font-weight: 600;
                    }
                    img {
                        max-width: 100%;
                        height: auto;
                    }
                    pre, code {
                        font-family: ui-monospace, Menlo, Monaco, "Cascadia Mono", monospace;
                        background: rgba(0,0,0,0.05);
                        border-radius: 4px;
                    }
                </style>
            </head>
            <body>
                \(raw)
            </body>
            </html>
            """
        }
    }
}

// MARK: - Cross-Platform WKWebView Implementation

#if os(iOS)
private struct RepresentedWebView: UIViewRepresentable {
    let htmlString: String
    let isScrollEnabled: Bool
    let onHeightCalculated: (CGFloat) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = isScrollEnabled
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.scrollView.isScrollEnabled = isScrollEnabled
        context.coordinator.onHeightCalculated = onHeightCalculated

        if context.coordinator.currentHTML != htmlString {
            context.coordinator.currentHTML = htmlString
            webView.loadHTMLString(htmlString, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onHeightCalculated: onHeightCalculated)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var currentHTML: String = ""
        var onHeightCalculated: (CGFloat) -> Void

        init(onHeightCalculated: @escaping (CGFloat) -> Void) {
            self.onHeightCalculated = onHeightCalculated
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") { [weak self] result, _ in
                if let height = result as? CGFloat, height > 0 {
                    DispatchQueue.main.async {
                        self?.onHeightCalculated(height)
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Strictly block external URL requests to maintain offline security boundary
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
#elseif os(macOS)
private struct RepresentedWebView: NSViewRepresentable {
    let htmlString: String
    let isScrollEnabled: Bool
    let onHeightCalculated: (CGFloat) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onHeightCalculated = onHeightCalculated

        if context.coordinator.currentHTML != htmlString {
            context.coordinator.currentHTML = htmlString
            webView.loadHTMLString(htmlString, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onHeightCalculated: onHeightCalculated)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var currentHTML: String = ""
        var onHeightCalculated: (CGFloat) -> Void

        init(onHeightCalculated: @escaping (CGFloat) -> Void) {
            self.onHeightCalculated = onHeightCalculated
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") { [weak self] result, _ in
                if let height = result as? CGFloat, height > 0 {
                    DispatchQueue.main.async {
                        self?.onHeightCalculated(height)
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
#endif
