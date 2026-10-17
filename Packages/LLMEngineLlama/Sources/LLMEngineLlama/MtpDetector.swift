// SPDX-License-Identifier: MIT

import Foundation
import llama

/// Sniffs GGUF metadata for Multi-Token Prediction (MTP / nextn) capabilities.
/// Aligned with the industrial standard in OGAM/llama.rn: inspecting model self-declared
/// draft layers across architecture keys (e.g. `nextn`, `mtp`, `multi_token`).
public struct MtpDetector: Sendable {
    public static let mtpKeyMarkers = ["nextn", "mtp", "multi_token"]

    /// Pure validation rule: evaluates whether a key-value metadata pair declares usable draft layers.
    public static func declaresDraftLayers(key: String, value: String) -> Bool {
        let lowerKey = key.lowercased()
        guard mtpKeyMarkers.some(lowerKey.contains) else { return false }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "false" || trimmed == "0" {
            return false
        }
        if let count = Int(trimmed) {
            return count > 0
        }
        return true
    }

    /// Evaluates a collection of metadata key-value pairs for MTP declarations.
    public static func modelDeclaresMtp(metadata: [String: String]) -> Bool {
        metadata.contains { declaresDraftLayers(key: $0.key, value: $0.value) }
    }

    /// Inspects a live `llama_model` instance's embedded GGUF metadata.
    public static func detectMtpSupport(model: OpaquePointer?) -> Bool {
        guard let model else { return false }
        let count = llama_model_meta_count(model)
        guard count > 0 else { return false }

        var keyBuffer = [CChar](repeating: 0, count: 256)
        var valBuffer = [CChar](repeating: 0, count: 256)

        for i in 0..<count {
            let keyLen = keyBuffer.withUnsafeMutableBufferPointer { buf in
                llama_model_meta_key_by_index(model, i, buf.baseAddress, buf.count)
            }
            guard keyLen > 0 else { continue }
            let key = keyBuffer.withUnsafeBufferPointer { buf in
                buf.baseAddress.map { String(cString: $0) } ?? ""
            }

            let valLen = valBuffer.withUnsafeMutableBufferPointer { buf in
                llama_model_meta_val_str_by_index(model, i, buf.baseAddress, buf.count)
            }
            guard valLen > 0 else { continue }
            let val = valBuffer.withUnsafeBufferPointer { buf in
                buf.baseAddress.map { String(cString: $0) } ?? ""
            }

            if declaresDraftLayers(key: key, value: val) {
                return true
            }
        }
        return false
    }
}

private extension Array where Element == String {
    func some(_ predicate: (String) -> Bool) -> Bool {
        contains(where: predicate)
    }
}
