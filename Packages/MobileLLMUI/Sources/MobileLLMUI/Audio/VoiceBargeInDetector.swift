// SPDX-License-Identifier: MIT

import Foundation

/// Action emitted by `VoiceBargeInDetector` for each captured microphone frame during TTS playback.
internal enum VoiceBargeInAction: Equatable, Sendable {
    case none
    case duckPlayback
    case restorePlayback
    case confirmInterrupt
}

/// Tunable parameters governing full-duplex echo rejection and two-stage barge-in verification.
internal struct VoiceBargeInConfig: Equatable, Sendable {
    var enabled: Bool
    var isUsingHeadphones: Bool
    var initialAECConvergenceDuration: Double
    var steadyPlaybackGrace: Double
    var farEndActiveFloor: Float
    var farEndTailHoldDuration: Double
    var stage1BaseThreshold: Float
    var stage1NoiseMargin: Float
    var stage1FarEndScale: Float
    var stage1MaxThreshold: Float
    var stage1RequiredDuration: Double
    var stage1DecayMultiplier: Double
    var stage2SettleDuration: Double
    var stage2ConfirmThreshold: Float
    var stage2NoiseMargin: Float
    var stage2RequiredDuration: Double
    var stage2QuietRejectDuration: Double
    var stage2MaxDuration: Double
    var falseAlarmCooldownDuration: Double
    var adaptiveEchoStep: Float
    var maxAdaptiveEchoOffset: Float
    var adaptiveEchoDecayPerSecond: Float

    /// Default configuration for iOS speakerphone playback with hardware VPIO AEC active.
    static let speakerWithHardwareAEC = VoiceBargeInConfig(
        enabled: true,
        isUsingHeadphones: false,
        initialAECConvergenceDuration: 1.60,
        steadyPlaybackGrace: 0.35,
        farEndActiveFloor: 0.08,
        farEndTailHoldDuration: 0.18,
        stage1BaseThreshold: 0.54,
        stage1NoiseMargin: 0.18,
        stage1FarEndScale: 0.22,
        stage1MaxThreshold: 0.88,
        stage1RequiredDuration: 0.18,
        stage1DecayMultiplier: 1.8,
        stage2SettleDuration: 0.09,
        stage2ConfirmThreshold: 0.44,
        stage2NoiseMargin: 0.16,
        stage2RequiredDuration: 0.12,
        stage2QuietRejectDuration: 0.10,
        stage2MaxDuration: 0.38,
        falseAlarmCooldownDuration: 0.70,
        adaptiveEchoStep: 0.06,
        maxAdaptiveEchoOffset: 0.22,
        adaptiveEchoDecayPerSecond: 0.008
    )

    /// Responsive configuration when headphones / Bluetooth audio isolate microphone from speaker output.
    static let headphones = VoiceBargeInConfig(
        enabled: true,
        isUsingHeadphones: true,
        initialAECConvergenceDuration: 0.0,
        steadyPlaybackGrace: 0.15,
        farEndActiveFloor: 0.08,
        farEndTailHoldDuration: 0.05,
        stage1BaseThreshold: 0.34,
        stage1NoiseMargin: 0.15,
        stage1FarEndScale: 0.0,
        stage1MaxThreshold: 0.75,
        stage1RequiredDuration: 0.10,
        stage1DecayMultiplier: 1.5,
        stage2SettleDuration: 0.03,
        stage2ConfirmThreshold: 0.30,
        stage2NoiseMargin: 0.12,
        stage2RequiredDuration: 0.08,
        stage2QuietRejectDuration: 0.08,
        stage2MaxDuration: 0.24,
        falseAlarmCooldownDuration: 0.30,
        adaptiveEchoStep: 0.02,
        maxAdaptiveEchoOffset: 0.08,
        adaptiveEchoDecayPerSecond: 0.010
    )

    /// Disables automatic voice barge-in (e.g. if hardware VPIO failed to activate on speakerphone).
    static let disabled = VoiceBargeInConfig(
        enabled: false,
        isUsingHeadphones: speakerWithHardwareAEC.isUsingHeadphones,
        initialAECConvergenceDuration: speakerWithHardwareAEC.initialAECConvergenceDuration,
        steadyPlaybackGrace: speakerWithHardwareAEC.steadyPlaybackGrace,
        farEndActiveFloor: speakerWithHardwareAEC.farEndActiveFloor,
        farEndTailHoldDuration: speakerWithHardwareAEC.farEndTailHoldDuration,
        stage1BaseThreshold: speakerWithHardwareAEC.stage1BaseThreshold,
        stage1NoiseMargin: speakerWithHardwareAEC.stage1NoiseMargin,
        stage1FarEndScale: speakerWithHardwareAEC.stage1FarEndScale,
        stage1MaxThreshold: speakerWithHardwareAEC.stage1MaxThreshold,
        stage1RequiredDuration: speakerWithHardwareAEC.stage1RequiredDuration,
        stage1DecayMultiplier: speakerWithHardwareAEC.stage1DecayMultiplier,
        stage2SettleDuration: speakerWithHardwareAEC.stage2SettleDuration,
        stage2ConfirmThreshold: speakerWithHardwareAEC.stage2ConfirmThreshold,
        stage2NoiseMargin: speakerWithHardwareAEC.stage2NoiseMargin,
        stage2RequiredDuration: speakerWithHardwareAEC.stage2RequiredDuration,
        stage2QuietRejectDuration: speakerWithHardwareAEC.stage2QuietRejectDuration,
        stage2MaxDuration: speakerWithHardwareAEC.stage2MaxDuration,
        falseAlarmCooldownDuration: speakerWithHardwareAEC.falseAlarmCooldownDuration,
        adaptiveEchoStep: speakerWithHardwareAEC.adaptiveEchoStep,
        maxAdaptiveEchoOffset: speakerWithHardwareAEC.maxAdaptiveEchoOffset,
        adaptiveEchoDecayPerSecond: speakerWithHardwareAEC.adaptiveEchoDecayPerSecond
    )
}

