// SPDX-License-Identifier: MIT

import Foundation

/// Global configuration keys shared across AppRuntime, AgentRuntime, LLMCore and MobileLLMUI.
public enum AppConfigurationKeys {
    /// Canonical storage key for mobileLLM app settings snapshot in UserDefaults.
    public static let settingsStorageKey = "mobileLLM.settings.v1"
}

/// Speculative decoding mode for generation.
public enum SpeculativeMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// Disabled (default): standard autoregressive decoding.
    case off
    /// Prompt Lookup: n-gram speculative decoding based on context pattern matching.
    case promptLookup
    /// Native MTP architecture preferred: use model's native MTP draft heads if available, fallback to prompt lookup.
    case mtp

    public var displayName: String {
        switch self {
        case .off: return "Off (Standard)"
        case .promptLookup: return "Prompt Lookup"
        case .mtp: return "Native MTP / Auto"
        }
    }
}

/// Decode / sampling parameters for one generation (DESIGN §2.2). Defaults are the shipped values.
public struct Sampling: Sendable, Equatable, Codable {
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var repetitionPenalty: Double
    public var maxTokens: Int
    /// Emit a `<think>` block (`enable_thinking` in the chat template).
    public var thinking: Bool
    /// History is trimmed to this many tokens before prefill (always keeping the system turn).
    public var contextTokenCap: Int
    /// KV-cache quantization width; `0` = unquantized. 4-bit quantizes each cache after a warmup.
    public var kvBits: Int
    /// Number of tokens to keep unquantized before switching the KV cache to `kvBits` (DESIGN §2.2).
    public var quantizedKVStart: Int
    /// Optional fixed seed for reproducible sampling.
    public var seed: UInt64?
    /// Speculative decoding mode (off by default).
    public var speculativeMode: SpeculativeMode
    /// Maximum tokens allowed inside `<think>` before forcing `</think>` closure; `0` = bounded only by `maxTokens`.
    public var thinkingBudget: Int
    /// Prefill batch size (`n_batch` and `n_ubatch` in llama.cpp).
    public var prefillBatchSize: Int

    public init(temperature: Double = 0.7,
                topP: Double = 0.95,
                topK: Int = 40,
                repetitionPenalty: Double = 1.05,
                maxTokens: Int = 1024,
                thinking: Bool = true,
                contextTokenCap: Int = 8192,
                kvBits: Int = 8,
                quantizedKVStart: Int = 256,
                seed: UInt64? = nil,
                speculativeMode: SpeculativeMode = .off,
                thinkingBudget: Int = 512,
                prefillBatchSize: Int = 512) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repetitionPenalty = repetitionPenalty
        self.maxTokens = maxTokens
        self.thinking = thinking
        self.contextTokenCap = contextTokenCap
        self.kvBits = kvBits
        self.quantizedKVStart = quantizedKVStart
        self.seed = seed
        self.speculativeMode = speculativeMode
        self.thinkingBudget = thinkingBudget
        self.prefillBatchSize = prefillBatchSize
    }

    private enum CodingKeys: String, CodingKey {
        case temperature, topP, topK, repetitionPenalty, maxTokens, thinking
        case contextTokenCap, kvBits, quantizedKVStart, seed, speculativeMode
        case thinkingBudget, prefillBatchSize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.temperature = try container.decode(Double.self, forKey: .temperature)
        self.topP = try container.decode(Double.self, forKey: .topP)
        self.topK = try container.decode(Int.self, forKey: .topK)
        self.repetitionPenalty = try container.decode(Double.self, forKey: .repetitionPenalty)
        self.maxTokens = try container.decode(Int.self, forKey: .maxTokens)
        self.thinking = try container.decode(Bool.self, forKey: .thinking)
        self.contextTokenCap = try container.decode(Int.self, forKey: .contextTokenCap)
        self.kvBits = try container.decode(Int.self, forKey: .kvBits)
        self.quantizedKVStart = try container.decode(Int.self, forKey: .quantizedKVStart)
        self.seed = try container.decodeIfPresent(UInt64.self, forKey: .seed)
        self.speculativeMode = try container.decodeIfPresent(SpeculativeMode.self, forKey: .speculativeMode) ?? .off
        self.thinkingBudget = try container.decodeIfPresent(Int.self, forKey: .thinkingBudget) ?? 512
        self.prefillBatchSize = try container.decodeIfPresent(Int.self, forKey: .prefillBatchSize) ?? 512
    }
}

