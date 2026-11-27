// SPDX-License-Identifier: MIT

import XCTest
@testable import TTSEngineMLX

final class AudioTimeStretcherTests: XCTestCase {
    func testBypassForNeutralAndInvalidInputs() {
        let samples: [Float] = [0.1, -0.2, 0.3, -0.4]

        XCTAssertEqual(
            LocalTTSAudioTimeStretcher.stretch(samples: [], sampleRate: 24_000, rate: 1.5),
            []
        )
        XCTAssertEqual(
            LocalTTSAudioTimeStretcher.stretch(samples: samples, sampleRate: 0, rate: 1.5),
            samples
        )
        XCTAssertEqual(
            LocalTTSAudioTimeStretcher.stretch(samples: samples, sampleRate: 24_000, rate: .nan),
            samples
        )
        XCTAssertEqual(
            LocalTTSAudioTimeStretcher.stretch(samples: samples, sampleRate: 24_000, rate: 1.0),
            samples
        )
        XCTAssertEqual(
            LocalTTSAudioTimeStretcher.stretch(samples: samples, sampleRate: 24_000, rate: 1.005),
            samples
        )
    }

    func testStretchFasterAndSlowerPreservesSignalAndScalesDuration() {
        let sampleRate = 24_000
        let count = sampleRate // 1.0 second
        let sine: [Float] = (0..<count).map { i in
            sin(2.0 * Float.pi * 220.0 * Float(i) / Float(sampleRate)) * 0.4
        }

        let faster = LocalTTSAudioTimeStretcher.stretch(samples: sine, sampleRate: sampleRate, rate: 1.5)
        XCTAssertGreaterThan(faster.count, Int(Double(count) * 0.50))
        XCTAssertLessThan(faster.count, Int(Double(count) * 0.85))
        XCTAssertTrue(faster.allSatisfy { $0.isFinite && abs($0) <= 1.0 })
        XCTAssertGreaterThan(rms(of: faster), 0.05)

        let slower = LocalTTSAudioTimeStretcher.stretch(samples: sine, sampleRate: sampleRate, rate: 0.75)
        XCTAssertGreaterThan(slower.count, Int(Double(count) * 1.15))
        XCTAssertLessThan(slower.count, Int(Double(count) * 1.60))
        XCTAssertTrue(slower.allSatisfy { $0.isFinite && abs($0) <= 1.0 })
        XCTAssertGreaterThan(rms(of: slower), 0.05)
    }

    private func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSquares / Float(samples.count))
    }
}