/// Pure-Swift, lock-free state machine that guards against speaker echo false barge-in using:
/// 1. Real active-playback AEC convergence tracking (never burned by TTS leading silence or pauses).
/// 2. Far-end reference gating, ambient noise-floor margin, and adaptive echo offset.
/// 3. Fast-decay Stage 1 accumulator followed by a two-stage duck-and-confirm Stage 2 verification.
internal struct VoiceBargeInDetector: Sendable {
    private enum Phase: Sendable {
        case monitoring
        case verifying(elapsed: Double, confirmAccum: Double, quietAccum: Double)
    }

    internal private(set) var config: VoiceBargeInConfig
    internal private(set) var isSpeaking: Bool = false
    internal private(set) var hasHeardPlaybackInTurn: Bool = false
    internal private(set) var aecConvergedPlaybackDuration: Double = 0
    internal private(set) var steadyGraceElapsed: Double = 0
    internal private(set) var farEndTailRemaining: Double = 0
    internal private(set) var farEndEnvelope: Float = 0
    internal private(set) var ambientNoiseFloor: Float = 0.08
    internal private(set) var adaptiveEchoOffset: Float = 0
    internal private(set) var cooldownRemaining: Double = 0
    internal private(set) var stage1Accumulated: Double = 0

    private var phase: Phase = .monitoring

    init(config: VoiceBargeInConfig = .speakerWithHardwareAEC) {
        self.config = config
    }

    /// Maps linear RMS amplitude to a 0...1 perceptual dBFS scale (-52 dBFS to -8 dBFS).
    static func normalizeRMS(_ rms: Float) -> Float {
        guard rms.isFinite else { return 0 }
        let db = 20 * log10(max(rms, 1e-6))
        let normalized = (db + 52) / 44
        return min(max(normalized, 0), 1)
    }

    var isVerifying: Bool {
        if case .verifying = phase { return true }
        return false
    }

    var isAECConverged: Bool {
        aecConvergedPlaybackDuration >= config.initialAECConvergenceDuration
    }

    var currentStage1Threshold: Float {
        let basePlusNoise = max(config.stage1BaseThreshold, ambientNoiseFloor + config.stage1NoiseMargin)
        if farEndEnvelope >= config.farEndActiveFloor || farEndTailRemaining > 0 {
            return min(
                config.stage1MaxThreshold,
                basePlusNoise + farEndEnvelope * config.stage1FarEndScale + adaptiveEchoOffset
            )
        }
        let quietBase: Float = config.isUsingHeadphones ? config.stage1BaseThreshold : 0.48
        return min(
            config.stage1MaxThreshold,
            max(quietBase, ambientNoiseFloor + config.stage1NoiseMargin)
        )
    }

    var currentStage2Threshold: Float {
        min(
            config.stage1MaxThreshold - 0.05,
            max(config.stage2ConfirmThreshold, ambientNoiseFloor + config.stage2NoiseMargin)
        )
    }

    mutating func configure(_ newConfig: VoiceBargeInConfig) {
        let routeChanged = newConfig.isUsingHeadphones != config.isUsingHeadphones
        config = newConfig
        stage1Accumulated = 0
        cooldownRemaining = 0
        phase = .monitoring
        if routeChanged {
            adaptiveEchoOffset = 0
        }
    }

    mutating func resetCalibration() {
        aecConvergedPlaybackDuration = 0
        steadyGraceElapsed = 0
        farEndTailRemaining = 0
        farEndEnvelope = 0
        adaptiveEchoOffset = 0
        cooldownRemaining = 0
        stage1Accumulated = 0
        phase = .monitoring
    }

    /// Updates speaking state for a new TTS turn or stop/interrupt transition.
    /// Returns `true` if a Stage 2 duck verification was active and should be restored by the caller.
    @discardableResult
    mutating func setSpeaking(_ speaking: Bool) -> Bool {
        let wasVerifying = isVerifying
        isSpeaking = speaking
        hasHeardPlaybackInTurn = false
        steadyGraceElapsed = 0
        farEndTailRemaining = 0
        farEndEnvelope = 0
        cooldownRemaining = 0
        stage1Accumulated = 0
        phase = .monitoring
        if speaking {
            adaptiveEchoOffset = max(0, adaptiveEchoOffset * 0.6)
        }
        return wasVerifying
    }

