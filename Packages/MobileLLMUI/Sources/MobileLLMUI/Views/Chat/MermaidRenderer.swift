// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// Renders Mermaid diagram specifications using the 100% official, fully offline Mermaid engine
/// bundled directly in the app. Zero network lag, zero CDN reliance, and complete syntax support.
/// In-memory cache for pre-rendered Mermaid SVG markup, completely bypassing repeated JS execution and WebKit lag.
final class MermaidSVGCache: @unchecked Sendable {
    static let shared = MermaidSVGCache()

    private let cache = NSCache<NSString, NSString>()

    private init() {
        cache.countLimit = 128
        cache.totalCostLimit = 16 * 1024 * 1024 // 16 MB text
    }

    func svg(forKey key: String) -> String? {
        cache.object(forKey: key as NSString) as String?
    }

    func setSVG(_ svg: String, forKey key: String) {
        guard !svg.isEmpty, svg.contains("<svg") else { return }
        cache.setObject(svg as NSString, forKey: key as NSString)
    }
}

public struct MermaidDiagramView: View {

    private var cacheKey: String {
        let prefix = colorScheme == .dark ? "dark" : "light"
        return "\(prefix)_\(code.hashValue)"
    }

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

    // Pre-compiled regex patterns and character sets to eliminate runtime compilation overhead
    private static let sanitizeRectRegex = try? NSRegularExpression(
        pattern: #"([a-zA-Z0-9_\u4e00-\u9fa5\-]+)\s*\[(?!\(|\/|\\|\[)([^\[\]]+)\]"#
    )
    private static let sanitizeRhombusRegex = try? NSRegularExpression(
        pattern: #"([a-zA-Z0-9_\u4e00-\u9fa5\-]+)\s*\{(?!\})([^{}]+)\}"#
    )
    // Matches already fully-quoted valid nodes like `id["some text"]` or `id{"some text"}`
    private static let sanitizeQuotedNodeRegex = try? NSRegularExpression(
        pattern: #"([a-zA-Z0-9_\u4e00-\u9fa5\-]+)\s*(\[|\{)"([^"\n]*)"(\]|\})"#
    )
    private static let sanitizeSpecialCharacters = CharacterSet(charactersIn: "()[]{}=^√·*+/%&|<>:;,!?~#\\\"？")

    public var body: some View {
        if isInteractiveZoom {
            // Fullscreen interactive mode: full dynamic WebView with zoom/pan capabilities
            RichContentWebView(
                htmlString: generateMermaidHTML(code: code, colorScheme: colorScheme, interactive: true),
                isScrollEnabled: true,
                onHeightCalculated: onHeightCalculated
            )
        } else if let cachedSVG = MermaidSVGCache.shared.svg(forKey: cacheKey) {
            // Warm cache hit: render pre-generated static SVG instantly without 2MB mermaid.js library overhead!
            RichContentWebView(
                htmlString: generateStaticSVGHTML(svg: cachedSVG, colorScheme: colorScheme),
                isScrollEnabled: false,
                onHeightCalculated: onHeightCalculated
            )
            .frame(height: 240)
        } else {
            // Cold render: render with full mermaid engine and cache the resulting SVG string
            RichContentWebView(
                htmlString: generateMermaidHTML(code: code, colorScheme: colorScheme, interactive: false),
                isScrollEnabled: false,
                onHeightCalculated: onHeightCalculated,
                onSVGCaptured: { svg in
                    MermaidSVGCache.shared.setSVG(svg, forKey: cacheKey)
                }
            )
            .frame(height: 240)
        }
    }

