// SPDX-License-Identifier: MIT

import Foundation
import UniformTypeIdentifiers
#if canImport(PDFKit)
import PDFKit
#endif

/// Extracts plain text on-device from TXT, Markdown, source code, and PDF files so both local
/// and cloud models can inspect attached documents without third-party parsers.
public enum DocumentTextExtractor {
    public enum ExtractionError: LocalizedError, Sendable {
        case unreadableFile(String)
        case unsupportedBinary(String)
        case emptyPDF(String)
        case emptyFile(String)
        case pdfUnsupportedOnPlatform

        public var errorDescription: String? {
            switch self {
            case .unreadableFile(let name):
                return "Unable to read \"\(name)\"."
            case .unsupportedBinary(let name):
                return "\"\(name)\" appears to be a binary or unsupported file. Only TXT, Markdown, code, and PDF files are supported."
            case .emptyPDF(let name):
                return "No selectable text found in \"\(name)\" (it may be a scanned image PDF)."
            case .emptyFile(let name):
                return "\"\(name)\" is empty."
            case .pdfUnsupportedOnPlatform:
                return "PDF text extraction is unavailable on this platform."
            }
        }
    }

    /// Content types presented by the system file picker for TXT / MD / code / PDF uploads.
    public static let supportedContentTypes: [UTType] = [
        .pdf,
        .plainText,
        .sourceCode,
        .json,
        .yaml,
        .xml,
        .html,
        .commaSeparatedText,
    ]

    /// Conservative character cap derived from the active model's context window so a single file
    /// leaves room for conversation history, system prompt, and the model's reply.
    public static func recommendedMaxCharacters(contextTokenCap: Int) -> Int {
        let safeTokenBudget = max(2_000, Int(Double(contextTokenCap) * 0.55))
        let estimatedChars = safeTokenBudget * 3
        return min(32_000, max(6_000, estimatedChars))
    }

    public static func extract(from url: URL, maxCharacters: Int) throws -> FileAttachment {
        let fileName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let rawText: String
        if ext == "pdf" {
            rawText = try extractPDFText(from: url, fileName: fileName)
        } else {
            rawText = try extractPlainText(from: url, fileName: fileName)
        }

        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            throw ext == "pdf" ? ExtractionError.emptyPDF(fileName) : ExtractionError.emptyFile(fileName)
        }

        let originalCount = normalized.count
        guard originalCount > maxCharacters else {
            return FileAttachment(
                fileName: fileName,
                fileExtension: ext,
                extractedText: normalized,
                originalCharCount: originalCount,
                isTruncated: false,
                retainedPercent: 100
            )
        }

        let truncated = truncateCleanly(normalized, maxCharacters: maxCharacters)
        let retainedPercent = max(1, min(99, Int((Double(truncated.count) / Double(originalCount) * 100).rounded())))
        let annotated = "\(truncated)\n\n[... File too long (\(originalCount) chars). Truncated to first \(retainedPercent)% ...]"
        return FileAttachment(
            fileName: fileName,
            fileExtension: ext,
            extractedText: annotated,
            originalCharCount: originalCount,
            isTruncated: true,
            retainedPercent: retainedPercent
        )
    }

    private static func extractPDFText(from url: URL, fileName: String) throws -> String {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError.unreadableFile(fileName)
        }
        var pages: [String] = []
        pages.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            if let pageText = document.page(at: index)?.string {
                let trimmed = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    pages.append(trimmed)
                }
            }
        }
        let joined = pages.joined(separator: "\n\n")
        guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtractionError.emptyPDF(fileName)
        }
        return joined
        #else
        throw ExtractionError.pdfUnsupportedOnPlatform
        #endif
    }

    private static func extractPlainText(from url: URL, fileName: String) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ExtractionError.unreadableFile(fileName)
        }
        guard !data.isEmpty else {
            throw ExtractionError.emptyFile(fileName)
        }
        // Reject obvious binary files (e.g. executables, archives, images) by checking for NUL bytes
        // in the leading prefix unless it looks like UTF-16 BOM.
        let hasUTF16BOM = data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE])
        if !hasUTF16BOM, data.prefix(4_096).contains(0x00) {
            throw ExtractionError.unsupportedBinary(fileName)
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        throw ExtractionError.unsupportedBinary(fileName)
    }

    private static func truncateCleanly(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let limitIndex = text.index(text.startIndex, offsetBy: maxCharacters)
        let prefix = text[..<limitIndex]
        // Prefer breaking at a newline or space within the final 15% so lines/words aren't split mid-token.
        let minBreakOffset = Int(Double(maxCharacters) * 0.85)
        let minBreakIndex = text.index(text.startIndex, offsetBy: minBreakOffset)
        if let newlineIndex = prefix.lastIndex(of: "\n"), newlineIndex >= minBreakIndex {
            return String(prefix[..<newlineIndex])
        }
        if let spaceIndex = prefix.lastIndex(of: " "), spaceIndex >= minBreakIndex {
            return String(prefix[..<spaceIndex])
        }
        return String(prefix)
    }
}
