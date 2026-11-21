// SPDX-License-Identifier: MIT

import Foundation
import SWCompression

/// Pure-Swift `.tar.bz2` archive extractor used to unpack downloaded Kokoro model bundles.
public enum KokoroTarBz2Extractor {
    public enum ExtractorError: LocalizedError {
        case invalidPath(String)

        public var errorDescription: String? {
            switch self {
            case .invalidPath(let path):
                return "Archive contains unsafe path: \(path)"
            }
        }
    }

    public static func extract(archiveURL: URL, destinationDir: URL) async throws {
        try await Task.detached(priority: .utility) {
            // Scope compressed buffer so it is freed before TarContainer expands entries.
            let tarData: Data = try {
                let compressedData = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
                return try BZip2.decompress(data: compressedData)
            }()
            let entries = try TarContainer.open(container: tarData)

            let fm = FileManager.default
            let canonicalRoot = destinationDir.standardizedFileURL.path

            for entry in entries {
                let rawName = entry.info.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !rawName.isEmpty, rawName != "." else { continue }

                let targetURL = destinationDir.appendingPathComponent(rawName).standardizedFileURL
                guard targetURL.path.hasPrefix(canonicalRoot) else {
                    throw ExtractorError.invalidPath(rawName)
                }

                switch entry.info.type {
                case .directory:
                    try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
                case .regular:
                    let parent = targetURL.deletingLastPathComponent()
                    if !fm.fileExists(atPath: parent.path) {
                        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                    }
                    if let data = entry.data {
                        try data.write(to: targetURL, options: [.atomic])
                    } else {
                        try Data().write(to: targetURL, options: [.atomic])
                    }
                default:
                    continue
                }
            }
        }.value
    }
}
