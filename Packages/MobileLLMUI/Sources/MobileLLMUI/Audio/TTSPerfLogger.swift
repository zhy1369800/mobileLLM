import Foundation
import os

/// Lightweight append-only performance logger writing to `Documents/tts-perf.log`
/// (visible in iOS Files app via `UIFileSharingEnabled`) and `os.Logger`.
public enum TTSPerfLogger {
    private static let logger = Logger(subsystem: "com.qwen3speech", category: "Perf")
    private static let queue = DispatchQueue(label: "com.mobilellm.tts-perf-logger")
    private static let maxFileBytes = 512 * 1024

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withTime, .withFractionalSeconds]
        return formatter
    }()

    public static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")

        // Avoid writing files into host Documents during automated unit tests.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }

        let stamp = timestampFormatter.string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        queue.async {
            appendLine(line)
        }
    }

    private static func appendLine(_ line: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = line.data(using: .utf8) else {
            return
        }
        let url = docs.appendingPathComponent("tts-perf.log")
        let fm = FileManager.default

        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int,
           size > maxFileBytes {
            try? fm.removeItem(at: url)
        }

        if !fm.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
            return
        }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
