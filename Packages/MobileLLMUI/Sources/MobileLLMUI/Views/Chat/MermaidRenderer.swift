// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// Renders Mermaid diagram specifications with dual-engine acceleration:
/// 1. Instant local vector SVG synthesis (<5ms, zero network lag, zero waiting).
/// 2. Asynchronous background upgrade for complex graph topologies when cached.
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
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline' https://cdn.jsdelivr.net https://cdnjs.cloudflare.com; img-src data: blob:; connect-src 'none';">
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
                .node-rect {
                    fill: var(--card-bg);
                    stroke: var(--hairline);
                    stroke-width: 1.5;
                }
                .node-text {
                    fill: var(--text-primary);
                    font-size: 13px;
                    font-weight: 500;
                    text-anchor: middle;
                    dominant-baseline: central;
                }
                .edge-path {
                    stroke: var(--text-secondary);
                    stroke-width: 1.5;
                    fill: none;
                }
                .edge-arrow {
                    fill: var(--text-secondary);
                }
                .edge-label {
                    fill: var(--text-secondary);
                    font-size: 11px;
                    text-anchor: middle;
                    dominant-baseline: central;
                }
            </style>
            <!-- Background prefetch for full engine without blocking initial paint -->
            <script async src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
        </head>
        <body>
            <div id="viewport">
                <div id="diagram-target"></div>
            </div>

            <script>
                (function() {
                    const rawCode = \(jsonString)[0];
                    const target = document.getElementById('diagram-target');

                    // 1. Instant Fast-Path: local vector SVG layout engine (<5ms)
                    function renderInstantVector(raw) {
                        try {
                            const lines = raw.split('\\n').map(l => l.trim()).filter(l => l.length > 0);
                            const isLR = raw.toLowerCase().includes(' lr');

                            const nodes = new Map();
                            const edges = [];

                            function getOrCreateNode(id, label, shape) {
                                if (!nodes.has(id)) {
                                    nodes.set(id, { id: id, label: label || id, shape: shape || 'rect' });
                                } else {
                                    const n = nodes.get(id);
                                    if (label && n.label === id) n.label = label;
                                    if (shape && n.shape === 'rect') n.shape = shape;
                                }
                                return nodes.get(id);
                            }

                            // Match Unicode/Chinese node IDs with [], (), {}, ([]) shape delimiters
                            const lineRegex = /([^\\s\\[\\]\\(\\)\\{\\}\\-\\->]+)(?:(\\[|\\(|\\{|\\(\\[|\\(\\()(.*?)(\\]|\\)|\\}|\\)\\]|\\)\\)))?\\s*(-->|--|==>|-\\.->)\\s*(?:\\|([^|]+)\\|)?\\s*([^\\s\\[\\]\\(\\)\\{\\}\\-\\->]+)(?:(\\[|\\(|\\{|\\(\\[|\\(\\()(.*?)(\\]|\\)|\\}|\\)\\]|\\)\\)))?/;

                            for (const line of lines) {
                                if (line.startsWith('graph') || line.startsWith('flowchart')) continue;
                                const m = line.match(lineRegex);
                                if (m) {
                                    const fromId = m[1];
                                    const fromShapeType = m[2] ? (m[2].startsWith('{') ? 'diamond' : (m[2].startsWith('(') ? 'round' : 'rect')) : 'rect';
                                    const fromLabel = m[3] || fromId;
                                    const edgeLabel = m[5] || '';
                                    const toId = m[6];
                                    const toShapeType = m[7] ? (m[7].startsWith('{') ? 'diamond' : (m[7].startsWith('(') ? 'round' : 'rect')) : 'rect';
                                    const toLabel = m[8] || toId;

                                    getOrCreateNode(fromId, fromLabel, fromShapeType);
                                    getOrCreateNode(toId, toLabel, toShapeType);
                                    edges.push({ from: fromId, to: toId, label: edgeLabel });
                                }
                            }

                            const nodeList = Array.from(nodes.values());
                            if (nodeList.length === 0) return false;

                            const baseCanvasW = 360;
                            let totalW = baseCanvasW;
                            let totalH = 200;

                            if (isLR) {
                                const nodeW = 120, nodeH = 42, gapX = 40;
                                nodeList.forEach((n, idx) => {
                                    n.w = nodeW; n.h = nodeH;
                                    n.x = idx * (nodeW + gapX) + 20;
                                    n.y = 40;
                                });
                                totalW = Math.max(baseCanvasW, nodeList.length * (nodeW + gapX) + 40);
                                totalH = 130;
                            } else {
                                const nodeW = 220, nodeH = 44, gapY = 46;
                                const startX = Math.round((baseCanvasW - nodeW) / 2);
                                nodeList.forEach((n, idx) => {
                                    n.w = nodeW; n.h = nodeH;
                                    n.x = startX;
                                    n.y = idx * (nodeH + gapY) + 20;
                                });
                                totalW = baseCanvasW;
                                totalH = nodeList.length * (nodeH + gapY) + 30;
                            }

                            let svg = `<svg viewBox="0 0 ${totalW} ${totalH}" style="width: 100%; max-width: \(interactive ? "100%" : "360px");" xmlns="http://www.w3.org/2000/svg">
                                <defs>
                                    <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
                                        <path d="M 0 1 L 10 5 L 0 9 z" class="edge-arrow" />
                                    </marker>
                                </defs>`;

                            edges.forEach(e => {
                                const f = nodes.get(e.from), t = nodes.get(e.to);
                                if (f && t) {
                                    const x1 = f.x + f.w / 2, y1 = f.y + f.h;
                                    const x2 = t.x + t.w / 2, y2 = t.y;
                                    svg += `<path d="M ${x1} ${y1} L ${x2} ${y2}" class="edge-path" marker-end="url(#arrow)" />`;
                                    if (e.label) {
                                        const midY = (y1 + y2) / 2;
                                        svg += `<rect x="${x1 - 42}" y="${midY - 9}" width="84" height="18" fill="\(bgColor)" rx="4" opacity="0.9" />`;
                                        svg += `<text x="${x1}" y="${midY}" class="edge-label">${e.label}</text>`;
                                    }
                                }
                            });

                            nodeList.forEach(n => {
                                const rx = n.shape === 'round' ? 18 : 8;
                                svg += `<g>
                                    <rect x="${n.x}" y="${n.y}" width="${n.w}" height="${n.h}" rx="${rx}" class="node-rect" />
                                    <text x="${n.x + n.w / 2}" y="${n.y + n.h / 2}" class="node-text">${n.label}</text>
                                </g>`;
                            });

                            svg += `</svg>`;
                            target.innerHTML = svg;
                            return true;
                        } catch (e) {
                            return false;
                        }
                    }

                    // Render instantly so user sees the diagram in <5ms without any network lag
                    renderInstantVector(rawCode);

                    // 2. Full Mermaid engine upgrade (seamless replacement once cached library is ready)
                    function tryMermaidUpgrade() {
                        if (typeof mermaid !== 'undefined') {
                            try {
                                mermaid.initialize({
                                    startOnLoad: false,
                                    theme: '\(isDark ? "dark" : "neutral")',
                                    securityLevel: 'loose',
                                    flowchart: { useMaxWidth: true, htmlLabels: true }
                                });
                                mermaid.render('bg-mermaid-svg', rawCode).then(res => {
                                    target.innerHTML = res.svg;
                                }).catch(() => {});
                            } catch (e) {}
                        }
                    }

                    if (window.addEventListener) {
                        window.addEventListener('load', tryMermaidUpgrade);
                    }
                })();
            </script>
        </body>
        </html>
        """
    }
}
