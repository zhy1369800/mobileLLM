// SPDX-License-Identifier: MIT

import SwiftUI
import AppUI

/// Renders Mermaid diagram specifications (flowcharts, sequence diagrams, architecture trees)
/// using a 100% offline, self-contained SVG synthesis engine. Zero network egress, zero CDN reliance.
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
            htmlString: generateOfflineMermaidHTML(code: code, colorScheme: colorScheme, interactive: isInteractiveZoom),
            isScrollEnabled: isInteractiveZoom,
            onHeightCalculated: onHeightCalculated
        )
    }

    /// Generates a 100% offline, self-contained HTML page that compiles the diagram code
    /// into native vector SVG with standard mobile viewport baseline and full scroll range.
    private func generateOfflineMermaidHTML(code: String, colorScheme: ColorScheme, interactive: Bool) -> String {
        let isDark = colorScheme == .dark
        let bgColor = isDark ? "#221B12" : "#F7F1E7"
        let cardBg = isDark ? "#2A2117" : "#FFFFFF"
        let textColor = isDark ? "#EFE6D5" : "#211B12"
        let secondaryColor = isDark ? "#B0A491" : "#5B5245"
        let hairlineColor = isDark ? "rgba(255,255,255,0.18)" : "rgba(33,20,0,0.15)"
        let accentColor = isDark ? "#D06450" : "#9F3C2E"

        let escapedCode = code
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "</script>", with: "<\\/script>")

        let paddingStyle = interactive
            ? "padding: 24px 16px 90px 16px;"
            : "padding: 12px 8px;"

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline';">
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
                body {
                    \(paddingStyle)
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    justify-content: flex-start; /* Do not center vertically to prevent top clipping / data loss on overflow */
                    overflow-x: \(interactive ? "auto" : "hidden");
                    overflow-y: \(interactive ? "auto" : "hidden");
                    -webkit-overflow-scrolling: touch;
                }
                #diagram-viewport {
                    width: 100%;
                    max-width: 100%;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                }
                svg {
                    display: block;
                    margin: 0 auto;
                    max-width: 100%;
                    height: auto;
                    filter: drop-shadow(0 2px 5px rgba(0,0,0,0.06));
                }
                .node-rect {
                    fill: var(--card-bg);
                    stroke: var(--hairline);
                    stroke-width: 1.5;
                    rx: 8;
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
                .raw-code-box {
                    background: rgba(0,0,0,0.03);
                    border: 1px solid var(--hairline);
                    border-radius: 8px;
                    padding: 12px;
                    width: 100%;
                    font-family: ui-monospace, Menlo, Monaco, monospace;
                    font-size: 12px;
                    color: var(--text-secondary);
                    white-space: pre-wrap;
                }
            </style>
        </head>
        <body>
            <div id="diagram-viewport"></div>

            <script>
                (function() {
                    const raw = `\(escapedCode)`.trim();
                    const viewport = document.getElementById('diagram-viewport');

                    try {
                        const lines = raw.split('\\n').map(l => l.trim()).filter(l => l.length > 0);
                        const isLR = raw.toLowerCase().includes(' lr');
                        
                        const nodes = new Map();
                        const edges = [];

                        function getOrCreateNode(id, label) {
                            if (!nodes.has(id)) {
                                nodes.set(id, { id: id, label: label || id });
                            } else if (label && nodes.get(id).label === id) {
                                nodes.get(id).label = label;
                            }
                            return nodes.get(id);
                        }

                        const arrowPattern = /([\\w\\-]+)(?:\\[(.*?)\\])?\\s*(-->|--|==>)\\s*(?:\\|([^|]+)\\|)?\\s*([\\w\\-]+)(?:\\[(.*?)\\])?/;

                        for (const line of lines) {
                            if (line.startsWith('graph') || line.startsWith('flowchart')) continue;
                            const match = line.match(arrowPattern);
                            if (match) {
                                const fromId = match[1];
                                const fromLabel = match[2] || fromId;
                                const edgeLabel = match[4] || '';
                                const toId = match[5];
                                const toLabel = match[6] || toId;

                                getOrCreateNode(fromId, fromLabel);
                                getOrCreateNode(toId, toLabel);
                                edges.push({ from: fromId, to: toId, label: edgeLabel });
                            } else {
                                const singleMatch = line.match(/([\\w\\-]+)\\[(.*?)\\]/);
                                if (singleMatch) {
                                    getOrCreateNode(singleMatch[1], singleMatch[2]);
                                }
                            }
                        }

                        const nodeList = Array.from(nodes.values());
                        if (nodeList.length === 0) {
                            viewport.innerHTML = '<pre class="raw-code-box">' + raw + '</pre>';
                            return;
                        }

                        // Standard mobile canvas coordinate baseline (360 pt)
                        const baseCanvasW = 360;
                        let totalW = baseCanvasW;
                        let totalH = 200;

                        if (isLR) {
                            const nodeW = 120;
                            const nodeH = 42;
                            const gapX = 40;
                            nodeList.forEach((n, idx) => {
                                n.w = nodeW;
                                n.h = nodeH;
                                n.x = idx * (nodeW + gapX) + 20;
                                n.y = 40;
                            });
                            totalW = Math.max(baseCanvasW, nodeList.length * (nodeW + gapX) + 40);
                            totalH = 130;
                        } else {
                            // Vertical layout (TD / TB)
                            const nodeW = 220; // Comfortable width for Chinese phrases without squishing
                            const nodeH = 44;
                            const gapY = 46;
                            const startX = Math.round((baseCanvasW - nodeW) / 2); // Center nodes cleanly on 360 canvas
                            
                            nodeList.forEach((n, idx) => {
                                n.w = nodeW;
                                n.h = nodeH;
                                n.x = startX;
                                n.y = idx * (nodeH + gapY) + 20;
                            });
                            totalW = baseCanvasW;
                            totalH = nodeList.length * (nodeH + gapY) + 30;
                        }

                        // Build Vector SVG with standard viewBox
                        let svg = `<svg viewBox="0 0 ${totalW} ${totalH}" style="width: 100%; max-width: ${interactive ? '100%' : '360px'};" xmlns="http://www.w3.org/2000/svg">
                            <defs>
                                <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
                                    <path d="M 0 1 L 10 5 L 0 9 z" class="edge-arrow" />
                                </marker>
                            </defs>`;

                        // Draw edges
                        edges.forEach(e => {
                            const f = nodes.get(e.from);
                            const t = nodes.get(e.to);
                            if (f && t) {
                                if (isLR) {
                                    const x1 = f.x + f.w;
                                    const y1 = f.y + f.h / 2;
                                    const x2 = t.x;
                                    const y2 = t.y + t.h / 2;
                                    svg += `<path d="M ${x1} ${y1} L ${x2} ${y2}" class="edge-path" marker-end="url(#arrow)" />`;
                                    if (e.label) {
                                        svg += `<text x="${(x1 + x2)/2}" y="${y1 - 8}" class="edge-label">${e.label}</text>`;
                                    }
                                } else {
                                    const x1 = f.x + f.w / 2;
                                    const y1 = f.y + f.h;
                                    const x2 = t.x + t.w / 2;
                                    const y2 = t.y;
                                    svg += `<path d="M ${x1} ${y1} L ${x2} ${y2}" class="edge-path" marker-end="url(#arrow)" />`;
                                    if (e.label) {
                                        // Place label with pleasant background pill
                                        const midY = (y1 + y2) / 2;
                                        svg += `<rect x="${x1 - 40}" y="${midY - 9}" width="80" height="18" fill="${bgColor}" rx="4" opacity="0.9" />`;
                                        svg += `<text x="${x1}" y="${midY}" class="edge-label">${e.label}</text>`;
                                    }
                                }
                            }
                        });

                        // Draw nodes
                        nodeList.forEach(n => {
                            svg += `<g>
                                <rect x="${n.x}" y="${n.y}" width="${n.w}" height="${n.h}" class="node-rect" />
                                <text x="${n.x + n.w / 2}" y="${n.y + n.h / 2}" class="node-text">${n.label}</text>
                            </g>`;
                        });

                        svg += `</svg>`;
                        viewport.innerHTML = svg;
                    } catch (err) {
                        viewport.innerHTML = '<pre class="raw-code-box">' + raw + '</pre>';
                    }
                })();
            </script>
        </body>
        </html>
        """
    }
}
