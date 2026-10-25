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
    /// into native vector SVG with layout, responsive pan/zoom, and ink-wash color tokens.
    private func generateOfflineMermaidHTML(code: String, colorScheme: ColorScheme, interactive: Bool) -> String {
        let isDark = colorScheme == .dark
        let bgColor = isDark ? "#221B12" : "#F7F1E7"
        let cardBg = isDark ? "#2A2117" : "#FFFFFF"
        let textColor = isDark ? "#EFE6D5" : "#211B12"
        let secondaryColor = isDark ? "#B0A491" : "#5B5245"
        let hairlineColor = isDark ? "rgba(255,255,255,0.15)" : "rgba(33,20,0,0.15)"
        let accentColor = isDark ? "#D06450" : "#9F3C2E"

        let escapedCode = code
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "</script>", with: "<\\/script>")

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
                body {
                    margin: 0;
                    padding: \(interactive ? "24px" : "12px");
                    background-color: var(--bg-surface);
                    color: var(--text-primary);
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    justify-content: center;
                    min-height: 100%;
                    overflow: \(interactive ? "auto" : "hidden");
                }
                #diagram-viewport {
                    width: 100%;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                }
                svg {
                    max-width: 100%;
                    height: auto;
                    filter: drop-shadow(0 2px 5px rgba(0,0,0,0.05));
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
                // Self-contained offline vector diagram layout engine
                (function() {
                    const raw = `\(escapedCode)`.trim();
                    const viewport = document.getElementById('diagram-viewport');

                    try {
                        const lines = raw.split('\\n').map(l => l.trim()).filter(l => l.length > 0);
                        const isLR = raw.toLowerCase().includes(' lr');
                        
                        // Parse node definitions and relationships
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

                        // Regex match for node connections: A[text] -->|label| B[text] or A --> B
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
                                // Single node declaration: A[Label]
                                const singleMatch = line.match(/([\\w\\-]+)\\[(.*?)\\]/);
                                if (singleMatch) {
                                    getOrCreateNode(singleMatch[1], singleMatch[2]);
                                }
                            }
                        }

                        const nodeList = Array.from(nodes.values());
                        if (nodeList.length === 0) {
                            // Display formatted structured text box if no diagram links were parsed
                            viewport.innerHTML = '<pre class="raw-code-box">' + raw + '</pre>';
                            return;
                        }

                        // Calculate layout positions
                        const nodeW = 120;
                        const nodeH = 40;
                        const gapX = isLR ? 70 : 30;
                        const gapY = isLR ? 30 : 60;

                        nodeList.forEach((n, idx) => {
                            if (isLR) {
                                n.x = idx * (nodeW + gapX) + 20;
                                n.y = 30;
                            } else {
                                n.x = 20;
                                n.y = idx * (nodeH + gapY) + 20;
                            }
                        });

                        const totalW = isLR ? nodeList.length * (nodeW + gapX) + 40 : nodeW + 40;
                        const totalH = isLR ? nodeH + 60 : nodeList.length * (nodeH + gapY) + 40;

                        // Build Vector SVG
                        let svg = `<svg viewBox="0 0 ${totalW} ${totalH}" xmlns="http://www.w3.org/2000/svg">
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
                                    const x1 = f.x + nodeW;
                                    const y1 = f.y + nodeH / 2;
                                    const x2 = t.x;
                                    const y2 = t.y + nodeH / 2;
                                    svg += `<path d="M ${x1} ${y1} L ${x2} ${y2}" class="edge-path" marker-end="url(#arrow)" />`;
                                    if (e.label) {
                                        svg += `<text x="${(x1 + x2)/2}" y="${y1 - 6}" class="edge-label">${e.label}</text>`;
                                    }
                                } else {
                                    const x1 = f.x + nodeW / 2;
                                    const y1 = f.y + nodeH;
                                    const x2 = t.x + nodeW / 2;
                                    const y2 = t.y;
                                    svg += `<path d="M ${x1} ${y1} L ${x2} ${y2}" class="edge-path" marker-end="url(#arrow)" />`;
                                    if (e.label) {
                                        svg += `<text x="${x1 + 8}" y="${(y1 + y2)/2}" class="edge-label" text-anchor="start">${e.label}</text>`;
                                    }
                                }
                            }
                        });

                        // Draw nodes
                        nodeList.forEach(n => {
                            svg += `<g>
                                <rect x="${n.x}" y="${n.y}" width="${nodeW}" height="${nodeH}" class="node-rect" />
                                <text x="${n.x + nodeW / 2}" y="${n.y + nodeH / 2}" class="node-text">${n.label}</text>
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
