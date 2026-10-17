// SPDX-License-Identifier: MIT

import Foundation

/// One turn in a chat, as handed to the engine (DESIGN §2.2 / §2.3).
public struct ChatTurn: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Equatable, Codable {
        case system, user, assistant
    }
    public let role: Role
    public let content: String
    /// Encoded image bytes (JPEG/PNG) attached to this turn, in display order. Empty for a text-only
    /// turn (the default) — the vision-capable llama.cpp engine feeds these to the model's mmproj via
    /// mtmd; every other path ignores them. Kept as raw encoded bytes (not decoded pixels) because
    /// `mtmd_helper_bitmap_init_from_buf` accepts encoded files directly.
    public let images: [Data]

    public init(role: Role, content: String, images: [Data] = []) {
        self.role = role
        self.content = content
        self.images = images
    }

    // Hand-written Codable so old persisted turns (no `images` key) still decode — `images` defaults to
    // empty — and a text-only turn re-encodes to the SAME bytes as before (the key is omitted when empty).
    // ChatStore builds ChatTurn transiently today, but the type is Codable and must stay snapshot-safe.
    private enum CodingKeys: String, CodingKey { case role, content, images }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        images = try c.decodeIfPresent([Data].self, forKey: .images) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        if !images.isEmpty { try c.encode(images, forKey: .images) }
    }
}

/// Why generation stopped.
public enum StopReason: String, Sendable, Equatable, Codable {
    case eos            // hit the end-of-sequence token
    case maxTokens      // hit `Sampling.maxTokens`
    case stopSequence   // hit a caller-supplied stop string
    case cancelled      // the caller cancelled (partial answer is still committed)
}

/// Speculative decoding runtime statistics for performance tracking and logging.
public struct SpeculativeStats: Sendable, Equatable, Codable {
    /// The name of the speculative driver that proposed the drafts (e.g. "Native MTP", "Prompt Lookup", "Prompt Lookup (Fallback)").
    public var driver: String
    /// Total candidate tokens drafted across all speculation steps.
    public var draftedTokens: Int
    /// Total drafted tokens verified and accepted by the target model.
    public var acceptedTokens: Int
    /// Overall acceptance rate (0.0 ... 1.0).
    public var acceptanceRate: Double {
        draftedTokens > 0 ? Double(acceptedTokens) / Double(draftedTokens) : 0.0
    }

    public init(driver: String, draftedTokens: Int, acceptedTokens: Int) {
        self.driver = driver
        self.draftedTokens = draftedTokens
        self.acceptedTokens = acceptedTokens
    }
}

/// End-of-generation statistics (DESIGN §2.2).
public struct Stats: Sendable, Equatable, Codable {
    public var promptTokens: Int
    public var genTokens: Int
    public var promptTPS: Double
    public var tokensPerSecond: Double
    public var peakMemoryBytes: Int64
    public var stopReason: StopReason
    public var speculativeStats: SpeculativeStats?
    /// Time to first token in seconds (from prefill start to first emitted token).
    public var ttftSeconds: Double?
    /// Tokens matched and reused from the KV cache without recomputation.
    public var cachedPromptTokens: Int?
    /// Number of transformer layers offloaded to GPU accelerator (nil when unmeasured).
    public var gpuLayers: Int?
    /// Execution backend/device name (e.g. "Metal GPU", "CPU").
    public var backend: String?

    /// Cache hit rate (0.0 ... 1.0) of prompt tokens.
    public var cacheHitRate: Double {
        let cached = cachedPromptTokens ?? 0
        let total = promptTokens + cached
        return total > 0 ? Double(cached) / Double(total) : 0.0
    }

    public init(promptTokens: Int, genTokens: Int, promptTPS: Double, tokensPerSecond: Double,
                peakMemoryBytes: Int64, stopReason: StopReason,
                speculativeStats: SpeculativeStats? = nil,
                ttftSeconds: Double? = nil,
                cachedPromptTokens: Int? = nil,
                gpuLayers: Int? = nil,
                backend: String? = nil) {
        self.promptTokens = promptTokens
        self.genTokens = genTokens
        self.promptTPS = promptTPS
        self.tokensPerSecond = tokensPerSecond
        self.peakMemoryBytes = peakMemoryBytes
        self.stopReason = stopReason
        self.speculativeStats = speculativeStats
        self.ttftSeconds = ttftSeconds
        self.cachedPromptTokens = cachedPromptTokens
        self.gpuLayers = gpuLayers
        self.backend = backend
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens, genTokens, promptTPS, tokensPerSecond, peakMemoryBytes, stopReason, speculativeStats
        case ttftSeconds, cachedPromptTokens, gpuLayers, backend
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try container.decode(Int.self, forKey: .promptTokens)
        genTokens = try container.decode(Int.self, forKey: .genTokens)
        promptTPS = try container.decode(Double.self, forKey: .promptTPS)
        tokensPerSecond = try container.decode(Double.self, forKey: .tokensPerSecond)
        peakMemoryBytes = try container.decode(Int64.self, forKey: .peakMemoryBytes)
        stopReason = try container.decode(StopReason.self, forKey: .stopReason)
        speculativeStats = try container.decodeIfPresent(SpeculativeStats.self, forKey: .speculativeStats)
        ttftSeconds = try container.decodeIfPresent(Double.self, forKey: .ttftSeconds)
        cachedPromptTokens = try container.decodeIfPresent(Int.self, forKey: .cachedPromptTokens)
        gpuLayers = try container.decodeIfPresent(Int.self, forKey: .gpuLayers)
        backend = try container.decodeIfPresent(String.self, forKey: .backend)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(promptTokens, forKey: .promptTokens)
        try container.encode(genTokens, forKey: .genTokens)
        try container.encode(promptTPS, forKey: .promptTPS)
        try container.encode(tokensPerSecond, forKey: .tokensPerSecond)
        try container.encode(peakMemoryBytes, forKey: .peakMemoryBytes)
        try container.encode(stopReason, forKey: .stopReason)
        try container.encodeIfPresent(speculativeStats, forKey: .speculativeStats)
        try container.encodeIfPresent(ttftSeconds, forKey: .ttftSeconds)
        try container.encodeIfPresent(cachedPromptTokens, forKey: .cachedPromptTokens)
        try container.encodeIfPresent(gpuLayers, forKey: .gpuLayers)
        try container.encodeIfPresent(backend, forKey: .backend)
    }
}

/// A streamed engine event (DESIGN §2.2). Reasoning + answer are already split from the raw token
/// stream by the engine's `ThinkSplitter`; `.done` closes the stream with `Stats`.
public enum EngineDelta: Sendable, Equatable {
    case reasoning(String)
    case answer(String)
    case done(Stats)
}

/// The engine contract the app talks to (DESIGN §2.2). Actor-friendly: the concrete engine is an
/// actor, and `generate` hands back an `AsyncThrowingStream` the UI consumes on the main actor.
/// LLMCore ships only the protocol + a mock; the real MLX-fork engine conforms to it in a later step.
public protocol LLMEngine: Sendable {
    /// Load a model variant's resident weights from `weightsDir` (offline). `progress` reports 0…1.
    func load(model: LLMModel, variant: LLMVariant, weightsDir: URL,
              progress: @escaping @Sendable (Double) -> Void) async throws

    /// Release the resident weights (and clear the accelerator reuse pool in the real engine).
    func unload() async

    /// Stream a generation from the chat history. The stream ends with a single `.done(Stats)` before
    /// finishing (or finishes throwing on error / cancellation).
    func generate(messages: [ChatTurn], params: Sampling) -> AsyncThrowingStream<EngineDelta, Error>
}