    private func generateStaticSVGHTML(svg: String, colorScheme: ColorScheme) -> String {
        let isDark = colorScheme == .dark
        let bgColor = isDark ? "#221B12" : "#F7F1E7"
        let textColor = isDark ? "#EFE6D5" : "#211B12"

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
            <style>
                * { box-sizing: border-box; }
                html, body {
                    width: 100%;
                    height: 100%;
                    margin: 0;
                    padding: 12px 8px;
                    background-color: \(bgColor);
                    color: \(textColor);
                    overflow: hidden;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                }
                svg {
                    width: 100% !important;
                    max-width: 100% !important;
                    max-height: 220px !important;
                    height: auto !important;
                    display: block;
                    margin: 0 auto;
                }
            </style>
        </head>
        <body>
            \(svg)
        </body>
        </html>
        """
    }

    private func generateMermaidHTML(code: String, colorScheme: ColorScheme, interactive: Bool) -> String {
        let isDark = colorScheme == .dark
        let bgColor = isDark ? "#221B12" : "#F7F1E7"
        let cardBg = isDark ? "#2A2117" : "#FFFFFF"
        let textColor = isDark ? "#EFE6D5" : "#211B12"
        let secondaryColor = isDark ? "#B0A491" : "#5B5245"
        let hairlineColor = isDark ? "rgba(255,255,255,0.18)" : "rgba(33,20,0,0.15)"
        let accentColor = isDark ? "#D06450" : "#9F3C2E"

        let sanitizedCode = Self.sanitizeMermaidCode(code)
        let jsonData = (try? JSONSerialization.data(withJSONObject: [sanitizedCode], options: [])) ?? Data()
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
        html, body {
            width: 100%;
            height: 100%;
            min-height: 100%;
            margin: 0;
            padding: 0;
        }
        body {
            padding: 20px 16px 80px 16px;
            box-sizing: border-box;
            display: flex;
            align-items: center;
            justify-content: center;
            overflow: auto;
            -webkit-overflow-scrolling: touch;
        }
        #viewport {
            width: 100%;
            height: 100%;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        #diagram-target {
            width: 100%;
            height: 100%;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        svg {
            max-width: 100% !important;
            max-height: 100% !important;
            width: auto !important;
            height: auto !important;
            display: block;
            margin: auto;
        }
        """

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; \(scriptCSP) img-src data: blob:; connect-src 'none';">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, minimum-scale=0.5, maximum-scale=5.0, user-scalable=\(interactive ? "yes" : "no")">
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
                                    if (\(interactive ? "true" : "false")) {
                                        svg.style.maxWidth = '100%';
                                        svg.style.maxHeight = '100%';
                                        svg.style.width = 'auto';
                                        svg.style.height = 'auto';
                                    } else {
                                        svg.style.width = '100%';
                                        svg.style.height = 'auto';
                                    }
                                }
                                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mermaidSVG) {
                                    window.webkit.messageHandlers.mermaidSVG.postMessage(res.svg);
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

    /// Sanitizes Mermaid code before passing to the official engine.
    /// 1. Splits inline boolean branching operators like `||` into standard multi-line statements.
    /// 2. Automatically wraps unquoted labels containing special characters or unescaped quotes in double quotes.
    public static func sanitizeMermaidCode(_ code: String) -> String {
        let lines = code.components(separatedBy: "\n")
        var isERDiagram = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("erDiagram") {
                isERDiagram = true
                break
            }
        }

        // Phase 1: Split inline ` || ` branches into standard independent lines
        var expandedLines: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("%%") || trimmed.hasPrefix("graph") || trimmed.hasPrefix("flowchart") || isERDiagram {
                expandedLines.append(line)
                continue
            }

            // Only split when " || " connects flow statements with arrow indicators
            if line.contains(" || ") && (line.contains("-->") || line.contains("---") || line.contains("==>") || line.contains("-.->")) {
                let parts = line.components(separatedBy: " || ")
                for part in parts {
                    let pTrimmed = part.trimmingCharacters(in: .whitespaces)
                    if !pTrimmed.isEmpty {
                        expandedLines.append("    " + pTrimmed)
                    }
                }
            } else {
                expandedLines.append(line)
            }
        }

        // Phase 2: Sanitize bracketed labels with special characters or embedded quotes
        guard let rectRegex = sanitizeRectRegex, let rhombusRegex = sanitizeRhombusRegex else {
            return expandedLines.joined(separator: "\n")
        }

        func sanitizeMatches(in line: String, regex: NSRegularExpression, leftB: String, rightB: String) -> String {
            let nsLine = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            guard !matches.isEmpty else { return line }

            let mutable = NSMutableString(string: line)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3 else { continue }
                let idStr = nsLine.substring(with: match.range(at: 1))
                let contentStr = nsLine.substring(with: match.range(at: 2))

                let trimmedContent = contentStr.trimmingCharacters(in: .whitespaces)

                // Already properly quoted: ["..."]
                if trimmedContent.hasPrefix("\"") && trimmedContent.hasSuffix("\"") && trimmedContent.count >= 2 {
                    let inner = trimmedContent.dropFirst().dropLast()
                    if !inner.contains("\"") {
                        continue
                    }
                    let safe = inner.replacingOccurrences(of: "\"", with: "'")
                    mutable.replaceCharacters(in: match.range, with: "\(idStr)\(leftB)\"\(safe)\"\(rightB)")
                    continue
                }

                if contentStr.rangeOfCharacter(from: sanitizeSpecialCharacters) != nil {
                    let safe = trimmedContent.replacingOccurrences(of: "\"", with: "'")
                    mutable.replaceCharacters(in: match.range, with: "\(idStr)\(leftB)\"\(safe)\"\(rightB)")
                }
            }
            return mutable as String
        }

        let sanitizedLines = expandedLines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("%%") { return line }

            // Phase 2A: Protect already-valid quoted nodes from sub-regex corruption (e.g. math subscripts like `x_{t+2}`)
            var protectedNodes: [String] = []
            var lineProtected = line
            if let quotedRegex = sanitizeQuotedNodeRegex {
                let nsLine = lineProtected as NSString
                let matches = quotedRegex.matches(in: lineProtected, range: NSRange(location: 0, length: nsLine.length))
                if !matches.isEmpty {
                    let mutable = NSMutableString(string: lineProtected)
                    for match in matches.reversed() {
                        let originalNode = nsLine.substring(with: match.range)
                        let placeholder = "__MERMAID_QUOTED_NODE_\(protectedNodes.count)__"
                        protectedNodes.append(originalNode)
                        mutable.replaceCharacters(in: match.range, with: placeholder)
                    }
                    lineProtected = mutable as String
                }
            }

            // Phase 2B: Sanitize unquoted nodes
            let l1 = sanitizeMatches(in: lineProtected, regex: rectRegex, leftB: "[", rightB: "]")
            let l2 = sanitizeMatches(in: l1, regex: rhombusRegex, leftB: "{", rightB: "}")

            // Phase 2C: Restore protected nodes
            var finalLine = l2
            for (index, originalNode) in protectedNodes.enumerated() {
                let placeholder = "__MERMAID_QUOTED_NODE_\(index)__"
                finalLine = finalLine.replacingOccurrences(of: placeholder, with: originalNode)
            }
            return finalLine
        }

        return sanitizedLines.joined(separator: "\n")
    }
}
