// SPDX-License-Identifier: MIT

import SwiftUI

/// Interactive 3D particle-sphere visualizer for real-time voice conversation mode.
/// Renders a Fibonacci lattice of 320 3D points projected onto a SwiftUI `Canvas`
/// with audio-reactive radial wave distortion, bucketed path fills, and automatic pause when idle/hidden.
public struct VoiceOrbView: View {
    public var state: VoiceChatState
    public var isPaused: Bool
    public var levelProvider: () -> Float
    public var onTap: () -> Void

    private static let particleCount = 320
    private static let basePoints: [SIMD3<Double>] = {
        let goldenAngle = Double.pi * (3.0 - sqrt(5.0))
        return (0..<particleCount).map { i in
            let y = 1.0 - (Double(i) / Double(particleCount - 1)) * 2.0
            let radius = sqrt(max(0.0, 1.0 - y * y))
            let theta = goldenAngle * Double(i)
            return SIMD3<Double>(cos(theta) * radius, y, sin(theta) * radius)
        }
    }()

    public init(
        state: VoiceChatState,
        isPaused: Bool = false,
        levelProvider: @escaping () -> Float,
        onTap: @escaping () -> Void
    ) {
        self.state = state
        self.isPaused = isPaused
        self.levelProvider = levelProvider
        self.onTap = onTap
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let baseRadius = min(size.width, size.height) * 0.34
                let color = orbColor(for: state)
                let level = isPaused ? 0.0 : Double(min(max(levelProvider(), 0), 1))

                // Soft ambient radial glow behind the sphere.
                let glowRadius = baseRadius * (1.28 + level * 0.25)
                let glowRect = CGRect(
                    x: center.x - glowRadius,
                    y: center.y - glowRadius,
                    width: glowRadius * 2,
                    height: glowRadius * 2
                )
                context.fill(
                    Path(ellipseIn: glowRect),
                    with: .radialGradient(
                        Gradient(colors: [color.opacity(0.24), color.opacity(0.0)]),
                        center: center,
                        startRadius: baseRadius * 0.2,
                        endRadius: glowRadius
                    )
                )

                let rotSpeed: Double = switch state {
                case .thinking: 0.72
                case .speaking: 0.42
                case .listening: 0.26
                default: 0.14
                }
                let rotY = isPaused ? 0.0 : t * rotSpeed
                let rotX = isPaused ? 0.12 : sin(t * 0.35) * 0.24

                let cosY = cos(rotY), sinY = sin(rotY)
                let cosX = cos(rotX), sinX = sin(rotX)

                let waveAmplitude: Double = switch state {
                case .idle: 0.0
                case .listening: 0.055 + level * 0.22
                case .thinking: 0.12 + sin(t * 3.0) * 0.04
                case .speaking: 0.14 + level * 0.30
                case .denied, .unavailable: 0.0
                }

                let waveSpeed: Double = switch state {
                case .speaking: 3.4
                case .thinking: 2.8
                case .listening: 2.0
                default: 1.0
                }

                // Batch particles into 4 depth-alpha buckets to minimize CoreGraphics fill calls.
                var bucketPaths = [Path(), Path(), Path(), Path()]

                for p in Self.basePoints {
                    let displacement: Double
                    if waveAmplitude > 0 {
                        let w1 = sin(p.x * 3.2 + t * waveSpeed) * cos(p.y * 3.0 - t * waveSpeed * 0.8)
                        let w2 = sin(p.z * 4.1 - t * waveSpeed * 1.1)
                        displacement = 1.0 + (w1 * 0.65 + w2 * 0.35) * waveAmplitude
                    } else {
                        displacement = 1.0
                    }

                    let vx = p.x * displacement
                    let vy = p.y * displacement
                    let vz = p.z * displacement

                    let rx = vx * cosY - vz * sinY
                    let rz1 = vx * sinY + vz * cosY
                    let ry = vy * cosX - rz1 * sinX
                    let rz = vy * sinX + rz1 * cosX

                    let perspective = 2.6 / (3.2 - rz)
                    let screenX = center.x + rx * baseRadius * perspective
                    let screenY = center.y + ry * baseRadius * perspective

                    let depthFactor = min(max((rz + 1.2) / 2.4, 0), 0.999)
                    let dotRadius = max(1.2, 1.4 + depthFactor * 2.2 + level * 0.8)
                    let bucketIdx = Int(depthFactor * 4.0)

                    bucketPaths[bucketIdx].addEllipse(in: CGRect(
                        x: screenX - dotRadius,
                        y: screenY - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    ))
                }

                let bucketAlphas = [0.22, 0.45, 0.72, 0.96]
                for idx in 0..<4 where !bucketPaths[idx].isEmpty {
                    context.fill(bucketPaths[idx], with: .color(color.opacity(bucketAlphas[idx])))
                }
            }
        }
        .contentShape(Circle())
        .onTapGesture {
            onTap()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint(state == .speaking || state == .thinking ? "Double-tap to interrupt and listen" : "")
        .accessibilityAddTraits(.isButton)
    }

    private func orbColor(for state: VoiceChatState) -> Color {
        switch state {
        case .idle:
            return Color(red: 0.68, green: 0.72, blue: 0.84)
        case .listening:
            return Color(red: 0.60, green: 0.67, blue: 1.0)
        case .thinking:
            return Color(red: 0.66, green: 0.44, blue: 1.0)
        case .speaking:
            return Color(red: 0.42, green: 0.90, blue: 0.72)
        case .denied, .unavailable:
            return Color(red: 0.95, green: 0.45, blue: 0.42)
        }
    }

    private var accessibilityTitle: String {
        switch state {
        case .idle: return "Voice orb, idle"
        case .listening: return "Voice orb, listening"
        case .thinking: return "Voice orb, thinking"
        case .speaking: return "Voice orb, speaking"
        case .denied: return "Microphone permission denied"
        case .unavailable: return "Speech recognition unavailable"
        }
    }
}
