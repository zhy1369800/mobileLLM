// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation

/// Pitch-preserving offline time-stretcher for Local MLX TTS PCM output using `AVAudioUnitTimePitch`.
/// Runs on synthesized 24 kHz mono buffers prior to WAV encoding so both standard playback and
/// full-duplex `VoiceChatSession` playback inherit `settings.ttsSpeechRate` without touching
/// the live VPIO audio graph.
public enum LocalTTSAudioTimeStretcher {
    public static let minRate: Double = 0.5
    public static let maxRate: Double = 2.0

    public static func stretch(samples: [Float], sampleRate: Int, rate: Double) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0, rate.isFinite else {
            return samples
        }

        let clampedRate = min(max(rate, minRate), maxRate)
        if abs(clampedRate - 1.0) < 0.01 {
            return samples
        }

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(sampleRate),
            channels: 1
        ) else {
            return samples
        }

        let padFrames = max(2_400, sampleRate / 10)
        let inputTotalFrames = samples.count + padFrames
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(inputTotalFrames)
        ),
        let inputChannel = inputBuffer.floatChannelData?[0] else {
            return samples
        }

        inputBuffer.frameLength = AVAudioFrameCount(inputTotalFrames)
        for i in samples.indices {
            let s = samples[i]
            inputChannel[i] = s.isFinite ? s : 0
        }
        for i in samples.count..<inputTotalFrames {
            inputChannel[i] = 0
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = Float(clampedRate)
        timePitch.pitch = 0

        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        let maxFrames: AVAudioFrameCount = 4_096
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
            try engine.start()
        } catch {
            return samples
        }

        defer {
            player.stop()
            engine.stop()
        }

        player.scheduleBuffer(inputBuffer, completionHandler: nil)
        player.play()

        guard let renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames) else {
            return samples
        }

        let latencyFrames = max(0, Int((timePitch.auAudioUnit.latency * Double(sampleRate)).rounded()))
        let expectedOutputFrames = max(1, Int((Double(samples.count) / clampedRate).rounded()))
        let totalFramesToRender = expectedOutputFrames
            + latencyFrames
            + Int(ceil(Double(padFrames) / clampedRate))
            + Int(maxFrames)

        var rendered: [Float] = []
        rendered.reserveCapacity(totalFramesToRender)

        var remainingFrames = totalFramesToRender
        var contextRetries = 0

        while remainingFrames > 0 {
            let framesToRender = min(maxFrames, AVAudioFrameCount(remainingFrames))
            do {
                let status = try engine.renderOffline(framesToRender, to: renderBuffer)
                switch status {
                case .success:
                    contextRetries = 0
                    let count = Int(renderBuffer.frameLength)
                    guard count > 0, let channel = renderBuffer.floatChannelData?[0] else {
                        remainingFrames = 0
                        break
                    }
                    rendered.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
                    remainingFrames -= count
                case .insufficientDataFromInputNode:
                    remainingFrames = 0
                case .cannotDoInCurrentContext:
                    contextRetries += 1
                    if contextRetries > 8 {
                        remainingFrames = 0
                    }
                case .error:
                    return samples
                @unknown default:
                    return samples
                }
            } catch {
                return samples
            }
        }

        guard !rendered.isEmpty else {
            return samples
        }

        let maxLeadingTrim = min(latencyFrames, max(0, rendered.count - expectedOutputFrames))
        var leadingTrim = 0
        while leadingTrim < maxLeadingTrim, abs(rendered[leadingTrim]) < 1e-4 {
            leadingTrim += 1
        }

        var output = Array(rendered[leadingTrim...])
        while output.count > expectedOutputFrames, let last = output.last, abs(last) < 1e-4 {
            output.removeLast()
        }

        guard !output.isEmpty else {
            return samples
        }

        for i in output.indices {
            let s = output[i]
            if !s.isFinite {
                output[i] = 0
            } else if s > 1.0 {
                output[i] = 1.0
            } else if s < -1.0 {
                output[i] = -1.0
            }
        }

        return output
    }
}
