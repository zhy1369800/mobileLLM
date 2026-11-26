// SPDX-License-Identifier: MIT

import XCTest
@testable import TTSEngineMLX

final class WAVEncoderTests: XCTestCase {
    func testEmptyOrInvalidSampleRateProducesEmptyData() {
        XCTAssertTrue(LocalTTSWAVEncoder.encodePCM16WAV(samples: [], sampleRate: 24_000).isEmpty)
        XCTAssertTrue(LocalTTSWAVEncoder.encodePCM16WAV(samples: [0.1], sampleRate: 0).isEmpty)
    }

    func testValidHeaderAndSampleEncodingWithClippingAndSanitization() {
        let samples: [Float] = [0.0, 2.0, -2.0, .nan, .infinity, -.infinity]
        let wav = LocalTTSWAVEncoder.encodePCM16WAV(samples: samples, sampleRate: 24_000)

        XCTAssertEqual(wav.count, 44 + samples.count * 2)
        XCTAssertEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: wav[36..<40], encoding: .ascii), "data")

        let channels = wav.withUnsafeBytes { $0.load(fromByteOffset: 22, as: UInt16.self).littleEndian }
        let rate = wav.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self).littleEndian }
        let bitsPerSample = wav.withUnsafeBytes { $0.load(fromByteOffset: 34, as: UInt16.self).littleEndian }
        XCTAssertEqual(channels, 1)
        XCTAssertEqual(rate, 24_000)
        XCTAssertEqual(bitsPerSample, 16)

        let decoded: [Int16] = (0..<samples.count).map { index in
            wav.withUnsafeBytes { $0.load(fromByteOffset: 44 + index * 2, as: Int16.self).littleEndian }
        }
        XCTAssertEqual(decoded, [0, 32767, -32767, 0, 0, 0])
    }
}
