// SPDX-License-Identifier: MIT

import Foundation
import llama
import LLMCore
import AppRuntime
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// The llama.cpp on-device engine: loads a GGUF model (mmap'd) and streams tokens through Metal,
/// routing the Bonsai `<think>` block to `.reasoning` and the rest to `.answer` via `ThinkSplitter`.
/// Conforms to `LLMCore.LLMEngine`, so the router drives it exactly like `MLXLLMEngine`.
///
/// Why a second engine at all: MLX keeps weights in anonymous (dirty) buffers that count fully against
/// the iOS jetsam ceiling; llama.cpp memory-maps the GGUF so its weight pages are clean/file-backed and
/// reclaimable under pressure — the difference that lets a 3.8 GB model breathe on an 8 GB phone. To keep
/// that discount we DISABLE Metal residency sets on iOS (they would wire the GPU buffers and erase it).
public actor LlamaEngine: LLMEngine {
    public typealias GovernanceFactory = @Sendable () -> GenerationGovernance

    public enum EngineError: Error, Sendable, Equatable, LocalizedError {
        case backendUnavailable
        case weightsNotFound
        case modelLoadFailed
        case contextInitFailed
        case notLoaded
        case decodeFailed
        case noUserMessage
        /// The prompt can't be made to fit the context window even after dropping all droppable history
        /// (system prefix + final user turn alone overflow). Raised instead of truncating mid-token.
        case contextWindowExceeded
        /// A turn carries an image but this model has no vision projector loaded (the variant declares no
        /// mmproj, or its file was missing at load). Raised instead of silently dropping the image.
        case visionUnavailable
        /// An attached image couldn't be decoded / prepared for the vision encoder (corrupt or unsupported
        /// image bytes, or the multimodal tokenizer rejected the prompt+image pairing).
        case imageDecodeFailed

        /// Actionable, user-facing text. Load/context failures point at the real lever (a smaller quant or
        /// freeing memory); the overflow case names the way out (shorter system prompt / longer context).
        public var errorDescription: String? {
            switch self {
            case .backendUnavailable:
                return "The on-device inference backend failed to start. Restart the app; if it keeps failing, this build may be missing its Metal support."
            case .weightsNotFound:
                return "No GGUF weights were found for this model. Re-download the model, then try again."
            case .modelLoadFailed:
                return "Couldn't load the model — most often it's too large for the memory available. Choose a smaller quantization, or free memory by unloading any other model and closing background apps."
            case .contextInitFailed:
                return "The context length or memory settings are too high. Please lower them in Settings and try again."
            case .notLoaded:
                return "No model is loaded yet. Load a model before starting a conversation."
            case .decodeFailed:
                return "Generation stopped on an internal decode error. Try again; if it persists, unload and reload the model."
            case .noUserMessage:
                return "There's no user message to respond to."
            case .contextWindowExceeded:
                return "The system prompt and your latest message alone don't fit this model's context window. Shorten the system prompt or raise the context length, then try again."
            case .visionUnavailable:
                return "This model can't read images — its vision component isn't available. Re-download the model to fetch its vision projector, or remove the image and send text only."
            case .imageDecodeFailed:
                return "Couldn't process the attached image. Make sure it's a valid JPEG or PNG, then try again."
            }
        }
    }

    private var model: OpaquePointer?
    private var vocab: OpaquePointer?
    private var context: OpaquePointer?
    /// The multimodal (vision) context from the variant's mmproj, initialized at load when the variant
    /// ships a vision projector whose file is present. `nil` for a text-only load. Freed before the model
    /// on unload/reload (it holds a reference to the text model).
    private var mtmdContext: OpaquePointer?
    /// The resolved mmproj path for the loaded variant, or nil when it ships none / the file is absent.
    /// Held so the vision encoder can be brought up lazily — see `ensureVisionContext`.
    private var projectorPath: String?
    private var contextCap: Int = 0          // the n_ctx the live context was built with
    private var contextKVBits: Int = -1      // the Sampling.kvBits the live context's KV cache was built for
    private var sessionCache = SessionCacheState()
    private var loadedID: String?
    private var thinkingCapable = true
    private var eosText = "<|im_end|>"
    private var promptTemplate: PromptTemplate = .chatML
    private var reasoningStyle: ReasoningStyle = .thinkTags
    /// Whether the currently loaded model declares MTP / nextn draft prediction layers.
    public private(set) var hasMtpSupport: Bool = false
    private var loadedGpuLayers: Int32 = 0
    nonisolated private let generationLifecycle = GenerationLifecycle()
    nonisolated private let governanceFactory: GovernanceFactory

    private let nThreads: Int32 = {
        Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
    }()

    /// llama.cpp's weights are mmap-backed, so there is no accelerator reuse cache to purge. The
    /// production governor still observes memory pressure and performs thermal pacing; tests inject a
    /// recorder through this factory without loading a GGUF.
    public init(governanceFactory: @escaping GovernanceFactory = {
        GenerationGovernance()
    }) {
        self.governanceFactory = governanceFactory
    }
    public var isLoaded: Bool { model != nil }

    /// The loaded GGUF's declared training context length (`llama_model_n_ctx_train`) — the model's true
    /// capability ceiling. Lets the UI stop inventing a `nativeContext` for community (Explore) checkpoints
    /// that aren't in the catalog. `nil` when nothing is loaded (or the model declares no value). Distinct
    /// from `contextCap`, which is the size of the CURRENTLY-ALLOCATED decode context, not the ceiling.
    public var modelTrainingContext: Int? {
        guard let model else { return nil }
        let n = llama_model_n_ctx_train(model)
        return n > 0 ? Int(n) : nil
    }

    // MARK: - Backend (global, once)

    private static let backendReady: Bool = {
        #if os(iOS)
        // Aligned with OGAM: on devices with > 4 GB RAM, allow Metal to keep weights in the residency set
        // to achieve full unified memory bandwidth (8+ tok/s) and eliminate NAND page-fault thrashing.
        // Only set NO_RESIDENCY on tight <= 4 GB devices to prevent Jetsam kills.
        if ProcessInfo.processInfo.physicalMemory <= 4_294_967_296 {
            setenv("GGML_METAL_NO_RESIDENCY", "1", 1)
        }
        #endif
        llama_backend_init()
        return true
    }()

    // MARK: - Loading

    public func load(model modelSpec: LLMCore.LLMModel, variant: LLMCore.LLMVariant, weightsDir: URL,
                     progress: @Sendable @escaping (Double) -> Void) async throws {
        guard Self.backendReady else { throw EngineError.backendUnavailable }
        let drain = await generationLifecycle.beginDrain()
        defer { generationLifecycle.endDrain(drain) }
        // Reloading over a resident model must free the predecessor first: llama_model_load_from_file
        // returns a fresh allocation, so overwriting the pointers would leak the old multi-GB model
        // (and `context = nil` below would leak its context — only llama_free releases it).
        releaseModelResources()
        let path = try Self.resolveGGUF(in: weightsDir, preferred: variant.source.fileName)

        var mp = llama_model_default_params()
        mp.load_mode = LLAMA_LOAD_MODE_MMAP      // the whole memory thesis: weights stay file-backed & reclaimable
        #if targetEnvironment(simulator)
        mp.n_gpu_layers = 0     // no Metal in the simulator
        #else
        let totalRam = ProcessInfo.processInfo.physicalMemory
        let threshold: UInt64 = 4_294_967_296 // 4 GB
        mp.n_gpu_layers = totalRam > threshold ? 999 : 0
        #endif

        guard let m = path.withCString({ llama_model_load_from_file($0, mp) }) else {
            throw EngineError.modelLoadFailed
        }
        model = m
        vocab = llama_model_get_vocab(m)
        loadedID = modelSpec.id
        loadedGpuLayers = mp.n_gpu_layers
        thinkingCapable = modelSpec.architecture.thinkingCapable
        eosText = modelSpec.architecture.eos
        promptTemplate = modelSpec.architecture.promptTemplate
        reasoningStyle = modelSpec.architecture.reasoningStyle
        hasMtpSupport = MtpDetector.detectMtpSupport(model: m)
        NSLog("[LlamaEngine] Model loaded: id=%@, MTP supported=%d, gpu_layers=%d",
              modelSpec.id, hasMtpSupport ? 1 : 0, loadedGpuLayers)
        context = nil; contextCap = 0; contextKVBits = -1

        // Vision: RESOLVE the projector now, LOAD it on first use. Bringing the vision encoder up here
        // cost every text-only chat the whole mmproj resident — ~940 MB for Gemma 4 E2B, on a phone whose
        // budget is ~4 GB. That was the difference between a comfortable run and a thrashing one: on a real
        // iPhone 16 Pro it meant 5 tok/s, `fc-thrashing` in the jetsam log, and eventually the OS killing
        // the app (largestProcess: mobileLLM, ~1.1 GB) mid-answer — for an encoder that had never seen an
        // image. A vision model is a text model that CAN see, not one that must pay to see while reading.
        //
        // Resolving eagerly keeps the old failure semantics exactly: a declared projector whose file is
        // missing leaves `projectorPath` nil → an image later throws `visionUnavailable`, not a blind load.
        projectorPath = variant.visionProjector.flatMap {
            Self.resolveProjector(in: weightsDir, fileName: $0.fileName)
        }
        progress(1)
    }

    /// Bring up the vision encoder (mmproj), once, on the first image-bearing turn. ~940 MB and a few
    /// seconds for Gemma 4 E2B, so the caller shows a note while it happens; kept resident afterwards
    /// because a conversation with one image usually has more.
    /// Returns nil when this model has no usable projector — the caller then throws `visionUnavailable`.
    private func ensureVisionContext() -> OpaquePointer? {
        if let mtmdContext { return mtmdContext }
        guard let projectorPath, let m = model else { return nil }
        var mp2 = mtmd_context_params_default()
        #if targetEnvironment(simulator)
        mp2.use_gpu = false
        #else
        // Keep backend strictly aligned with the base text model:
        // On iOS devices with > 4 GB RAM, both LLM and mmproj run on Metal GPU.
        // On <= 4 GB devices, both run on CPU to avoid cross-backend tensor mismatches.
        let totalRam = ProcessInfo.processInfo.physicalMemory
        let threshold: UInt64 = 4_294_967_296 // 4 GB
        mp2.use_gpu = totalRam > threshold
        #endif
        mp2.print_timings = false
        mp2.n_threads = nThreads

        NSLog("[LlamaEngine] Initializing vision projector: path=%@, use_gpu=%d, threads=%d",
              projectorPath, Int32(mp2.use_gpu ? 1 : 0), Int32(mp2.n_threads))

        guard let ctx = projectorPath.withCString({ mtmd_init_from_file($0, m, mp2) }) else {
            NSLog("[LlamaEngine] Failed to initialize multimodal context from %@", projectorPath)
            return nil
        }
        NSLog("[LlamaEngine] Vision projector initialized successfully")
        mtmdContext = ctx
        return mtmdContext
    }

    public func unload() async {
        // Keep the drain held after old tasks exit and through every native free below.
        let drain = await generationLifecycle.beginDrain()
        defer { generationLifecycle.endDrain(drain) }
        releaseModelResources()
    }

    private func releaseModelResources() {
        // Free the vision context BEFORE the model — it holds a reference to the text model.
        if let mtmdContext { mtmd_free(mtmdContext) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        mtmdContext = nil
        projectorPath = nil
        context = nil; model = nil; vocab = nil; loadedID = nil; contextCap = 0; contextKVBits = -1
        loadedGpuLayers = 0
        hasMtpSupport = false
        sessionCache.reset()
    }

    /// (Re)create the decode context sized to `cap` tokens with the requested KV-cache width. Kept separate
    /// from `load` because n_ctx (and the KV-cache dtype) is fixed at context-creation on llama.cpp, while
    /// both are per-generation levers. `kvBits` mirrors `Sampling.kvBits`: 0 = f16 (default), 4 = Q4_0,
    /// 8 = Q8_0. Rebuilds when EITHER the size or the KV width changes.
    private func ensureContext(cap: Int, kvBits: Int) throws {
        let target = max(512, cap)
        if context != nil, contextCap == target, contextKVBits == kvBits {
            // Keep KV cache resident for prefix reuse; prefill will clear if history diverges
            return
        }
        sessionCache.reset()
        if let context { llama_free(context) }
        // Reset BEFORE the fallible init below: if llama_init_from_model throws out of this function,
        // `context` must not keep pointing at the freed allocation (a retry would double-free, and the
        // reuse branch above would llama_memory_clear freed memory — a user-reachable UAF via kvBits).
        context = nil; contextCap = 0; contextKVBits = -1
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(target)
        cp.n_batch = 512                                          // small compute buffer; prefill is chunked
        cp.n_threads = nThreads
        cp.n_threads_batch = nThreads
        // KV-cache quantization and Flash Attention.
        // Aligned with OGAM: use AUTO across Metal backends so llama.cpp enables Flash Attention
        // on all supported layers while gracefully handling hybrid/multimodal layers,
        // keeping attention computation constant-time and preventing 2 tok/s slowdown.
        switch kvBits {
        case 4:
            cp.type_k = GGML_TYPE_Q4_0; cp.type_v = GGML_TYPE_Q4_0
        case 8:
            cp.type_k = GGML_TYPE_Q8_0; cp.type_v = GGML_TYPE_Q8_0
        default:
            break
        }
        #if !targetEnvironment(simulator)
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        #endif

        // Attempt 1: try initializing with preferred settings (including AUTO Flash Attention).
        var ctx = model.flatMap { llama_init_from_model($0, cp) }

        // Attempt 2 (OGAM fallback alignment): if Attempt 1 failed (e.g. FA allocation failure,
        // kernel incompatibilities during multimodal operations, or tight VRAM), retry with
        // default attention and f16 fallback to maximize successful execution.
        if ctx == nil, let model {
            NSLog("[LlamaEngine] Context init Attempt 1 failed (target=%d, kvBits=%d), retrying fallback...",
                  Int32(target), Int32(kvBits))
            var fallbackCp = llama_context_default_params()
            fallbackCp.n_ctx = UInt32(target)
            fallbackCp.n_batch = 512
            fallbackCp.n_threads = nThreads
            fallbackCp.n_threads_batch = nThreads
            #if !targetEnvironment(simulator)
            fallbackCp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
            #endif
            // Keep user KV bits if quantized
            switch kvBits {
            case 4:
                fallbackCp.type_k = GGML_TYPE_Q4_0; fallbackCp.type_v = GGML_TYPE_Q4_0
            case 8:
                fallbackCp.type_k = GGML_TYPE_Q8_0; fallbackCp.type_v = GGML_TYPE_Q8_0
            default:
                break
            }
            ctx = llama_init_from_model(model, fallbackCp)

            // Attempt 3: if quantized KV cache itself was too memory-heavy or refused, retry base f16 default
            if ctx == nil && kvBits != 0 {
                var safeCp = llama_context_default_params()
                safeCp.n_ctx = UInt32(target)
                safeCp.n_batch = 512
                safeCp.n_threads = nThreads
                safeCp.n_threads_batch = nThreads
                ctx = llama_init_from_model(model, safeCp)
            }
        }

        guard let ctx else {
            throw EngineError.contextInitFailed
        }
        context = ctx
        contextCap = target
        contextKVBits = kvBits
    }

    // MARK: - Generation

    public nonisolated func generate(messages: [ChatTurn],
                                     params: Sampling) -> AsyncThrowingStream<EngineDelta, Error> {
        AsyncThrowingStream { continuation in
            let governance = governanceFactory()
            let lease = generationLifecycle.begin(using: governance)
            let work = Task {
                await self.run(messages: messages, params: params, governance: governance,
                               lease: lease, into: continuation)
            }
            generationLifecycle.attachTaskCancellation({ work.cancel() }, to: lease)
            continuation.onTermination = { [generationLifecycle] _ in
                generationLifecycle.cancel(lease)
            }
        }
    }

    private func run(messages: [ChatTurn], params: Sampling,
                     governance: GenerationGovernance, lease: GenerationLifecycle.Lease,
                     into cont: AsyncThrowingStream<EngineDelta, Error>.Continuation) async {
        defer { generationLifecycle.end(lease) }
        let initialCachedSessionTokensCount = sessionCache.tokens.count
        let initialCachedSessionTokenCount = sessionCache.tokenCount
        var isIncrementalContinuation = false
        do {
            // Handles cancellation that won the race before this actor task started.
            try await governance.cooperativeCheckpoint()
            guard model != nil, let vocab else { throw EngineError.notLoaded }
            guard messages.contains(where: { $0.role == .user }) else { throw EngineError.noUserMessage }
            // Before allocating a vision encoder/context, honor heat and memory pressure.
            try await governance.checkpoint()
            // An image the user is sending NOW with no vision projector loaded fails fast (rather than
            // being silently dropped): the model literally can't see it. Only the FINAL turn is held to
            // that bar — images on HISTORY turns (a thread continued after switching to a text-only
            // model) are dropped instead, because failing there would brick the whole conversation and
            // the past answers already reflect what the previous model saw.
            //
            // This is also where the vision encoder is BROUGHT UP (~940 MB) — only now, because an image
            // is actually here. A text-only chat never pays for it. `ensureVisionContext` is idempotent,
            // so only the first image in a session waits; the composer shows the note (ChatStore sets it
            // whenever a vision turn goes out, which is honest either way — the first image loads the
            // encoder, later ones still have to run it).
            var messages = messages
            if messages.contains(where: { !$0.images.isEmpty }) { _ = ensureVisionContext() }
            if mtmdContext == nil {
                if let last = messages.last, !last.images.isEmpty {
                    throw EngineError.visionUnavailable
                }
                messages = messages.map { turn in
                    turn.images.isEmpty ? turn : ChatTurn(role: turn.role, content: turn.content)
                }
            }

            try ensureContext(cap: params.contextTokenCap, kvBits: params.kvBits)
            guard let context else { throw EngineError.contextInitFailed }

            let wantThinking = params.thinking && reasoningStyle.canThink
            // Prefer the GGUF's own embedded template via llama.cpp for pure text (matching official tokenizer / Jinja
            // training alignment); for image turns or when template fails, use hand-verified builder so media
            // markers (<__media__>) are never stripped or corrupted by pure-text chat templates.
            func renderPrompt(_ msgs: [ChatTurn]) -> String {
                let carriesMedia = msgs.contains(where: { !$0.images.isEmpty })
                if !carriesMedia, let m = model,
                   let rendered = Self.autoPrompt(msgs, modelPtr: m, reasoning: reasoningStyle, thinking: wantThinking) {
                    return rendered
                }
                return Self.buildPrompt(messages: msgs, template: promptTemplate,
                                        reasoning: reasoningStyle, thinking: wantThinking)
            }

            // Fit the history into the KV window by dropping WHOLE oldest non-system turns and rebuilding —
            // NEVER by chopping tokens off the front, which would shear the system prompt and the template
            // head mid-conversation. Reserve room for the answer; if even {system prefix + final user turn}
            // overflows, fail with a clear error rather than emit garbage from a half-formed prompt. Each
            // attached image also reserves ~600 tokens — its vision-encoder embeddings consume real context.
            let reserve = Self.answerTokenReserve(maxTokens: params.maxTokens)
            let budget = contextCap - reserve
            guard budget > 0, let kept = Self.fitMessages(messages, budget: budget, tokenCount: {
                Self.tokenize(vocab: vocab, text: renderPrompt($0), addSpecial: true).count + Self.imageTokenCount($0)
            }) else {
                throw EngineError.contextWindowExceeded
            }

            let sampler = Self.makeSampler(vocab: vocab, params: params)
            defer { llama_sampler_free(sampler) }

            // Prefill. With NO image in the kept history this is byte-identical to before: tokenize the
            // rendered prompt and llama_decode it in n_batch chunks. When a kept turn carries images, prefill
            // through mtmd instead (marker injection → tokenize text+images → chunk-by-chunk encode/decode),
            // which leaves the KV populated so the decode loop below continues from where the prefill ended.
            let prefillStart = Date()
            let nBatch = 512
            var promptTokenCount: Int = 0
            var cachedRollbackTokensCount: Int = 0
            var rollbackDiagnosticMessage: String? = nil
            let hasImages = kept.contains { !$0.images.isEmpty }

            // Check if this turn is an incremental continuation of the cached session:
            // Condition:
            // 1. Prefix of `kept` exactly matches `cachedSessionTurns`
            // 2. Exactly 1 new turn added (the new user query)
            // 3. The new query carries no images
            // 4. Physical KV cache has sufficient headroom for suffix + answer reserve
            let previousCount = sessionCache.turns.count
            let canAttemptIncremental = previousCount > 0 &&
                kept.count == previousCount + 1 &&
                Array(kept.prefix(previousCount)) == sessionCache.turns &&
                kept.last?.images.isEmpty == true

            var incrementalSuffixTokens: [llama_token]? = nil
            if canAttemptIncremental {
                let newTurnPrompt = Self.buildPrompt(messages: [kept.last!], template: promptTemplate,
                                                     reasoning: reasoningStyle, thinking: wantThinking)
                let suffixText = newTurnPrompt.hasPrefix("\n") ? newTurnPrompt : ("\n" + newTurnPrompt)
                let tokens = Self.tokenize(vocab: vocab, text: suffixText, addSpecial: false)
                let incrementalReserve = min(reserve, 256)
                if !tokens.isEmpty && sessionCache.tokenCount + tokens.count + incrementalReserve <= contextCap {
                    incrementalSuffixTokens = tokens
                } else {
                    NSLog("[LlamaEngine] Incremental continuation skipped: KV cache headroom exceeded or empty tokens (used=%d, suffix=%d, reserve=%d, cap=%d). Falling back to full evaluation.",
                          Int32(sessionCache.tokenCount), Int32(tokens.count), Int32(incrementalReserve), Int32(contextCap))
                }
            } else if previousCount > 0 {
                let countOk = kept.count == previousCount + 1
                let prefixOk = countOk && Array(kept.prefix(previousCount)) == sessionCache.turns
                let noImg = kept.last?.images.isEmpty == true
                NSLog("[LlamaEngine] Incremental continuation rejected: kept.count=%d (expected %d), prefixMatch=%@, lastNoImages=%@",
                      Int32(kept.count), Int32(previousCount + 1),
                      prefixOk ? "true" : "false",
                      noImg ? "true" : "false")
            }

            var prefilledPromptTokens: [llama_token]? = nil
            if let suffixTokens = incrementalSuffixTokens {
                isIncrementalContinuation = true
                // MULTI-TURN CONTINUATION (text or multimodal):
                // All prior turns (including visual ViT embeddings and previous answers) already reside
                // in the KV cache with the assistant turn cleanly closed by EOG. Decode ONLY the suffix
                // of the new user query — completely skipping mtmd re-evaluation and saving ~3-5 seconds
                // of image ViT compute!
                NSLog("[LlamaEngine] Incremental continuation matched! Suffix tokens: %d (skipped image/history recompute)",
                      Int32(suffixTokens.count))
                let batchCap = Int32(max(1, min(nBatch, suffixTokens.count)))
                var batch = llama_batch_init(batchCap, 0, 1)
                defer { llama_batch_free(batch) }

                var i = 0
                while i < suffixTokens.count {
                    try await governance.checkpoint()
                    guard self.context == context else { throw CancellationError() }
                    let end = min(i + nBatch, suffixTokens.count)
                    let chunkCount = end - i
                    for offset in 0..<chunkCount {
                        let tok = suffixTokens[i + offset]
                        let isLast = (i + offset == suffixTokens.count - 1)
                        Self.setBatchItem(&batch, at: offset, maxCapacity: batchCap,
                                          token: tok, pos: Int32(sessionCache.tokenCount + i + offset), logits: isLast)
                    }
                    batch.n_tokens = Int32(chunkCount)
                    guard llama_decode(context, batch) == 0 else { throw EngineError.decodeFailed }
                    i = end
                    await Task.yield()
                    guard self.context == context else { throw CancellationError() }
                }
                promptTokenCount = suffixTokens.count
                // Note: conversationTokens for speculative n-gram lookup is built lazily below,
                // only when speculative mode is active and prompt lookup is actually in use.
            } else if hasImages {
                // Multimodal full evaluation: new image introduced or conversation diverged
                sessionCache.reset(context: context)
                promptTokenCount = try await mtmdPrefill(kept: kept, context: context,
                                                         renderPrompt: renderPrompt, nBatch: nBatch,
                                                         governance: governance)
            } else {
                // Pure text evaluation: Prefix Rollback optimization with clean slate fallback
                let promptTokens = Self.tokenize(vocab: vocab, text: renderPrompt(kept), addSpecial: true)
                prefilledPromptTokens = promptTokens

                let residentHadImages = sessionCache.hasImages

                // Calculate Longest Common Prefix (LCP) between resident KV tokens and new prompt tokens.
                // Only valid if resident session was pure text and has authoritative physical tokens cached.
                var commonCount = 0
                if !residentHadImages && !sessionCache.tokens.isEmpty {
                    let maxLcp = min(sessionCache.tokens.count, promptTokens.count)
                    while commonCount < maxLcp && sessionCache.tokens[commonCount] == promptTokens[commonCount] {
                        commonCount += 1
                    }
                }

                let incrementalReserve = min(reserve, 256)
                let canRollback = !residentHadImages &&
                                  !sessionCache.tokens.isEmpty &&
                                  commonCount >= 16 &&
                                  commonCount < promptTokens.count &&
                                  (promptTokens.count + incrementalReserve <= contextCap)

                if !canRollback {
                    if residentHadImages {
                        rollbackDiagnosticMessage = "跳过回滚: 包含多模态图片"
                    } else if sessionCache.tokens.isEmpty {
                        rollbackDiagnosticMessage = "跳过回滚: 显存中无历史会话Token"
                    } else if commonCount < 16 {
                        rollbackDiagnosticMessage = "回滚失败: 最长公共前缀过短 (仅匹配 \(commonCount) tok, 需要>=16, resident=\(sessionCache.tokens.count), prompt=\(promptTokens.count))"
                    } else if commonCount >= promptTokens.count {
                        rollbackDiagnosticMessage = "跳过回滚: 前缀完全包含新Prompt"
                    } else {
                        rollbackDiagnosticMessage = "跳过回滚: 上下文超限 (prompt=\(promptTokens.count), cap=\(contextCap))"
                    }
                }

                NSLog("[LlamaEngine] Prefix rollback evaluation: resident=%d, prompt=%d, common=%d (canRollback=%@, residentHadImages=%@)",
                      Int32(sessionCache.tokens.count), Int32(promptTokens.count), Int32(commonCount),
                      canRollback ? "true" : "false", residentHadImages ? "true" : "false")

                var rollbackSucceeded = false
                if canRollback {
                    var rmSuccess = true
                    if sessionCache.tokens.count > commonCount {
                        rmSuccess = llama_memory_seq_rm(llama_get_memory(context), 0, Int32(commonCount), -1)
                    }
                    if rmSuccess {
                        let suffixTokens = Array(promptTokens[commonCount...])
                        let hitRatePct = (Double(commonCount) / Double(promptTokens.count)) * 100.0
                        NSLog("[LlamaEngine] Prefix rollback matched! Common prefix: %d tokens (hit %.1f%%), suffix: %d tokens",
                              Int32(commonCount), hitRatePct, Int32(suffixTokens.count))

                        let batchCap = Int32(max(1, min(nBatch, suffixTokens.count)))
                        var batch = llama_batch_init(batchCap, 0, 1)
                        defer { llama_batch_free(batch) }

                        var i = 0
                        var decodeError: Error? = nil
                        while i < suffixTokens.count {
                            try await governance.checkpoint()
                            guard self.context == context else { throw CancellationError() }
                            let end = min(i + nBatch, suffixTokens.count)
                            let chunkCount = end - i
                            for offset in 0..<chunkCount {
                                let tok = suffixTokens[i + offset]
                                let isLast = (i + offset == suffixTokens.count - 1)
                                Self.setBatchItem(&batch, at: offset, maxCapacity: batchCap,
                                                  token: tok, pos: Int32(commonCount + i + offset), logits: isLast)
                            }
                            batch.n_tokens = Int32(chunkCount)
                            let decodeRes = llama_decode(context, batch)
                            if decodeRes != 0 {
                                decodeError = EngineError.decodeFailed
                                break
                            }
                            i = end
                            await Task.yield()
                            guard self.context == context else { throw CancellationError() }
                        }
                        if decodeError == nil {
                            promptTokenCount = suffixTokens.count
                            cachedRollbackTokensCount = commonCount
                            rollbackSucceeded = true
                            rollbackDiagnosticMessage = "前缀回滚命中: 复用 \(commonCount) tok (\(String(format: "%.1f%%", hitRatePct))), 解码后缀 \(suffixTokens.count) tok"
                        } else {
                            rollbackDiagnosticMessage = "回滚失败: 后缀Token解码失败 (llama_decode error)"
                            NSLog("[LlamaEngine] Prefix rollback decode failed, falling back to clean slate")
                        }
                    } else {
                        rollbackDiagnosticMessage = "回滚跳过: 显存不支持局部截断 (如Qwen3.5等混合SSM/Recurrent架构隐状态在数学上不可逆)，已安全全量重新预填充"
                        NSLog("[LlamaEngine] Prefix rollback llama_memory_seq_rm rejected partial sequence trim (likely hybrid/recurrent architecture like Qwen 3.5), safely falling back to clean slate")
                    }
                }

                if !rollbackSucceeded {
                    // Clean slate fallback: clean slate to ensure 100% position alignment
                    sessionCache.reset(context: context)

                    let batchCap = Int32(max(1, min(nBatch, promptTokens.count)))
                    var batch = llama_batch_init(batchCap, 0, 1)
                    defer { llama_batch_free(batch) }

                    var i = 0
                    while i < promptTokens.count {
                        try await governance.checkpoint()
                        guard self.context == context else { throw CancellationError() }
                        let end = min(i + nBatch, promptTokens.count)
                        let chunkCount = end - i
                        for offset in 0..<chunkCount {
                            let tok = promptTokens[i + offset]
                            let isLast = (i + offset == promptTokens.count - 1)
                            Self.setBatchItem(&batch, at: offset, maxCapacity: batchCap,
                                              token: tok, pos: Int32(i + offset), logits: isLast)
                        }
                        batch.n_tokens = Int32(chunkCount)
                        guard llama_decode(context, batch) == 0 else { throw EngineError.decodeFailed }
                        i = end
                        await Task.yield()
                        guard self.context == context else { throw CancellationError() }
                    }
                    promptTokenCount = promptTokens.count
                }
            }
            let promptSecs = max(Date().timeIntervalSince(prefillStart), 0.0001)
            let cachedPromptTokensCount: Int = incrementalSuffixTokens != nil ? sessionCache.tokenCount : cachedRollbackTokensCount

            // Decode loop. Implicit-open reasoning (Qwen3.5) begins inside the think block. The answer
            // stripper removes a model's answer-wrapper tags (Hunyuan's <answer>…</answer>) so they never
            // reach the UI.
            var splitter = ThinkSplitter(startInThink: reasoningStyle == .thinkTagsImplicitOpen && wantThinking)
            var decoder = PieceDecoder()
            var answerStripper = LiteralStripper(tags: Self.answerStripTags(for: promptTemplate))
            var fullGeneratedAnswer = ""
            var firstTokenTime: Date? = nil
            func emit(_ d: ThinkSplitter.Delta) {
                switch d {
                case .reasoning(let s):
                    if !s.isEmpty {
                        if firstTokenTime == nil { firstTokenTime = Date() }
                        cont.yield(.reasoning(s))
                    }
                case .answer(let s):
                    let out = answerStripper.isNoop ? s : answerStripper.feed(s)
                    if !out.isEmpty {
                        if firstTokenTime == nil { firstTokenTime = Date() }
                        cont.yield(.answer(out))
                        fullGeneratedAnswer += out
                    }
                }
            }
            var genTokens = 0
            var peak: Int64 = 0
            var stop: StopReason = .eos
            let genStart = Date()
            let maxTokens = params.maxTokens

            // Speculative decoding mode configuration
            // Adaptive draft token cap based on sampling temperature:
            // - Low temperature (<= 0.2) or greedy: high prediction confidence, draft up to 2 tokens.
            // - Moderate / high temperature (> 0.2): higher entropy, draft 1 token to bound rollback penalty.
            let effectiveMaxDrafts: Int = (params.temperature <= 0.2) ? 2 : 1
            let missThresholdForBackoff: Int = (params.temperature > 0.6) ? 1 : 2
            let drafter = PromptLookupDrafter(maxDraftTokens: effectiveMaxDrafts, minNgram: 3, maxNgram: 5, maxLookbackWindow: 512)
            var toolGate = ToolCallSpeculationGate()
            var mtpDriver: NativeMtpDriver? = nil
            let useSpeculative: Bool

            switch params.speculativeMode {
            case .off:
                useSpeculative = false
            case .promptLookup:
                useSpeculative = true
            case .mtp:
                if hasMtpSupport {
                    if NativeMtpDriver.isCompiledIn {
                        mtpDriver = NativeMtpDriver(context: context, model: model, nDraft: effectiveMaxDrafts)
                        NSLog("[LlamaEngine] Speculative mode: Native MTP driver initialized successfully (nDraft=%d)", Int32(effectiveMaxDrafts))
                    } else {
                        NSLog("[LlamaEngine] Speculative mode: Native MTP symbols not linked in framework, fallback to Prompt Lookup")
                    }
                    useSpeculative = true
                } else {
                    NSLog("[LlamaEngine] Speculative mode: Model lacks MTP weights, fallback to Prompt Lookup")
                    useSpeculative = true
                }
            }

            var activeSpeculativeDriver: String? = nil
            var totalDraftedTokens = 0
            var totalAcceptedTokens = 0

            var conversationTokens: [llama_token] = []
            if useSpeculative {
                if let prefilled = prefilledPromptTokens {
                    // Pure-text full-eval path: prompt was already tokenized during prefill, reuse directly.
                    conversationTokens = prefilled
                } else if let suffixTokens = incrementalSuffixTokens {
                    // Multi-turn incremental path: only Prompt Lookup needs a token history for n-gram matching.
                    // MTP driver only requires lastToken per step, so skip expensive history tokenize for MTP.
                    if mtpDriver == nil {
                        // Prompt Lookup (or MTP falling back to Prompt Lookup): build n-gram window from
                        // cached history + current suffix. The lookup window is capped at 512 tokens in
                        // PromptLookupDrafter so this is bounded even for long conversations.
                        let cachedTokens = Self.tokenize(vocab: vocab, text: renderPrompt(Array(sessionCache.turns)), addSpecial: true)
                        conversationTokens = cachedTokens + suffixTokens
                    }
                    // MTP with actual driver: conversationTokens stays empty — not needed.
                } else {
                    // Multimodal full-eval path: tokenize once here for the n-gram lookup window.
                    let promptTokens = Self.tokenize(vocab: vocab, text: renderPrompt(kept), addSpecial: true)
                    conversationTokens.append(contentsOf: promptTokens)
                }
            }

            let baseKvPos = incrementalSuffixTokens != nil ? sessionCache.tokenCount : cachedRollbackTokensCount
            var kvPos: llama_pos = Int32(baseKvPos + promptTokenCount)
            let physicalHeadroom = max(0, contextCap - Int(kvPos))
            let effectiveMaxTokens = (maxTokens > 0) ? min(maxTokens, physicalHeadroom) : physicalHeadroom
            var supportsKvRollback = true
            var consecutiveMisses = 0
            var backoffCooldown = 0

            let batchCapacity = Int32(1 + effectiveMaxDrafts + 2) // tokenID (1) + max drafts + safety margin
            var specBatch = llama_batch_init(batchCapacity, 0, 1)
            defer { llama_batch_free(specBatch) }

            var lastCheckpointUptime: UInt64 = DispatchTime.now().uptimeNanoseconds
            let checkpointIntervalNanos: UInt64 = 150_000_000
            var generatedTokens: [llama_token] = []

            while true {
                // Cooperative fast-path: check Task and governance cancellation synchronously with zero allocation
                if Task.isCancelled || governance.isCancelled {
                    throw CancellationError()
                }
                guard self.context == context else { throw CancellationError() }

                // Pause checkpoint: only yield into asynchronous wait when generation is actively paused
                if governance.isPaused {
                    try await governance.cooperativeCheckpoint()
                    guard self.context == context else { throw CancellationError() }
                }

                // Periodic thermal and system pressure checkpoint (~150ms cadence or every 32 tokens)
                let now = DispatchTime.now().uptimeNanoseconds
                if (genTokens & 0b11111 == 0) || (now >= lastCheckpointUptime && now - lastCheckpointUptime >= checkpointIntervalNanos) {
                    try await governance.checkpoint()
                    guard self.context == context else { throw CancellationError() }
                    lastCheckpointUptime = now
                }

                // Cooperative yield to system scheduler (every 64 tokens instead of 8, preventing GPU pipeline bubbles)
                if genTokens & 0b111111 == 0 && genTokens > 0 {
                    await Task.yield()
                    guard self.context == context else { throw CancellationError() }
                }

                if genTokens >= effectiveMaxTokens { stop = .maxTokens; break }
                let tokenID = llama_sampler_sample(sampler, context, -1)

                if llama_vocab_is_eog(vocab, tokenID) {
                    stop = .eos
                    if kvPos < contextCap {
                        Self.setBatchItem(&specBatch, at: 0, maxCapacity: batchCapacity, token: tokenID, pos: kvPos, logits: false)
                        specBatch.n_tokens = 1
                        _ = llama_decode(context, specBatch)
                        kvPos += 1
                    }
                    generatedTokens.append(tokenID)
                    break
                }

                let piece = Self.tokenToPiece(vocab: vocab, token: tokenID)
                let text = decoder.feed(piece)
                if !text.isEmpty {
                    toolGate.feed(text)
                    for d in splitter.feed(text) { emit(d) }
                }
                genTokens += 1
                generatedTokens.append(tokenID)
                if useSpeculative { conversationTokens.append(tokenID) }

                if genTokens >= effectiveMaxTokens {
                    if kvPos < contextCap {
                        Self.setBatchItem(&specBatch, at: 0, maxCapacity: batchCapacity, token: tokenID, pos: kvPos, logits: false)
                        specBatch.n_tokens = 1
                        _ = llama_decode(context, specBatch)
                        kvPos += 1
                    }
                    stop = .maxTokens
                    break
                }

                if !useSpeculative {
                    // Standard autoregressive fast-path: zero draft matching, zero token caching overhead
                    Self.setBatchItem(&specBatch, at: 0, maxCapacity: batchCapacity, token: tokenID, pos: kvPos, logits: true)
                    specBatch.n_tokens = 1
                    guard llama_decode(context, specBatch) == 0 else { throw EngineError.decodeFailed }
                    kvPos += 1
                } else {
                    let drafts: [llama_token]
                    let stepDriver: String
                    let remainingKvForDrafts = max(0, contextCap - Int(kvPos) - 1)
                    if supportsKvRollback && backoffCooldown == 0 && remainingKvForDrafts > 0 && !toolGate.isInsideToolCall {
                        let draftCap = min(effectiveMaxDrafts, remainingKvForDrafts)
                        if let mtpDriver {
                            let mtpDrafts = mtpDriver.predict(lastToken: tokenID, maxDrafts: draftCap)
                            if !mtpDrafts.isEmpty {
                                drafts = mtpDrafts
                                stepDriver = "Native MTP"
                            } else {
                                drafts = drafter.propose(from: conversationTokens)
                                stepDriver = "Prompt Lookup (Fallback)"
                            }
                        } else {
                            drafts = drafter.propose(from: conversationTokens)
                            stepDriver = (params.speculativeMode == .mtp) ? "Prompt Lookup (Fallback)" : "Prompt Lookup"
                        }
                    } else {
                        drafts = []
                        stepDriver = "None"
                        if backoffCooldown > 0 { backoffCooldown -= 1 }
                    }

                    if drafts.isEmpty {
                        Self.setBatchItem(&specBatch, at: 0, maxCapacity: batchCapacity, token: tokenID, pos: kvPos, logits: true)
                        specBatch.n_tokens = 1
                        guard llama_decode(context, specBatch) == 0 else { throw EngineError.decodeFailed }
                        kvPos += 1
                    } else {
                        let draftCount = min(drafts.count, Int(batchCapacity - 1), remainingKvForDrafts)
                        totalDraftedTokens += draftCount
                        if activeSpeculativeDriver == nil || stepDriver == "Native MTP" {
                            activeSpeculativeDriver = stepDriver
                        }
                        Self.setBatchItem(&specBatch, at: 0, maxCapacity: batchCapacity, token: tokenID, pos: kvPos, logits: true)
                        for dIdx in 0..<draftCount {
                            Self.setBatchItem(&specBatch, at: dIdx + 1, maxCapacity: batchCapacity, token: drafts[dIdx], pos: kvPos + Int32(dIdx + 1), logits: true)
                        }
                        specBatch.n_tokens = Int32(1 + draftCount)
                        guard llama_decode(context, specBatch) == 0 else { throw EngineError.decodeFailed }

                        var acceptedDrafts = 0
                        var hitEos = false
                        var hitMaxTokensInDrafts = false

                        for dIdx in 0..<draftCount {
                            let actual = llama_sampler_sample(sampler, context, Int32(dIdx))
                            if actual == drafts[dIdx] && !llama_vocab_is_eog(vocab, actual) {
                                let dPiece = Self.tokenToPiece(vocab: vocab, token: actual)
                                let dText = decoder.feed(dPiece)
                                if !dText.isEmpty {
                                    toolGate.feed(dText)
                                    for d in splitter.feed(dText) { emit(d) }
                                }
                                genTokens += 1
                                generatedTokens.append(actual)
                                conversationTokens.append(actual)
                                acceptedDrafts += 1
                                if genTokens >= effectiveMaxTokens {
                                    let discardFromPos = kvPos + 1 + Int32(acceptedDrafts)
                                    if acceptedDrafts < draftCount {
                                        let rmOk = llama_memory_seq_rm(llama_get_memory(context), 0, discardFromPos, -1)
                                        if !rmOk {
                                            supportsKvRollback = false
                                        }
                                    }
                                    kvPos = discardFromPos
                                    hitMaxTokensInDrafts = true
                                    break
                                }
                            } else {
                                let actualIsEog = llama_vocab_is_eog(vocab, actual)
                                if !actualIsEog {
                                    let aPiece = Self.tokenToPiece(vocab: vocab, token: actual)
                                    let aText = decoder.feed(aPiece)
                                    if !aText.isEmpty {
                                        toolGate.feed(aText)
                                        for d in splitter.feed(aText) { emit(d) }
                                    }
                                    genTokens += 1
                                    generatedTokens.append(actual)
                                    conversationTokens.append(actual)
                                } else {
                                    hitEos = true
                                    generatedTokens.append(actual)
                                }

                                let discardFromPos = kvPos + 1 + Int32(acceptedDrafts)
                                let rmOk = llama_memory_seq_rm(llama_get_memory(context), 0, discardFromPos, -1)
                                if !rmOk {
                                    supportsKvRollback = false
                                }

                                if discardFromPos < contextCap {
                                    Self.setBatchItem(&specBatch, at: 0, maxCapacity: batchCapacity, token: actual, pos: discardFromPos, logits: !actualIsEog)
                                    specBatch.n_tokens = 1
                                    _ = llama_decode(context, specBatch)
                                    kvPos = discardFromPos + 1
                                } else {
                                    kvPos = discardFromPos
                                }
                                break
                            }
                        }

                        totalAcceptedTokens += acceptedDrafts

                        if hitMaxTokensInDrafts {
                            stop = .maxTokens
                            break
                        }

                        if acceptedDrafts == draftCount {
                            kvPos += Int32(1 + draftCount)
                            consecutiveMisses = 0
                        } else {
                            consecutiveMisses += 1
                            if consecutiveMisses >= missThresholdForBackoff {
                                backoffCooldown = 16
                                consecutiveMisses = 0
                            }
                        }

                        if hitEos {
                            stop = .eos
                            break
                        }
                    }
                }
            }

            let tail = decoder.flush()
            if !tail.isEmpty { for d in splitter.feed(tail) { emit(d) } }
            for d in splitter.finish() { emit(d) }
            let strippedTail = answerStripper.isNoop ? "" : answerStripper.flush()
            if !strippedTail.isEmpty {
                if firstTokenTime == nil { firstTokenTime = Date() }
                cont.yield(.answer(strippedTail))
                fullGeneratedAnswer += strippedTail
            }

            let genSecs = max(Date().timeIntervalSince(genStart), 0.0001)
            peak = max(peak, Self.footprintBytes())

            let speculativeStatsResult: SpeculativeStats?
            if useSpeculative {
                let resolvedDriver = activeSpeculativeDriver ?? (
                    params.speculativeMode == .mtp ? (
                        hasMtpSupport && NativeMtpDriver.isCompiledIn ? "Native MTP" : "Prompt Lookup (Fallback)"
                    ) : "Prompt Lookup"
                )
                let s = SpeculativeStats(
                    driver: resolvedDriver,
                    draftedTokens: totalDraftedTokens,
                    acceptedTokens: totalAcceptedTokens
                )
                speculativeStatsResult = s
                NSLog("[LlamaEngine] Speculative stats: driver=%@, drafted=%d, accepted=%d (%.1f%%)",
                      resolvedDriver, totalDraftedTokens, totalAcceptedTokens,
                      s.acceptanceRate * 100.0)
            } else {
                speculativeStatsResult = nil
            }

            let ttftSeconds: Double? = firstTokenTime.map { max(0, $0.timeIntervalSince(prefillStart)) }
            if let ttft = ttftSeconds {
                let hitRatePct = (Double(cachedPromptTokensCount) / Double(max(1, cachedPromptTokensCount + promptTokenCount))) * 100.0
                NSLog("[LlamaEngine] TTFT: %.1f ms | Prompt cache: %d hit (%.1f%%)",
                      ttft * 1000.0, cachedPromptTokensCount, hitRatePct)
            }

            cont.yield(.done(Stats(
                promptTokens: promptTokenCount,
                genTokens: genTokens,
                promptTPS: Double(promptTokenCount) / promptSecs,
                tokensPerSecond: Double(genTokens) / genSecs,
                peakMemoryBytes: peak,
                stopReason: stop,
                speculativeStats: speculativeStatsResult,
                ttftSeconds: ttftSeconds,
                cachedPromptTokens: cachedPromptTokensCount,
                gpuLayers: Int(loadedGpuLayers),
                backend: loadedGpuLayers > 0 ? "Metal GPU" : "CPU",
                rollbackDiagnostic: rollbackDiagnosticMessage)))

            // Multi-turn and multimodal reuse: record valid conversational turn on natural EOS completion.
            // If KV rollback failed during speculative decoding, the physical KV cache is dirty and must not be reused.
            if stop == .eos && supportsKvRollback && answerStripper.isNoop && !fullGeneratedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let updatedTurns = kept + [ChatTurn(role: .assistant, content: fullGeneratedAnswer)]
                if let suffixTokens = incrementalSuffixTokens {
                    sessionCache.append(turns: updatedTurns,
                                        additionalTokens: suffixTokens + generatedTokens,
                                        additionalCount: suffixTokens.count + generatedTokens.count)
                } else if let promptTokens = prefilledPromptTokens {
                    sessionCache.commit(turns: updatedTurns,
                                        tokens: promptTokens + generatedTokens,
                                        count: promptTokens.count + generatedTokens.count)
                } else {
                    // Multimodal full evaluation (hasImages):
                    // No purely textual tokens to match for Prefix Rollback, but the total physical
                    // KV cache occupancy must be preserved so subsequent text turns can incrementally continue.
                    sessionCache.commitMultimodal(turns: updatedTurns,
                                                  count: promptTokenCount + generatedTokens.count)
                }
            } else {
                sessionCache.reset(context: context)
            }
            cont.finish()
        } catch is CancellationError {
            // Only purely incremental continuations (where the verified session prefix was never modified or rolled back)
            // can safely prune back to `initialCachedSessionTokenCount`. Any prefix-rollback or full-recompute path
            // altered the physical KV positions, so pruning to the old length would retain alien tokens and corrupt KV cache.
            // Furthermore, multimodal sessions carrying visual ViT embeddings must never undergo partial KV truncation (per e87379f).
            if isIncrementalContinuation, !sessionCache.hasImages, let context, initialCachedSessionTokenCount > 0 && initialCachedSessionTokensCount > 0 {
                // Retain previously verified conversational prefix: prune only uncommitted tokens added during this cancelled turn.
                if sessionCache.prune(to: initialCachedSessionTokenCount, context: context) {
                    NSLog("[LlamaEngine] Cancellation: retained %d prefix tokens (pruned uncommitted turn)", Int32(initialCachedSessionTokenCount))
                } else {
                    NSLog("[LlamaEngine] Cancellation: backend rejected partial sequence trim (hybrid/recurrent state), safely cleared entire session")
                }
            } else {
                sessionCache.reset(context: context)
            }
            cont.yield(.done(Stats(promptTokens: 0, genTokens: 0, promptTPS: 0, tokensPerSecond: 0,
                                   peakMemoryBytes: Self.footprintBytes(), stopReason: .cancelled)))
            cont.finish()
        } catch {
            sessionCache.reset(context: context)
            cont.finish(throwing: error)
        }
    }

    /// Session-only controls. The stream's termination callback still handles the ordinary Stop action.
    public nonisolated func pauseGeneration() { generationLifecycle.pauseActive() }
    public nonisolated func resumeGeneration() { generationLifecycle.resumeActive() }
    public nonisolated func cancelGeneration() { generationLifecycle.cancelActive() }

    // MARK: - Vision (mtmd)

    /// Tokens reserved per attached image in the context-fit math. A vision encoder emits on the order of a
    /// few hundred embedding tokens per image (it varies with the model's tiling / input resolution); ~600
    /// is a deliberately safe upper bound that keeps the KV budget honest without starving the text. It is
    /// a reservation for FITTING only — the true image-token count comes back from mtmd after tokenization.
    static let imageTokenBudget = 600

    /// Total image-token reservation for a set of turns: `imageTokenBudget` per attached image. Zero for a
    /// text-only history, so adding this term to the fit's token count is a no-op on the text path.
    static func imageTokenCount(_ messages: [ChatTurn]) -> Int {
        messages.reduce(0) { $0 + $1.images.count } * imageTokenBudget
    }

    /// Prefix one media marker (each on its own line) per attached image to the content of every
    /// image-bearing turn, leaving text-only turns untouched. The rendered prompt then carries exactly one
    /// marker per image, in turn/image order, which is what `mtmd_tokenize` needs to interleave the image
    /// chunks. Pure (the marker is injected, not read from the C library) so it unit-tests without a model;
    /// with no images anywhere it returns the input unchanged, so the no-image prompt is byte-for-byte as
    /// before.
    static func injectMediaMarkers(_ messages: [ChatTurn], marker: String) -> [ChatTurn] {
        messages.map { turn in
            guard !turn.images.isEmpty else { return turn }
            let prefix = String(repeating: marker + "\n", count: turn.images.count)
            return ChatTurn(role: turn.role, content: prefix + turn.content, images: turn.images)
        }
    }

    /// Multimodal prefill: render the kept turns with a media marker injected per attached image, split the
    /// text + images into mtmd chunks, and evaluate them chunk-by-chunk into the live context's KV cache
    /// (image encode → decode for image chunks, plain decode for text) so the ordinary decode loop can
    /// continue from the end of the prefill. Returns the total prefilled token count (text + image tokens)
    /// for the stats line. Cancellation-checked and yields between chunks (chunk-level granularity is
    /// acceptable), bailing via the reentrancy guard if a concurrent reload swaps the context out.
    private func mtmdPrefill(kept: [ChatTurn], context: OpaquePointer,
                             renderPrompt: ([ChatTurn]) -> String, nBatch: Int,
                             governance: GenerationGovernance) async throws -> Int {
        guard let mtmdCtx = mtmdContext else { throw EngineError.visionUnavailable }
        let marker = String(cString: mtmd_default_marker())
        let promptText = renderPrompt(Self.injectMediaMarkers(kept, marker: marker))

        // Decode each attached image (encoded JPEG/PNG bytes) into an mtmd bitmap, in prompt order.
        var bitmaps: [OpaquePointer?] = []
        defer { for b in bitmaps { if let b { mtmd_bitmap_free(b) } } }
        for turn in kept {
            for image in turn.images {
                try await governance.checkpoint()
                guard self.context == context else { throw CancellationError() }
                let preparedImage = Self.downsampleImageDataIfNeeded(image)
                let wrapper: mtmd_helper_bitmap_wrapper = preparedImage.withUnsafeBytes { raw in
                    mtmd_helper_bitmap_init_from_buf(mtmdCtx, raw.bindMemory(to: UInt8.self).baseAddress,
                                                     preparedImage.count, false, mtmd_helper_init_opt_default())
                }
                guard let bmp = wrapper.bitmap else { throw EngineError.imageDecodeFailed }
                bitmaps.append(bmp)
            }
        }

        // Split the text + bitmaps into chunks (marker count == bitmap count by construction).
        guard let chunks = mtmd_input_chunks_init() else { throw EngineError.imageDecodeFailed }
        defer { mtmd_input_chunks_free(chunks) }
        let tokenizeRC: Int32 = promptText.withCString { cText -> Int32 in
            // text_len in BYTES (matches the text path's `utf8.count`), robust to any embedded null.
            var input = mtmd_input_text(text: cText, text_len: promptText.utf8.count,
                                        add_special: true, parse_special: true)
            var bmpArray = bitmaps
            return bmpArray.withUnsafeMutableBufferPointer { buf in
                mtmd_tokenize(mtmdCtx, chunks, &input, buf.baseAddress, bitmaps.count)
            }
        }
        guard tokenizeRC == 0 else { throw EngineError.imageDecodeFailed }

        // Evaluate chunk-by-chunk into the KV cache; only the last chunk needs logits (for the first sample).
        let nChunks = mtmd_input_chunks_size(chunks)
        var nPast: llama_pos = 0
        for idx in 0..<nChunks {
            try await governance.checkpoint()
            guard self.context == context else { throw CancellationError() }
            guard let chunk = mtmd_input_chunks_get(chunks, idx) else { throw EngineError.decodeFailed }
            let isLast = idx == nChunks - 1
            var newNPast: llama_pos = 0
            let rc = mtmd_helper_eval_chunk_single(mtmdCtx, context, chunk, nPast, /*seq_id*/ 0,
                                                   Int32(nBatch), /*logits_last*/ isLast, &newNPast)
            guard rc == 0 else { throw EngineError.decodeFailed }
            nPast = newNPast
            await Task.yield()
            guard self.context == context else { throw CancellationError() }   // reentrant teardown
        }
        return Int(mtmd_helper_get_n_tokens(chunks))
    }

    /// Downsample large input images (e.g. 12MP/48MP camera shots) to an optimal max dimension
    /// before feeding into mtmd. Avoids massive visual patch explosion (1500+ tokens) and
    /// extreme memory pressure / fc-thrashing on iOS Metal.
    static func downsampleImageDataIfNeeded(_ data: Data, maxDimension: CGFloat = 1024) -> Data {
        #if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return data }

        let propertiesOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, propertiesOptions) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
           width <= maxDimension && height <= maxDimension {
            return data
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let downsampled = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return data
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return data
        }
        let writeOptions = [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        CGImageDestinationAddImage(destination, downsampled, writeOptions)
        guard CGImageDestinationFinalize(destination) else { return data }
        return output as Data
        #else
        return data
        #endif
    }

    // MARK: - Prompt / tokenizer helpers

    /// Serialize the chat history into the model's prompt string, dispatching on its `PromptTemplate`
    /// and appending the reasoning-control suffix for its `ReasoningStyle`. `thinking` is the effective
    /// per-turn choice (the caller has already ANDed it with the model's capability).
    ///
    /// BOS POLICY (all builders): a builder NEVER writes a literal begin-of-sentence token. Tokenization
    /// runs with `addSpecial: true`, so llama.cpp prepends the GGUF's own BOS whenever its metadata sets
    /// `add_bos_token=true`; a literal BOS in the string would then be a SECOND one (`parse_special: true`
    /// re-tokenizes it), which measurably degrades output. The ChatML/Gemma builders always relied on this;
    /// the DeepSeek/Hunyuan builders now do too. `PromptBuilderTests` pins that no builder output emits one.
    static func buildPrompt(messages: [ChatTurn], template: PromptTemplate,
                            reasoning: ReasoningStyle, thinking: Bool) -> String {
        switch template {
        case .chatML:   return chatMLPrompt(messages, reasoning: reasoning, thinking: thinking)
        case .deepSeek: return deepSeekPrompt(messages, reasoning: reasoning, thinking: thinking)
        case .hunyuan:  return hunyuanPrompt(messages, reasoning: reasoning, thinking: thinking)
        case .gemma:    return gemmaPrompt(messages)
        case .auto:     return chatMLPrompt(messages, reasoning: reasoning, thinking: thinking)  // fallback
        }
    }

    /// Choose the chat turns whose rendered prompt fits `budget` tokens, for context-overflow handling.
    ///
    /// Policy: keep EVERY system turn and the final turn (the user's current query) unconditionally; if the
    /// whole history overflows, drop whole non-system turns oldest-first, re-measuring after each drop, and
    /// stop as soon as it fits — so the system prefix and the live question always survive and the newest
    /// history is preferred. Returns the kept messages, or `nil` when even {all system turns + the final
    /// turn} overflows (the caller fails with `.contextWindowExceeded` rather than truncate mid-token).
    ///
    /// Pure + tokenizer-free: `tokenCount` renders and measures a candidate (injected so the selection is
    /// unit-testable without loading a model). Called at most once per droppable turn.
    static func fitMessages(_ messages: [ChatTurn], budget: Int,
                            tokenCount: ([ChatTurn]) -> Int) -> [ChatTurn]? {
        if tokenCount(messages) <= budget { return messages }
        // Droppable = non-system turns except the final one, oldest first (ascending index order).
        let lastIndex = messages.indices.last
        let droppable = messages.indices.filter { $0 != lastIndex && messages[$0].role != .system }
        var removed = Set<Int>()
        for idx in droppable {
            removed.insert(idx)
            let kept = messages.enumerated().filter { !removed.contains($0.offset) }.map { $0.element }
            if tokenCount(kept) <= budget { return kept }
        }
        // Nothing droppable is left: only the system prefix and the final turn remain.
        let minimal = messages.enumerated().filter { !removed.contains($0.offset) }.map { $0.element }
        return tokenCount(minimal) <= budget ? minimal : nil
    }

    /// Output space reserved by context fitting. A positive request is a hard promise and must be
    /// reserved in full; `0` retains the existing "unbounded generation" meaning and uses a finite
    /// 256-token planning reserve so a prompt can still be admitted.
    static func answerTokenReserve(maxTokens: Int) -> Int {
        max(8, maxTokens > 0 ? maxTokens : 256)
    }

    /// Render the prompt with the template EMBEDDED IN THE GGUF via llama.cpp — the path for arbitrary
    /// community checkpoints (Explore), where no hand-written builder exists. Returns nil when the model
    /// ships no template or llama.cpp can't render it, so the caller can fall back to ChatML.
    static func autoPrompt(_ messages: [ChatTurn], modelPtr: OpaquePointer,
                           reasoning: ReasoningStyle, thinking: Bool) -> String? {
        guard let tmpl = llama_model_chat_template(modelPtr, nil) else { return nil }
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        var chat: [llama_chat_message] = []
        for m in messages {
            let role: String
            switch m.role { case .system: role = "system"; case .user: role = "user"; case .assistant: role = "assistant" }
            guard let r = strdup(role), let c = strdup(m.content) else { return nil }
            owned.append(r); owned.append(c)
            chat.append(llama_chat_message(role: UnsafePointer(r), content: UnsafePointer(c)))
        }
        var buf = [CChar](repeating: 0, count: 1 << 15)
        var n = chat.withUnsafeBufferPointer {
            llama_chat_apply_template(tmpl, $0.baseAddress, chat.count, true, &buf, Int32(buf.count))
        }
        if n > Int32(buf.count) {                       // grow once if the template needs more room
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = chat.withUnsafeBufferPointer {
                llama_chat_apply_template(tmpl, $0.baseAddress, chat.count, true, &buf, Int32(buf.count))
            }
        }
        guard n > 0 else { return nil }
        let rendered = String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return rendered + thinkSuffix(reasoning, thinking: thinking)
    }

    /// The `<think>` control suffix appended after the assistant-turn opener:
    /// - `.thinkTags` — the model emits its own `<think>`: nothing when thinking, an empty closed block
    ///   to suppress reasoning when not.
    /// - `.thinkTagsImplicitOpen` — the template pre-fills the opening tag: an open `<think>\n` when
    ///   thinking (the stream begins inside the block), the empty closed block to suppress when not.
    static func thinkSuffix(_ reasoning: ReasoningStyle, thinking: Bool) -> String {
        switch reasoning {
        case .none: return ""
        case .thinkTags: return thinking ? "" : "<think>\n\n</think>\n\n"
        case .thinkTagsImplicitOpen: return thinking ? "<think>\n" : "<think>\n\n</think>\n\n"
        }
    }

    /// ChatML (Qwen3/3.5/3.6, MiniCPM5, Bonsai): `<|im_start|>role\n…<|im_end|>\n`, then the assistant
    /// opener + think suffix.
    static func chatMLPrompt(_ messages: [ChatTurn], reasoning: ReasoningStyle, thinking: Bool) -> String {
        var s = ""
        for m in messages {
            let role: String
            switch m.role { case .system: role = "system"; case .user: role = "user"; case .assistant: role = "assistant" }
            s += "<|im_start|>\(role)\n\(m.content)<|im_end|>\n"
        }
        s += "<|im_start|>assistant\n"
        return s + thinkSuffix(reasoning, thinking: thinking)
    }

    /// DeepSeek(-R1 distills): raw system, then each USER turn already carries the trailing `<｜Assistant｜>`
    /// opener; assistant history turns end with the DeepSeek EOS. The model emits its own `<think>`
    /// (explicit), so no opener is pre-filled unless we suppress. The leading `<｜begin▁of▁sentence｜>` is
    /// NOT written here — `tokenize(addSpecial: true)` owns the BOS (see `buildPrompt`'s BOS policy).
    static func deepSeekPrompt(_ messages: [ChatTurn], reasoning: ReasoningStyle, thinking: Bool) -> String {
        let eos = "<｜end▁of▁sentence｜>"
        var s = coalescedSystemPrompt(messages)
        for m in messages {
            switch m.role {
            case .system: break
            case .user: s += "<｜User｜>\(m.content)<｜Assistant｜>"
            case .assistant: s += "\(m.content)\(eos)"
            }
        }
        return s + thinkSuffix(reasoning, thinking: thinking)
    }

    /// Tencent Hunyuan: raw system, then each USER turn carries the trailing `<｜hy_Assistant｜>` opener;
    /// assistant history turns end with the Hunyuan EOS. Explicit `<think>`. The leading
    /// `<｜hy_begin▁of▁sentence｜>` is NOT written here — `tokenize(addSpecial: true)` owns the BOS (see
    /// `buildPrompt`'s BOS policy).
    static func hunyuanPrompt(_ messages: [ChatTurn], reasoning: ReasoningStyle, thinking: Bool) -> String {
        let eos = "<｜hy_place▁holder▁no▁2｜>"
        var s = coalescedSystemPrompt(messages)
        for m in messages {
            switch m.role {
            case .system: break
            case .user: s += "<｜hy_User｜>\(m.content)<｜hy_Assistant｜>"
            case .assistant: s += "\(m.content)\(eos)"
            }
        }
        return s + thinkSuffix(reasoning, thinking: thinking)
    }

    /// Raw-system templates have one system slot. Preserve every system turn in encounter order and
    /// separate them explicitly so an auto-compaction breadcrumb cannot run into the base instruction.
    static func coalescedSystemPrompt(_ messages: [ChatTurn]) -> String {
        messages.lazy
            .filter { $0.role == .system && !$0.content.isEmpty }
            .map(\.content)
            .joined(separator: "\n\n")
    }

    /// Google Gemma 4: asymmetric turn markers — `<|turn>role\n…<turn|>\n` per turn, then the model
    /// opener `<|turn>model\n`. Shipped non-thinking (reasoning `.none`): with no thinking token injected
    /// the model answers directly, so no `<|channel>thought` channel appears. BOS is added by the
    /// tokenizer (add_special), not written here. (assistant role → "model".)
    static func gemmaPrompt(_ messages: [ChatTurn]) -> String {
        var s = ""
        for m in messages {
            let role: String
            switch m.role { case .system: role = "system"; case .user: role = "user"; case .assistant: role = "model" }
            s += "<|turn>\(role)\n\(m.content)<turn|>\n"
        }
        s += "<|turn>model\n"
        return s
    }

    static func tokenize(vocab: OpaquePointer, text: String, addSpecial: Bool) -> [llama_token] {
        let cap = Int32(text.utf8.count + 2)
        var tokens = [llama_token](repeating: 0, count: Int(cap))
        let n = text.withCString { cstr in
            llama_tokenize(vocab, cstr, Int32(text.utf8.count), &tokens, cap, addSpecial, /*parse_special*/ true)
        }
        if n < 0 { return [] }
        return Array(tokens.prefix(Int(n)))
    }

    /// Token → raw bytes (no null terminator). Grows the buffer if a single piece needs > 16 bytes.
    static func tokenToPiece(vocab: OpaquePointer, token: llama_token) -> [CChar] {
        var buf = [CChar](repeating: 0, count: 16)
        let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, /*special*/ false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            let n2 = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
            return Array(buf.prefix(Int(max(0, n2))))
        }
        return Array(buf.prefix(Int(n)))
    }

    /// A sampler chain matching the app's `Sampling`: penalties → top-k → top-p → temp → dist, or greedy
    /// when temperature is ~0. Order follows the llama.cpp convention.
    static func makeSampler(vocab: OpaquePointer, params: Sampling) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        if params.repetitionPenalty > 1.0 {
            let nVocab = llama_vocab_n_tokens(vocab)
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(nVocab, 64, Int32(params.repetitionPenalty), 0, 0))
        }
        if params.temperature <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
            return chain
        }
        if params.topK > 0 { llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(params.topK))) }
        if params.topP < 1.0 { llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(params.topP), 1)) }
        llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(params.temperature)))
        let seed = params.seed.map { UInt32(truncatingIfNeeded: $0) } ?? 0xFFFF_FFFF   // 0xFFFFFFFF = random
        llama_sampler_chain_add(chain, llama_sampler_init_dist(seed))
        return chain
    }

    static func resolveGGUF(in dir: URL, preferred: String?) throws -> String {
        let fm = FileManager.default
        if let preferred {
            let p = dir.appendingPathComponent(preferred)
            if fm.fileExists(atPath: p.path) { return p.path }
        }
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if let gguf = contents.first(where: { $0.pathExtension.lowercased() == "gguf" }) { return gguf.path }
        // A single-file download may have landed at `dir` itself.
        if dir.pathExtension.lowercased() == "gguf", fm.fileExists(atPath: dir.path) { return dir.path }
        throw EngineError.weightsNotFound
    }

    /// Resolve a vision projector (mmproj) file to load. Order: (1) an absolute `fileName` that exists — the
    /// CLI `--mmproj` escape hatch; (2) `dir/fileName`, where the downloader places it beside the GGUF; (3)
    /// a basename match anywhere in `dir`. Returns nil when the projector isn't present (the caller then
    /// runs text-only, and an image later throws `.visionUnavailable`).
    static func resolveProjector(in dir: URL, fileName: String) -> String? {
        let fm = FileManager.default
        if fileName.hasPrefix("/"), fm.fileExists(atPath: fileName) { return fileName }
        let direct = dir.appendingPathComponent(fileName)
        if fm.fileExists(atPath: direct.path) { return direct.path }
        let base = (fileName as NSString).lastPathComponent
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if let hit = contents.first(where: { $0.lastPathComponent == base }) { return hit.path }
        return nil
    }

    /// Literal answer-wrapper tags to strip from the answer stream for a given template. Hunyuan wraps its
    /// final answer in `<answer>…</answer>`; the ChatML/DeepSeek families don't wrap.
    static func answerStripTags(for template: PromptTemplate) -> [String] {
        switch template {
        case .hunyuan: ["<answer>", "</answer>"]
        case .chatML, .deepSeek, .gemma, .auto: []
        }
    }

    /// Current resident footprint (`phys_footprint` — dirty + compressed, the number iOS jetsams on).
    static func footprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    /// Sets up a slot in a `llama_batch` with explicit position and logits flags.
    private static func setBatchItem(_ batch: inout llama_batch, at i: Int, maxCapacity: Int32 = 8, token: llama_token, pos: llama_pos, logits: Bool) {
        guard i >= 0 && i < Int(maxCapacity) else {
            assertionFailure("[LlamaEngine] Batch slot index \(i) exceeds allocated capacity \(maxCapacity)")
            return
        }
        batch.token[i] = token
        batch.pos[i] = pos
        batch.n_seq_id[i] = 1
        if let seqPtr = batch.seq_id[i] {
            seqPtr.pointee = 0
        }
        batch.logits[i] = logits ? 1 : 0
    }

    /// Encapsulates conversational session cache state (physical KV context & logical tokens/turns).
    /// Enforces the invariant that partial prune failure automatically resets the entire session.
    private struct SessionCacheState {
        private(set) var turns: [ChatTurn] = []
        private(set) var tokens: [llama_token] = []
        private(set) var tokenCount: Int = 0

        var isEmpty: Bool { turns.isEmpty && tokens.isEmpty && tokenCount == 0 }
        var hasImages: Bool { turns.contains { !$0.images.isEmpty } }

        /// Reset physical KV memory (if context is non-nil) and clear all Swift state.
        mutating func reset(context: OpaquePointer? = nil) {
            if let context {
                llama_memory_clear(llama_get_memory(context), true)
            }
            turns.removeAll()
            tokens.removeAll()
            tokenCount = 0
        }

        /// Prune the session cache to `count` tokens.
        /// If llama_memory_seq_rm succeeds, trims `tokens` and updates `tokenCount`.
        /// If it fails (e.g. hybrid SSM / recurrent state rejection on Qwen 3.5),
        /// it automatically performs a full `reset(context:)` to enforce consistency.
        @discardableResult
        mutating func prune(to count: Int, context: OpaquePointer?) -> Bool {
            guard let context else {
                reset()
                return false
            }
            let rmOk = llama_memory_seq_rm(llama_get_memory(context), 0, Int32(count), -1)
            if rmOk {
                if tokens.count > count {
                    tokens = Array(tokens.prefix(count))
                }
                tokenCount = count
                return true
            } else {
                reset(context: context)
                return false
            }
        }

        /// Commit full turns, tokens, and count on natural completion.
        mutating func commit(turns: [ChatTurn], tokens: [llama_token], count: Int) {
            self.turns = turns
            self.tokens = tokens
            self.tokenCount = count
        }

        /// Append tokens to existing session cache on incremental suffix turn.
        mutating func append(turns: [ChatTurn], additionalTokens: [llama_token], additionalCount: Int) {
            self.turns = turns
            if !tokens.isEmpty {
                self.tokens.append(contentsOf: additionalTokens)
            }
            self.tokenCount += additionalCount
        }

        /// Multimodal full evaluation commit: physical count tracked, but no pure text tokens.
        mutating func commitMultimodal(turns: [ChatTurn], count: Int) {
            self.turns = turns
            self.tokens.removeAll()
            self.tokenCount = count
        }
    }

    /// Lightweight spec gate to detect tool-call blocks and suppress draft speculation during structured output.
    private struct ToolCallSpeculationGate {
        private(set) var isInsideToolCall: Bool = false
        private var tailBuffer: String = ""

        mutating func feed(_ chunk: String) {
            guard !chunk.isEmpty else { return }
            tailBuffer += chunk
            if tailBuffer.count > 256 {
                tailBuffer = String(tailBuffer.suffix(256))
            }

            if !isInsideToolCall {
                if tailBuffer.contains("<tool_call>") ||
                   tailBuffer.contains("<tool_call") ||
                   tailBuffer.contains("<|tool_call") ||
                   tailBuffer.contains("<｜tool") ||
                   tailBuffer.contains("{\"name\":") ||
                   tailBuffer.contains("{\\\"name\\\":") {
                    isInsideToolCall = true
                }
            } else {
                if tailBuffer.contains("</tool_call>") ||
                   tailBuffer.contains("<tool_call|>") ||
                   tailBuffer.contains("call▁end｜>") ||
                   tailBuffer.contains("}</tool_call>") {
                    isInsideToolCall = false
                }
            }
        }
    }
}
