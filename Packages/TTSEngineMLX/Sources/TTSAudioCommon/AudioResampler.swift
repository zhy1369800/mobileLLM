// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Minimal pure-Swift resampler helper replacing upstream's full `AudioFileLoader`
/// for in-memory speaker encoder waveform inputs.
public enum AudioFileLoader {
    /// Linearly resamples mono Float32 PCM from `sourceRate` to `targetRate`.
    public static func resample(_ samples: [Float], from sourceRate: Int, to targetRate: Int) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0, targetRate > 0, sourceRate != targetRate else {
            return samples
        }
        let ratio = Double(sourceRate) / Double(targetRate)
        let outputCount = max(1, Int((Double(samples.count) / ratio).rounded(.down)))
        var output = [Float]()
        output.reserveCapacity(outputCount)

        for index in 0..<outputCount {
            let sourcePos = Double(index) * ratio
            let lower = Int(sourcePos)
            let upper = min(lower + 1, samples.count - 1)
            let weight = Float(sourcePos - Double(lower))
            let interpolated = samples[lower] * (1.0 - weight) + samples[upper] * weight
            output.append(interpolated)
        }
        return output
    }
}
