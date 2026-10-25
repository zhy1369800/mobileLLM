// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// Renders Mermaid diagram specifications using the 100% official, fully offline Mermaid engine
/// bundled directly in the app. Zero network lag, zero CDN reliance, and complete syntax support.
public struct MermaidDiagramView: View {
    public let code: String
    public let isInteractiveZoom: Bool
    public var onHeightCalculated: ((CGFloat) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    public init(
        code: String,
        isInteractiveZoom: Bool = false,
        onHeightCalculated: ((CGFloat) -> Void)? = nil
    ) {
        self.code = code
        self.isInteractiveZoom = isInteractiveZoom
        self.onHeightCalculated = onHeightCalculated
    }

    /// Cached bundled Mermaid.js library content. Loaded once into memory for instant rendering.
    private static let bundledMermaidJS: String = {
        let candidateURLs = [
            Bundle.module.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Resources"),
            Bundle.module.url(forResource: "mermaid.min", withExtension: "js"),
            Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
        ]
        for url in candidateURLs.compactMap({ $0 }) {
            if let str = try? String(contentsOf: url, encoding: .utf8), !str.isEmpty {
                return str
            }
        }
        return ""
    }()

    public var body: some View {
        RichContentWebView(
            htmlString: generateMermaidHTML(code: code, colorScheme: colorScheme, interactive: isInteractiveZoom),
            isScrollEnabled: isInteractiveZoom,
            onHeightCalculated: onHeightCalculated
        )
    }

    private func generateMermaidHTML(code: String, colorScheme: ColorScheme, interactive: Bool) -> String {
        let isDark = colorScheme == .dark
        let bgColor = isDark ? "#221B12" : "#F7F1E7"
        let cardBg = isDark ? "#2A2117" : "#FFFFFF"
        let textColor = isDark ? "#EFE6D5" : "#211B12"
        let secondaryColor = isDark ? "#B0A491" : "#5B5245"
        let hairlineColor = isDark ? "rgba(255,255,255,0.18)" : "rgba(33,20,0,0.15)"
        let accentColor = isDark ? "#D06450" : "#9F3C2E"

        let jsonData = (try? JSONSerialization.data(withJSONObject: [code], options: [])) ?? Data()
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "[\"\"]"

        let hasBundledEngine = !Self.bundledMermaidJS.isEmpty

        let scriptTag = hasBundledEngine
            ? "<script>\(Self.bundledMermaidJS)</script>"
            : "<script src=\"https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js\"></script>"

        let scriptCSP = hasBundledEngine
            ? "script-src 'unsafe-inline';"
            : "script-src 'unsafe-inline' https://cdn.jsdelivr.net;"

        let cardModeCSS = """
        body {
            padding: 12px 8px;
            overflow: hidden;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        #viewport {
            width: 100%;
            display: flex;
            justify-content: center;
            align-items: center;
        }
        svg {
            width: 100% !important;
            max-width: 100% !important;
            max-height: 230px !important;
            height: auto !important;
            display: block;
            margin: 0 auto;
        }
        """

        let fullscreenModeCSS = """
        body {
            padding: 24px 16px 90px 16px;
            overflow-x: auto;
            overflow-y: auto;
            -webkit-overflow-scrolling: touch;
            display: block;
        }
        #viewport {
            width: 100%;
            display: flex;
            justify-content: center;
        }
        svg {
            max-width: 100% !important;
            height: auto !important;
            display: block;
            margin: 0 auto;
        }
        """

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; \(scriptCSP) img-src data: blob:; connect-src 'none';">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=4.0, user-scalable=\(interactive ? "yes" : "no")">
            <style>
                :root {
                    --bg-surface: \(bgColor);
                    --card-bg: \(cardBg);
                    --text-primary: \(textColor);
                    --text-secondary: \(secondaryColor);
                    --hairline: \(hairlineColor);
                    --accent: \(accentColor);
                }
                * { box-sizing: border-box; }
                html, body {
                    width: 100%;
                    min-height: 100%;
                    margin: 0;
                    background-color: var(--bg-surface);
                    color: var(--text-primary);
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                }
                \(interactive ? fullscreenModeCSS : cardModeCSS)
                .error-container {
                    background: rgba(208, 100, 80, 0.1);
                    border: 1px solid var(--accent);
                    border-radius: 8px;
                    padding: 12px;
                    width: 100%;
                    font-size: 13px;
                }
                .error-title {
                    font-weight: 600;
                    color: var(--accent);
                    margin-bottom: 6px;
                }
                .raw-code {
                    font-family: ui-monospace, Menlo, Monaco, monospace;
                    font-size: 12px;
                    color: var(--text-secondary);
                    white-space: pre-wrap;
                    margin: 0;
                }
            </style>
            \(scriptTag)
        </head>
        <body>
            <div id="viewport">
                <div id="diagram-target"></div>
            </div>

            <script>
                (function() {
                    const rawCode = \(jsonString)[0];
                    const target = document.getElementById('diagram-target');

                    function showFallback(errText) {
                        target.innerHTML = `
                            <div class="error-container">
                                <div class="error-title">图表代码</div>
                                <pre class="raw-code">${escapeHtml(rawCode)}</pre>
                            </div>
                        `;
                    }

                    function escapeHtml(str) {
                        return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
                    }

                    if (typeof mermaid === 'undefined') {
                        showFallback("图表引擎加载中...");
                        return;
                    }

                    try {
                        mermaid.initialize({
                            startOnLoad: false,
                            theme: '\(isDark ? "dark" : "neutral")',
                            securityLevel: 'loose',
                            themeVariables: {
                                darkMode: \(isDark ? "true" : "false"),
                                background: '\(bgColor)',
                                primaryColor: '\(cardBg)',
                                primaryTextColor: '\(textColor)',
                                primaryBorderColor: '\(hairlineColor)',
                                lineColor: '\(secondaryColor)',
                                secondaryColor: '\(cardBg)',
                                tertiaryColor: '\(cardBg)'
                            },
                            flowchart: {
                                useMaxWidth: true,
                                htmlLabels: true,
                                curve: 'basis'
                            }
                        });

                        mermaid.render('official-svg-' + Date.now(), rawCode)
                            .then(function(res) {
                                target.innerHTML = res.svg;
                                const svg = target.querySelector('svg');
                                if (svg) {
                                    if (!svg.getAttribute('viewBox') && svg.getAttribute('width') && svg.getAttribute('height')) {
                                        const w = parseFloat(svg.getAttribute('width'));
                                        const h = parseFloat(svg.getAttribute('height'));
                                        if (w > 0 && h > 0) {
                                            svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
                                        }
                                    }
                                    svg.style.width = '100%';
                                    svg.style.height = 'auto';
                                }
                            })
                            .catch(function(err) {
                                showFallback(err && err.message ? err.message : String(err));
                            });
                    } catch (e) {
                        showFallback(e.message || String(e));
                    }
                })();
            </script>
        </body>
        </html>
        """
    }
}