    /// Updates the ambient noise baseline while idle/thinking (never during active TTS playback).
    mutating func updateAmbientNoise(level: Float) {
        guard !isSpeaking, level.isFinite else { return }
        let sample = min(max(level, 0), 0.42)
        if sample < ambientNoiseFloor {
            ambientNoiseFloor = ambientNoiseFloor * 0.90 + sample * 0.10
        } else {
            ambientNoiseFloor = ambientNoiseFloor * 0.992 + sample * 0.008
        }
    }

    mutating func process(micLevel: Float, farEndLevel: Float, duration: Double) -> VoiceBargeInAction {
        guard isSpeaking, config.enabled, duration > 0 else { return .none }
        let mic = micLevel.isFinite ? min(max(micLevel, 0), 1) : 0
        let farEnd = farEndLevel.isFinite ? min(max(farEndLevel, 0), 1) : 0

        switch phase {
        case .verifying(var elapsed, var confirmAccum, var quietAccum):
            elapsed += duration
            if elapsed < config.stage2SettleDuration {
                phase = .verifying(
                    elapsed: elapsed,
                    confirmAccum: confirmAccum,
                    quietAccum: quietAccum
                )
                return .none
            }

            let threshold = currentStage2Threshold
            if mic >= threshold {
                confirmAccum += duration
                quietAccum = max(0, quietAccum - duration)
                if confirmAccum >= config.stage2RequiredDuration {
                    phase = .monitoring
                    stage1Accumulated = 0
                    isSpeaking = false
                    return .confirmInterrupt
                }
            } else {
                quietAccum += duration
                confirmAccum = max(0, confirmAccum - duration * 1.5)
                if quietAccum >= config.stage2QuietRejectDuration {
                    rejectVerifyingAsEcho()
                    return .restorePlayback
                }
            }

            if elapsed >= config.stage2MaxDuration {
                phase = .monitoring
                stage1Accumulated = 0
                cooldownRemaining = config.falseAlarmCooldownDuration
                adaptiveEchoOffset = min(
                    config.maxAdaptiveEchoOffset,
                    adaptiveEchoOffset + config.adaptiveEchoStep * 0.5
                )
                return .restorePlayback
            }

            phase = .verifying(
                elapsed: elapsed,
                confirmAccum: confirmAccum,
                quietAccum: quietAccum
            )
            return .none

        case .monitoring:
            let farEndActive = farEnd >= config.farEndActiveFloor
            if farEndActive {
                hasHeardPlaybackInTurn = true
                farEndTailRemaining = config.farEndTailHoldDuration
                farEndEnvelope = max(farEnd, farEndEnvelope * 0.85)
                aecConvergedPlaybackDuration += duration
                steadyGraceElapsed += duration
            } else if farEndTailRemaining > 0 {
                farEndTailRemaining = max(0, farEndTailRemaining - duration)
                farEndEnvelope *= 0.88
                if farEndTailRemaining == 0 {
                    farEndEnvelope = 0
                    steadyGraceElapsed = 0
                }
            } else {
                farEndEnvelope = 0
                steadyGraceElapsed = 0
            }

            guard hasHeardPlaybackInTurn else {
                return .none
            }

            if cooldownRemaining > 0 {
                cooldownRemaining = max(0, cooldownRemaining - duration)
                stage1Accumulated = 0
                return .none
            }

            let speakerOrTailActive = farEndActive || farEndTailRemaining > 0
            if speakerOrTailActive && !isAECConverged {
                stage1Accumulated = 0
                return .none
            }
            if speakerOrTailActive && steadyGraceElapsed < config.steadyPlaybackGrace {
                stage1Accumulated = 0
                return .none
            }

            let threshold = currentStage1Threshold
            if mic >= threshold {
                stage1Accumulated += duration
                if stage1Accumulated >= config.stage1RequiredDuration {
                    stage1Accumulated = 0
                    phase = .verifying(
                        elapsed: 0,
                        confirmAccum: 0,
                        quietAccum: 0
                    )
                    return .duckPlayback
                }
            } else {
                stage1Accumulated = max(0, stage1Accumulated - duration * config.stage1DecayMultiplier)
            }

            if farEndActive && stage1Accumulated == 0 && adaptiveEchoOffset > 0 && mic < (threshold - 0.08) {
                adaptiveEchoOffset = max(
                    0,
                    adaptiveEchoOffset - config.adaptiveEchoDecayPerSecond * Float(duration)
                )
            }

            return .none
        }
    }

    private mutating func rejectVerifyingAsEcho() {
        adaptiveEchoOffset = min(
            config.maxAdaptiveEchoOffset,
            adaptiveEchoOffset + config.adaptiveEchoStep
        )
        phase = .monitoring
        stage1Accumulated = 0
        cooldownRemaining = config.falseAlarmCooldownDuration
    }
}
