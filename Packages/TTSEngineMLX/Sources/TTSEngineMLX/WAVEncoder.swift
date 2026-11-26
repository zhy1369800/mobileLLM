// SPDX-License-Identifier: MIT

import Foundation

/// Encodes mono Float32 PCM waveforms into a standard 44-byte RIFF/WAVE PCM16 buffer.
public enum LocalTTSWAVEncoder {
    /// Encodes `samples` (expected in `[-1.0, 1.0]`) as 16-bit mono PCM WAV data.
    /// Non-finite samples (`NaN`, `±Inf`) are zeroed cleanly instead of overflowing.
    public static func encodePCM16WAV(samples: [Float], sampleRate: Int = 24_000) -> Data {
        guard !samples.isEmpty, sampleRate > 0 else { return Data() }

        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = Int(bitsPerSample) / 8
        let dataSize = samples.count * bytesPerSample
        let riffChunkSize = UInt32(36 + dataSize)

        var data = Data(capacity: 44 + dataSize)
        data.append(contentsOf: "RIFF".utf8)
        appendUInt32(&data, riffChunkSize)
        data.append(contentsOf: "WAVE".utf8)

        data.append(contentsOf: "fmt ".utf8)
        appendUInt32(&data, 16) // PCM fmt chunk size
        appendUInt16(&data, 1)  // Linear PCM format
        appendUInt16(&data, numChannels)
        appendUInt32(&data, UInt32(sampleRate))
        appendUInt32(&data, UInt32(sampleRate * Int(numChannels) * bytesPerSample))
        appendUInt16(&data, numChannels * UInt16(bytesPerSample))
        appendUInt16(&data, bitsPerSample)

        data.append(contentsOf: "data".utf8)
        appendUInt32(&data, UInt32(dataSize))

        for sample in samples {
            let finite = sample.isFinite ? sample : 0
            let clamped = max(-1.0 as Float, min(1.0 as Float, finite))
            let scaled = (clamped * 32767.0).rounded()
            let pcm = Int16(max(-32767.0, min(32767.0, scaled)))
            appendInt16(&data, pcm)
        }
        return data
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendInt16(_ data: inout Data, _ value: Int16) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
