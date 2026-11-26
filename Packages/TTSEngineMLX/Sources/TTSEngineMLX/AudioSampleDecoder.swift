// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation

/// Decodes user-supplied reference audio files (WAV / M4A / MP3 / CAF / AIFF)
/// into mono Float32 PCM samples for CosyVoice3 zero-shot voice cloning.
public enum AudioSampleDecoder {
    public enum DecodeError: LocalizedError, Sendable {
        case emptyAudio
        case invalidFormat

        public var errorDescription: String? {
            switch self {
            case .emptyAudio:
                return "Reference audio clip contains no samples."
            case .invalidFormat:
                return "Unsupported or unreadable reference audio format."
            }
        }
    }

    public static func loadMonoFloatSamples(
        from url: URL,
        maxDurationSeconds: Double = 30.0
    ) throws -> (samples: [Float], sampleRate: Int) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let sampleRate = srcFormat.sampleRate
        guard sampleRate > 0, srcFormat.channelCount > 0 else {
            throw DecodeError.invalidFormat
        }

        let maxFrames = maxDurationSeconds > 0
            ? min(Int64(file.length), Int64((sampleRate * maxDurationSeconds).rounded(.down)))
            : Int64(file.length)
        guard maxFrames > 0 else {
            throw DecodeError.emptyAudio
        }

        guard let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: srcFormat.channelCount,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: floatFormat,
            frameCapacity: AVAudioFrameCount(maxFrames)
        ) else {
            throw DecodeError.invalidFormat
        }

        try file.read(into: buffer, frameCount: AVAudioFrameCount(maxFrames))
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channelData = buffer.floatChannelData else {
            throw DecodeError.emptyAudio
        }

        let channelCount = Int(floatFormat.channelCount)
        var mono = [Float](repeating: 0, count: frameCount)
        if channelCount == 1 {
            let ptr = channelData[0]
            for i in 0..<frameCount {
                let s = ptr[i]
                mono[i] = s.isFinite ? s : 0
            }
        } else {
            let scale = 1.0 / Float(channelCount)
            for ch in 0..<channelCount {
                let ptr = channelData[ch]
                for i in 0..<frameCount {
                    let s = ptr[i]
                    if s.isFinite {
                        mono[i] += s * scale
                    }
                }
            }
        }

        return (mono, Int(sampleRate.rounded()))
    }
}
