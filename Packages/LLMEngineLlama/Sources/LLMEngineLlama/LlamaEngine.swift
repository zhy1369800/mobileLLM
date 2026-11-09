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
#if canImport(Darwin)
import Darwin
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
    private var contextBatchSize: Int = 0    // the actual effective n_batch / n_ubatch the live context was built with
    private var contextRequestedBatchSize: Int = 0
    private var contextSpeculativeMode: SpeculativeMode = .off
    private var sessionCache = SessionCacheState()
    /// Saved "prompt fully prefilled" checkpoints (via llama_state_seq_save_file), keyed by logical
    /// turn count at save time. Lets edit-resend reuse a whole-sequence state even when seq_rm is
    /// rejected (Qwen 3.5 hybrid Gated DeltaNet / recurrent state). LRU-capped and cleared whenever
    /// the context is rebuilt (KV layout / dtype no longer matches the saved files).
    private var checkpoints: [Int: SessionCheckpoint] = [:]
    /// Insertion order of checkpoint keys (oldest first), used for LRU eviction.
    private var checkpointOrder: [Int] = []
    /// Compatibility signature of the currently saved checkpoints. Snapshots survive transient
    /// `unload()` calls (e.g. backgrounding / leaving chat) and are cleared only when a different
    /// model/variant is loaded or when context capacity / KV dtype / speculative layout changes.
    private var checkpointModelKey: String? = nil
    private var checkpointContextCap: Int = 0
    private var checkpointKVBits: Int = -1
    private var checkpointIsSpeculative: Bool = false
    /// LRU cap: keep the 3 most recent snapshots (previous turn's completed EOS base + current
    /// turn's prefilled prompt + current turn's completed EOS base), so both Regenerate and
    /// Edit-Resend on the latest turn hit a matching prefix boundary.
    private static let checkpointMaxSlots = 3
    /// Recurrent-state rollback snapshots (`n_rs_seq`) for hybrid architectures (Qwen 3.5 Gated
    /// DeltaNet). Lets `llama_memory_seq_rm` rewind up to this many tokens without recompute — covers
    /// single-token regenerates, but a message edit cuts hundreds+ tokens deep, which always exceeds
    /// the depth budget, so edit-resend reuse is served by the file checkpoint instead of these slots.
    /// Allocated only while speculative decoding is active (short draft-verification rollbacks); 0
    /// during standard generation saves recurrent S memory ×(1+n_rs_seq) — Qwen3.5-4B adds ~24 MiB
    /// per slot, so 2 slots = ~48 MiB; larger models (7B+) scale proportionally.
    /// Attention-only architectures are clamped to 0 inside llama.cpp, so this is safe for every model.
    private static let rsRollbackSlots: UInt32 = 2
    private var checkpointDirectory: URL? = nil
    /// Filesystem-safe per-model prefix for checkpoint files. The model id (e.g. "mlx-community/…")
    /// may contain path separators and spaces, so it is scrubbed and length-bounded; scoping files per
    /// model keeps two engines (or two models over time) from clobbering each other's snapshots.
    private var checkpointFilePrefix: String {
        guard let loadedID else { return "ckpt-unknown-" }
        let scrubbed = loadedID.map { ch in
            ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_" ? ch : "_"
        }
        return "ckpt-\(String(scrubbed.prefix(48)))-"
    }
    private var loadedID: String?
    private var loadedModelKey: String?
    private var thinkingCapable = true
    private var eosText = "<|im_end|>"
    private var promptTemplate: PromptTemplate = .chatML
    private var reasoningStyle: ReasoningStyle = .thinkTags
    /// Whether the currently loaded model declares MTP / nextn draft prediction layers.
    public private(set) var hasMtpSupport: Bool = false
    /// Tracks whether the active backend/model architecture supports partial KV cache trimming via seq_rm.
    /// Initialized to true on load; if rejected (e.g. Qwen 3.5 hybrid Gated DeltaNet state), further attempts are bypassed.
    private var supportsPartialTrim: Bool = true
    private var loadedGpuLayers: Int32 = 0
    nonisolated private let generationLifecycle = GenerationLifecycle()
    nonisolated private let governanceFactory: GovernanceFactory

    private static func computeOptimalThreads() -> Int32 {
        #if canImport(Darwin)
        var pCores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &pCores, &size, nil, 0) == 0, pCores > 0 {
            #if os(iOS)
            // On iPhone/iPad, clamp strictly to physical performance cores (typically 2 on iPhone,
            // up to 4 on iPad) so worker threads never spill onto efficiency cores and spin-wait.
            return min(pCores, 4)
            #else
            return min(pCores, 8)
            #endif
        }
        #endif

        #if os(iOS)
        // Baseline iOS fallback: limit to 2 threads (standard iPhone performance core count).
        return min(2, max(1, Int32(ProcessInfo.processInfo.activeProcessorCount - 2)))
        #else
        return Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        #endif
    }

    private let nThreads: Int32 = computeOptimalThreads()

    /// llama.cpp's weights are mmap-backed, so there is no accelerator reuse cache to purge. The
    /// production governor still observes memory pressure and performs thermal pacing; tests inject a
    /// recorder through this factory without loading a GGUF.
    public init(governanceFactory: @escaping GovernanceFactory = {
        GenerationGovernance()
    }) {
        self.governanceFactory = governanceFactory
        // Residual-checkpoint cleanup deliberately does NOT run here: engine construction must not
        // delete shared on-disk state, or a second instance would wipe the first one's snapshots.
        // The startup sweep lives on the App launch path (mobileLLMApp.swift) before engines exist.
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
        let newModelKey = "\(modelSpec.id)|\(variant.id)"
        if let existingKey = checkpointModelKey, existingKey != newModelKey {
            clearCheckpoints()
        }
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
        loadedModelKey = newModelKey
        loadedGpuLayers = mp.n_gpu_layers
        thinkingCapable = modelSpec.architecture.thinkingCapable
        eosText = modelSpec.architecture.eos
        promptTemplate = modelSpec.architecture.promptTemplate
        reasoningStyle = modelSpec.architecture.reasoningStyle
        hasMtpSupport = MtpDetector.detectMtpSupport(model: m)
        supportsPartialTrim = true
        NSLog("[LlamaEngine] Model loaded: id=%@, MTP supported=%d, gpu_layers=%d",
              modelSpec.id, hasMtpSupport ? 1 : 0, loadedGpuLayers)
        context = nil; contextCap = 0; contextKVBits = -1; contextBatchSize = 0; contextRequestedBatchSize = 0; contextSpeculativeMode = .off

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
        context = nil; model = nil; vocab = nil; loadedID = nil; loadedModelKey = nil; contextCap = 0; contextKVBits = -1; contextBatchSize = 0; contextRequestedBatchSize = 0
        loadedGpuLayers = 0
        hasMtpSupport = false
        supportsPartialTrim = true
        sessionCache.reset()
    }

    // MARK: - Session checkpoints (edit-resend whole-sequence reuse)

    /// A saved "prompt fully prefilled" snapshot for one logical turn boundary. Written by
    /// `llama_state_seq_save_file` right after prefill and BEFORE generation starts, so it captures
    /// exactly the prompt state (no generated tokens) — the same boundary `turnPromptEndPositions`
    /// records for the seq_rm regenerate path. On restore the KV / recurrent state is reloaded and only
    /// the tokens after the edit point are decoded.
    private struct SessionCheckpoint {
        let turnCount: Int                   // kept.count at save time
        let promptEndPos: Int                // logical KV position (llama_pos) where the snapshot ended
        let extraVisualTokens: Int           // extra physical KV slots occupied by M-RoPE images beyond promptEndPos
        let filePath: String
        let tokens: [llama_token]            // token header saved in the file (for round-trip check)
        let renderedTokens: [llama_token]    // canonical rendered prompt tokens (for prefix validation)
        let turns: [ChatTurn]                // kept turns at save time, to rebuild sessionCache.turns on restore
        let hasImages: Bool                  // whether the captured KV state includes multimodal ViT embeddings

        var physicalEndPos: Int { promptEndPos + extraVisualTokens }
    }

    private func checkpointDirectoryURL() -> URL? {
        if let checkpointDirectory { return checkpointDirectory }
        // Documents/Checkpoints (not tmp) so the files show up in Files → On My iPhone → mobileLLM.
        // UIFileSharingEnabled is already on in Info.plist, so anything under Documents is visible.
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Checkpoints", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Exclude from iCloud backup: snapshots are engine-internal caches (≈96–280 MiB each at 8K
        // context), regenerated on demand — backing them up wastes iCloud quota. Mirrors the
        // Documents/models exclusion in mobileLLMApp.setupModelStorageBase. saveCheckpoint() also
        // marks each newly written file, since new files do not inherit the directory's attribute.
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDir = dir
        try? mutableDir.setResourceValues(resourceValues)
        // Sweep stale checkpoint files that cannot belong to the currently loaded model (e.g. a
        // previous model/session left them when the app was killed). Files sharing our per-model
        // prefix are kept: another live context (e.g. a second engine instance on the same model)
        // may still own them, and deleting them here would silently zero its cache-hit rate.
        if let stale = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in stale where url.lastPathComponent.hasPrefix("ckpt-") {
                if !url.lastPathComponent.hasPrefix(checkpointFilePrefix) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        checkpointDirectory = dir
        return dir
    }

    /// Remove all checkpoint files and the in-memory index. Called on model switch and whenever the
    /// context layout / dtype changes — the saved KV layout / dtype no longer matches.
    private func clearCheckpoints() {
        checkpoints.removeAll()
        checkpointOrder.removeAll()
        checkpointModelKey = nil
        checkpointContextCap = 0
        checkpointKVBits = -1
        checkpointIsSpeculative = false
        if let dir = checkpointDirectory {
            try? FileManager.default.removeItem(at: dir)
            checkpointDirectory = nil
        }
    }

    /// Clean up any leftover checkpoint directories from previous runs. Safe to call at startup or teardown.
    public static func cleanupResidualCheckpoints() {
        // Must match checkpointDirectoryURL(): Documents/Checkpoints (visible in Files app).
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Checkpoints", isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
            NSLog("[LlamaEngine] Residual checkpoint directory cleaned up: %@", dir.path)
        }
    }

    /// Save a "prompt fully prefilled" checkpoint for `turnCount`. Failures are never fatal — a
    /// checkpoint is a pure optimization; without one edit-resend simply falls back to full recompute.
    ///
    /// Short contexts (≤ 1024 tokens) are skipped: full-prefill takes < 0.5 s and the checkpoint
    /// overhead is not worth it.
    /// NOTE: the C-layer write (~100–300 ms for an 8K Q8_0 snapshot) currently runs SYNCHRONOUSLY on
    /// the actor — callers invoke this right after prefill and before the first decode, so the write
    /// adds to TTFT and blocks other actor calls (unload/cancel) while it is in flight. TODO: move the
    /// write off the actor (snapshot state to memory first, then write from a background task) if the
    /// TTFT impact matters.
    private func saveCheckpoint(turnCount: Int,
                                promptTokens: [llama_token],
                                renderedTokens: [llama_token]? = nil,
                                promptEndPos: Int? = nil,
                                extraVisualTokens: Int = 0,
                                turns: [ChatTurn],
                                hasImages: Bool = false,
                                context: OpaquePointer) {
        let canonicalTokens = (renderedTokens?.isEmpty == false) ? renderedTokens! : promptTokens
        let effectiveEndPos = promptEndPos ?? promptTokens.count
        guard !promptTokens.isEmpty, !turns.isEmpty, effectiveEndPos > 0 else {
            NSLog("[LlamaEngine][Checkpoint] saveCheckpoint skipped: empty tokens or turns")
            return
        }
        // Short-context skip for pure text (≤ 1024 tokens): full recompute is < 0.5 s.
        // Multimodal checkpoints are ALWAYS saved regardless of token count because ViT image encoding
        // takes 2–5 seconds even on a short 1-turn prompt.
        if !hasImages && effectiveEndPos <= 1024 {
            NSLog("[LlamaEngine][Checkpoint] saveCheckpoint skipped: tokens=%d <= 1024", Int32(effectiveEndPos))
            return
        }
        // Same-turn boundary with identical prompt and turns: already saved, skip the disk write.
        if let existing = checkpoints[turnCount],
           existing.promptEndPos == effectiveEndPos,
           existing.extraVisualTokens == extraVisualTokens,
           existing.tokens == promptTokens,
           existing.renderedTokens == canonicalTokens,
           existing.turns == turns,
           FileManager.default.fileExists(atPath: existing.filePath) {
            NSLog("[LlamaEngine][Checkpoint] saveCheckpoint skipped: turn %d identical to existing checkpoint", Int32(turnCount))
            return
        }
        guard let dir = checkpointDirectoryURL() else {
            NSLog("[LlamaEngine][Checkpoint] saveCheckpoint failed: cannot resolve directory")
            return
        }
        let filePath = dir.appendingPathComponent("\(checkpointFilePrefix)\(turnCount).bin").path
        let tokensCopy = promptTokens
        let turnsCopy = turns
        let written = filePath.withCString { cPath in
            tokensCopy.withUnsafeBufferPointer { buf in
                llama_state_seq_save_file(context, cPath, 0, buf.baseAddress, buf.count)
            }
        }
        if written == 0 {
            if checkpoints[turnCount]?.filePath == filePath {
                checkpoints.removeValue(forKey: turnCount)
                checkpointOrder.removeAll { $0 == turnCount }
            }
            try? FileManager.default.removeItem(atPath: filePath)
            NSLog("[LlamaEngine][Checkpoint] Checkpoint save failed (turn=%d, endPos=%d, path=%@)", Int32(turnCount), Int32(effectiveEndPos), filePath)
        } else {
            checkpointOrder.removeAll { $0 == turnCount }
            checkpointOrder.append(turnCount)
            checkpoints[turnCount] = SessionCheckpoint(turnCount: turnCount,
                                                       promptEndPos: effectiveEndPos,
                                                       extraVisualTokens: extraVisualTokens,
                                                       filePath: filePath,
                                                       tokens: promptTokens,
                                                       renderedTokens: canonicalTokens,
                                                       turns: turnsCopy,
                                                       hasImages: hasImages)
            checkpointModelKey = loadedModelKey
            checkpointContextCap = contextCap
            checkpointKVBits = contextKVBits
            checkpointIsSpeculative = (contextSpeculativeMode != .off)
            trimCheckpoints()
            NSLog("[LlamaEngine][Checkpoint] Checkpoint save succeeded (turn=%d, endPos=%d, extraVisual=%d, hasImages=%@, bytes=%zu, path=%@)",
                  Int32(turnCount), Int32(effectiveEndPos), Int32(extraVisualTokens), hasImages ? "true" : "false", written, filePath)
            // New files do not inherit the directory's isExcludedFromBackup attribute; mark this one
            // so the fresh snapshot stays out of iCloud backup.
            var fileURL = URL(fileURLWithPath: filePath)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? fileURL.setResourceValues(values)
        }
    }

    /// Load and verify a checkpoint file into `context`, rolling `sessionCache` back to its boundary on success.
    private func loadCheckpointFile(_ cp: SessionCheckpoint,
                                    context: OpaquePointer,
                                    failureReason: inout String?) -> Bool {
        var loaded = [llama_token](repeating: 0, count: cp.tokens.count + 16)
        var loadedCount = 0
        let nread = cp.filePath.withCString { cPath in
            loaded.withUnsafeMutableBufferPointer { buf in
                llama_state_seq_load_file(context, cPath, 0, buf.baseAddress, buf.count, &loadedCount)
            }
        }
        guard nread > 0, loadedCount == cp.tokens.count else {
            if failureReason == nil {
                failureReason = "检查点文件缺失或未完成写入 (turn=\(cp.turnCount))"
            }
            return false
        }
        guard loaded.prefix(loadedCount).elementsEqual(cp.tokens) else {
            if failureReason == nil {
                failureReason = "检查点文件内容校验失败 (turn=\(cp.turnCount))"
            }
            return false
        }
        sessionCache.rollbackToCheckpoint(turns: cp.turns,
                                          tokens: cp.hasImages ? [] : cp.tokens,
                                          count: cp.promptEndPos,
                                          turnCount: cp.turnCount,
                                          promptEndPos: cp.promptEndPos,
                                          extraVisualTokens: cp.extraVisualTokens)
        return true
    }

    /// LRU eviction: keep only the most recently saved `checkpointMaxSlots` snapshots.
    private func trimCheckpoints() {
        while checkpointOrder.count > Self.checkpointMaxSlots {
            let oldest = checkpointOrder.removeFirst()
            if let old = checkpoints.removeValue(forKey: oldest) {
                try? FileManager.default.removeItem(atPath: old.filePath)
            }
        }
    }

    /// Attempt to restore the best matching checkpoint for an edit-resend. Prioritizes semantic turn-boundary
    /// matching (where `kept` starts with the exact text of a completed `.assistant` turn checkpoint) so that
    /// edit-resend achieves 99.9% reuse without falling victim to BPE greedy tokenization divergence.
    /// Falls back to token-level prefix matching if no whole-turn boundary matches.
    private func restoreCheckpoint(kept: [ChatTurn],
                                   fittedPromptText: String,
                                   vocab: OpaquePointer?,
                                   thinking: Bool,
                                   newPromptTokens: [llama_token],
                                   minCommon: Int,
                                   reserve: Int,
                                   context: OpaquePointer,
                                   reason: inout String) -> (pos: Int, suffix: [llama_token])? {
        guard !checkpoints.isEmpty else {
            reason = "无已保存检查点 (checkpoints 为空)"
            return nil
        }
        var loadFailureReason: String? = nil
        // Strategy 1: Semantic turn-boundary matching (bypasses token-level divergence).
        // Semantic candidates must be sorted by turnCount descending (most recent completed turn first)
        // so that edit-resend maximizes semantic conversation history reuse rather than physical position
        // (which in thinking mode can be artificially larger on older turns due to historical <think> blocks).
        let semanticCandidates = checkpoints.values.sorted { $0.turnCount > $1.turnCount }

        for cp in semanticCandidates {
            guard !cp.hasImages else { continue }
            if cp.turnCount < kept.count,
               cp.turns.count == cp.turnCount,
               cp.turns.last?.role == .assistant,
               Array(kept.prefix(cp.turnCount)) == cp.turns {
                let remainingTurns = Array(kept[cp.turnCount...])
                let suffixText: String
                if let m = model,
                   let prefixRendered = Self.autoPrompt(Array(kept.prefix(cp.turnCount)), modelPtr: m,
                                                        reasoning: reasoningStyle, thinking: thinking,
                                                        addGenerationPrompt: false) {
                    let cleanPrefix = prefixRendered.hasSuffix("\n") ? String(prefixRendered.dropLast()) : prefixRendered
                    if !cleanPrefix.isEmpty && fittedPromptText.hasPrefix(cleanPrefix) {
                        suffixText = String(fittedPromptText.dropFirst(cleanPrefix.count))
                    } else {
                        let fallback = Self.buildPrompt(messages: remainingTurns, template: promptTemplate,
                                                        reasoning: reasoningStyle, thinking: thinking)
                        suffixText = fallback.hasPrefix("\n") ? fallback : ("\n" + fallback)
                    }
                } else {
                    let fallback = Self.buildPrompt(messages: remainingTurns, template: promptTemplate,
                                                    reasoning: reasoningStyle, thinking: thinking)
                    suffixText = fallback.hasPrefix("\n") ? fallback : ("\n" + fallback)
                }
                var suffixTokens = vocab != nil ? Self.tokenize(vocab: vocab!, text: suffixText, addSpecial: false) : []
                guard !suffixTokens.isEmpty else { continue }

                // Token alignment check: eliminate subtle boundary BPE divergence by aligning
                // with the canonical prompt tokens tail slice when the body matches and start position exactly aligns.
                if suffixTokens.count > 2,
                   newPromptTokens.count - suffixTokens.count == cp.physicalEndPos {
                    let canonicalSuffix = Array(newPromptTokens[(newPromptTokens.count - suffixTokens.count)...])
                    if canonicalSuffix != suffixTokens,
                       canonicalSuffix.suffix(from: 2) == suffixTokens.suffix(from: 2) {
                        NSLog("[LlamaEngine] Aligned boundary BPE token divergence in restoreCheckpoint to canonical prompt tokens")
                        suffixTokens = canonicalSuffix
                    }
                }

                guard cp.physicalEndPos + suffixTokens.count + reserve <= contextCap else {
                    if loadFailureReason == nil {
                        loadFailureReason = "检查点物理KV余量不足 (pos=\(cp.physicalEndPos), suffix=\(suffixTokens.count), reserve=\(reserve), cap=\(contextCap))"
                    }
                    continue
                }
                guard loadCheckpointFile(cp, context: context, failureReason: &loadFailureReason) else {
                    continue
                }
                NSLog("[LlamaEngine] Checkpoint restored (turn-prefix): turn=%d, promptEndPos=%d, suffix=%d tok",
                      Int32(cp.turnCount), Int32(cp.promptEndPos), Int32(suffixTokens.count))
                return (cp.promptEndPos, suffixTokens)
            }
        }

        // Strategy 2: Fallback to token-level prefix matching (sorted by canonical prefix length descending).
        let tokenCandidates = checkpoints.values.sorted { $0.renderedTokens.count > $1.renderedTokens.count }
        for cp in tokenCandidates {
            guard !cp.hasImages else { continue }
            let matchLen = cp.renderedTokens.count
            guard matchLen >= minCommon, matchLen <= newPromptTokens.count else { continue }
            // Prefix validation: the saved canonical prompt must equal the head of the new prompt.
            guard newPromptTokens.prefix(matchLen).elementsEqual(cp.renderedTokens) else { continue }

            let suffixCount = max(1, newPromptTokens.count - matchLen)
            guard cp.physicalEndPos + suffixCount + reserve <= contextCap else {
                if loadFailureReason == nil {
                    loadFailureReason = "检查点物理KV余量不足 (pos=\(cp.physicalEndPos), suffix=\(suffixCount), reserve=\(reserve), cap=\(contextCap))"
                }
                continue
            }

            guard loadCheckpointFile(cp, context: context, failureReason: &loadFailureReason) else {
                continue
            }

            let suffix = Array(newPromptTokens[matchLen...])
            NSLog("[LlamaEngine] Checkpoint restored (token-prefix): turn=%d, promptEndPos=%d (matched=%d), suffix=%d tok",
                  Int32(cp.turnCount), Int32(cp.promptEndPos), Int32(matchLen), Int32(suffix.count))
            return (cp.promptEndPos, suffix)
        }
        if let loadFailureReason {
            reason = loadFailureReason
        } else {
            reason = "无前缀匹配的检查点 (编辑点早于所有已保存边界或前缀不符)"
        }
        return nil
    }

    private enum MultimodalRestoreMatch {
        /// Restored a visual-prefix checkpoint where all images up to the final turn are already in KV;
        /// caller only needs to decode the trailing pure-text `tailTokens` starting at `pos`.
        case visualPrefix(pos: Int, tailTokens: [llama_token])
        /// Restored an earlier turn-boundary checkpoint up to `pos`; caller evaluates `remainingTurns`.
        case turnPrefix(pos: Int, remainingTurns: [ChatTurn])
    }

    /// Attempt to restore the best matching checkpoint for a multimodal (`hasImages == true`) turn.
    private func restoreMultimodalCheckpoint(kept: [ChatTurn],
                                             vocab: OpaquePointer,
                                             reserve: Int,
                                             renderPrompt: ([ChatTurn]) -> String,
                                             context: OpaquePointer,
                                             reason: inout String) -> MultimodalRestoreMatch? {
        guard !checkpoints.isEmpty else {
            reason = "无已保存检查点 (checkpoints 为空)"
            return nil
        }
        var loadFailureReason: String? = nil
        let candidates = checkpoints.values.sorted { $0.promptEndPos > $1.promptEndPos }
        let marker = String(cString: mtmd_default_marker())

        for cp in candidates {
            // Case 1: Visual-prefix checkpoint (saved right after the last image chunk of turn `cp.turnCount`).
            // Serves BOTH:
            //   (a) Regenerate / Edit-Resend of the caption on that image turn itself (`kept.count == cp.turnCount`), and
            //   (b) Regenerate / Edit-Resend on subsequent text-only turns (`kept.count > cp.turnCount` with no new images),
            // because in both cases `marker` in turn `cp.turnCount` is the final media marker in `kept`, so everything
            // after `lastMarkerRange.upperBound` is pure text that `decodeSuffix` can evaluate in ~10–30 ms.
            if cp.hasImages,
               cp.turnCount <= kept.count,
               cp.turns.count == cp.turnCount,
               let cpLast = cp.turns.last, cpLast.content.isEmpty, !cpLast.images.isEmpty {
                let targetTurn = kept[cp.turnCount - 1]
                let trailingTurns = Array(kept[cp.turnCount...])
                let trailingHasImages = trailingTurns.contains { !$0.images.isEmpty }
                if !trailingHasImages,
                   targetTurn.role == cpLast.role,
                   targetTurn.images == cpLast.images,
                   Array(kept.prefix(cp.turnCount - 1)) == Array(cp.turns.dropLast()) {
                    let fullText = renderPrompt(Self.injectMediaMarkers(kept, marker: marker))
                    guard let lastMarkerRange = fullText.range(of: marker, options: .backwards) else { continue }
                    let tailText = String(fullText[lastMarkerRange.upperBound...])
                    let tailTokens = Self.tokenize(vocab: vocab, text: tailText, addSpecial: false)
                    guard !tailTokens.isEmpty, cp.physicalEndPos + tailTokens.count + reserve <= contextCap else {
                        if loadFailureReason == nil {
                            loadFailureReason = "检查点物理KV余量不足 (pos=\(cp.physicalEndPos), tail=\(tailTokens.count), reserve=\(reserve), cap=\(contextCap))"
                        }
                        continue
                    }
                    guard loadCheckpointFile(cp, context: context, failureReason: &loadFailureReason) else { continue }
                    NSLog("[LlamaEngine] Multimodal visual-prefix checkpoint restored: turn=%d (kept=%d), pos=%d, extraVisual=%d, tail=%d tok",
                          Int32(cp.turnCount), Int32(kept.count), Int32(cp.promptEndPos), Int32(cp.extraVisualTokens), Int32(tailTokens.count))
                    return .visualPrefix(pos: cp.promptEndPos, tailTokens: tailTokens)
                }
            }

            // Case 2: Earlier full turn-boundary EOS checkpoint (must end on a completed `.assistant` turn).
            if cp.turnCount < kept.count,
               cp.turns.count == cp.turnCount,
               cp.turns.last?.role == .assistant,
               cp.turns.last?.content.isEmpty == false,
               Array(kept.prefix(cp.turnCount)) == cp.turns {
                let remainingTurns = Array(kept[cp.turnCount...])
                guard !remainingTurns.isEmpty else { continue }
                let remainingTextTokens = Self.tokenize(vocab: vocab, text: renderPrompt(remainingTurns), addSpecial: false).count
                let requiredTokens = max(1, remainingTextTokens + Self.imageTokenCount(remainingTurns))
                guard cp.physicalEndPos + requiredTokens + reserve <= contextCap else {
                    if loadFailureReason == nil {
                        loadFailureReason = "检查点物理KV余量不足 (pos=\(cp.physicalEndPos), rem=\(requiredTokens), reserve=\(reserve), cap=\(contextCap))"
                    }
                    continue
                }
                guard loadCheckpointFile(cp, context: context, failureReason: &loadFailureReason) else { continue }
                NSLog("[LlamaEngine] Multimodal turn-prefix checkpoint restored: turn=%d, pos=%d, extraVisual=%d, remainingTurns=%d",
                      Int32(cp.turnCount), Int32(cp.promptEndPos), Int32(cp.extraVisualTokens), Int32(remainingTurns.count))
                return .turnPrefix(pos: cp.promptEndPos, remainingTurns: remainingTurns)
            }
        }

        if let loadFailureReason {
            reason = loadFailureReason
        } else {
            reason = "无前缀匹配的检查点 (编辑点早于所有已保存边界或图片/前缀不符)"
        }
        return nil
    }

    /// Decode `suffixTokens` starting at physical KV position `startPos` in batches, requesting logits
    /// on the final token. Returns false when a chunk fails to decode (caller falls back); throws on
    /// cancellation or context teardown — mirroring the inline decode loops in `run`.
    private func decodeSuffix(_ suffixTokens: [llama_token], from startPos: Int,
                              nBatch: Int, context: OpaquePointer,
                              governance: GenerationGovernance) async throws -> Bool {
        guard !suffixTokens.isEmpty else { return true }
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
                                  token: tok, pos: Int32(startPos + i + offset), logits: isLast)
            }
            batch.n_tokens = Int32(chunkCount)
            if llama_decode(context, batch) != 0 { return false }
            i = end
            if Task.isCancelled || governance.isCancelled { throw CancellationError() }
            guard self.context == context else { throw CancellationError() }
        }
        return true
    }

    /// (Re)create the decode context sized to `cap` tokens with the requested KV-cache width. Kept separate
    /// from `load` because n_ctx (and the KV-cache dtype) is fixed at context-creation on llama.cpp, while
    /// both are per-generation levers. `kvBits` mirrors `Sampling.kvBits`: 0 = f16 (default), 4 = Q4_0,
    /// 6 = K Q4_0 + V Q8_0 (split), 8 = Q8_0. Rebuilds when EITHER the size or the KV width changes.
    private func ensureContext(cap: Int, kvBits: Int, batchSize: Int = 512, speculativeMode: SpeculativeMode = .off) throws {
        let target = max(512, cap)
        let targetBatch = max(128, min(batchSize, target))
        let isSpeculative = (speculativeMode != .off)
        let currentIsSpeculative = (contextSpeculativeMode != .off)
        if context != nil,
           contextCap == target,
           contextKVBits == kvBits,
           contextRequestedBatchSize == targetBatch,
           currentIsSpeculative == isSpeculative {
            // Keep KV cache resident for prefix reuse; prefill will clear if history diverges
            return
        }
        sessionCache.reset()
        if !checkpoints.isEmpty,
           checkpointContextCap != 0,
           (checkpointContextCap != target || checkpointKVBits != kvBits || checkpointIsSpeculative != isSpeculative) {
            clearCheckpoints()
        }
        if let context { llama_free(context) }
        // Reset BEFORE the fallible init below: if llama_init_from_model throws out of this function,
        // `context` must not keep pointing at the freed allocation (a retry would double-free, and the
        // reuse branch above would llama_memory_clear freed memory — a user-reachable UAF via kvBits).
        context = nil; contextCap = 0; contextKVBits = -1; contextBatchSize = 0; contextRequestedBatchSize = 0; contextSpeculativeMode = .off
        var effectiveBatch = targetBatch
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(target)
        cp.n_batch = UInt32(targetBatch)
        cp.n_ubatch = UInt32(targetBatch)
        cp.n_threads = nThreads
        cp.n_threads_batch = nThreads
        // Recurrent-state rollback snapshots for hybrid architectures (Qwen 3.5).
        // NOTE: edit-resend rollback via llama_memory_seq_rm is depth-limited to n_rs_seq — a single
        // reply is hundreds+ tokens deep, so message edits always exceed it and reuse falls through
        // to the KV checkpoints (saveCheckpoint) instead. Slots are kept only while speculative
        // decoding is active (short draft-verification rollbacks); 0 during standard generation
        // saves ~48–96+ MiB of recurrent state memory.
        let rsSlots: UInt32 = isSpeculative ? Self.rsRollbackSlots : 0
        cp.n_rs_seq = rsSlots
        // KV-cache quantization and Flash Attention.
        // Aligned with OGAM: use AUTO across Metal backends so llama.cpp enables Flash Attention
        // on all supported layers while gracefully handling hybrid/multimodal layers,
        // keeping attention computation constant-time and preventing 2 tok/s slowdown.
        // kvBits: 0 = f16 (default), 4 = Q4_0, 8 = Q8_0, 6 = K Q4_0 + V Q8_0 (split: V is most
        // quality-sensitive, K tolerates more quantization — ~23% smaller than full Q8_0).
        switch kvBits {
        case 4:
            cp.type_k = GGML_TYPE_Q4_0; cp.type_v = GGML_TYPE_Q4_0
        case 6:
            cp.type_k = GGML_TYPE_Q4_0; cp.type_v = GGML_TYPE_Q8_0
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
            fallbackCp.n_batch = UInt32(targetBatch)
            fallbackCp.n_ubatch = UInt32(targetBatch)
            fallbackCp.n_threads = nThreads
            fallbackCp.n_threads_batch = nThreads
            fallbackCp.n_rs_seq = rsSlots
            #if !targetEnvironment(simulator)
            fallbackCp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
            #endif
            // Keep user KV bits if quantized
            switch kvBits {
            case 4:
                fallbackCp.type_k = GGML_TYPE_Q4_0; fallbackCp.type_v = GGML_TYPE_Q4_0
            case 6:
                fallbackCp.type_k = GGML_TYPE_Q4_0; fallbackCp.type_v = GGML_TYPE_Q8_0
            case 8:
                fallbackCp.type_k = GGML_TYPE_Q8_0; fallbackCp.type_v = GGML_TYPE_Q8_0
            default:
                break
            }
            ctx = llama_init_from_model(model, fallbackCp)

            // Attempt 3: if quantized KV cache itself was too memory-heavy or refused, retry base f16 default
            if ctx == nil && kvBits != 0 {
                let safeBatch = min(targetBatch, 512)
                var safeCp = llama_context_default_params()
                safeCp.n_ctx = UInt32(target)
                safeCp.n_batch = UInt32(safeBatch)
                safeCp.n_ubatch = UInt32(safeBatch)
                safeCp.n_threads = nThreads
                safeCp.n_threads_batch = nThreads
                safeCp.n_rs_seq = rsSlots  // B1 fix: must match Attempt 1/2
                #if !targetEnvironment(simulator)
                safeCp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
                #endif
                ctx = llama_init_from_model(model, safeCp)
                if ctx != nil {
                    effectiveBatch = safeBatch
                }
            }
        }

        guard let ctx else {
            throw EngineError.contextInitFailed
        }
        context = ctx
        contextCap = target
        contextKVBits = kvBits
        contextBatchSize = effectiveBatch
        contextRequestedBatchSize = targetBatch
        contextSpeculativeMode = speculativeMode
        NSLog("[LlamaEngine] Context initialized: n_ctx=%d, effective_batch=%d (requested=%d), kvBits=%d, speculative=%@ (n_rs_seq=%d)",
              Int32(target), Int32(effectiveBatch), Int32(targetBatch), Int32(kvBits),
              isSpeculative ? "true" : "false", Int32(rsSlots))
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
        var hasImages = false
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

            if !params.kvCheckpointsEnabled, !checkpoints.isEmpty || checkpointDirectory != nil {
                clearCheckpoints()
            }
            try ensureContext(cap: params.contextTokenCap, kvBits: params.kvBits, batchSize: params.prefillBatchSize, speculativeMode: params.speculativeMode)
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
            func renderCompletedHistory(_ msgs: [ChatTurn]) -> String {
                let carriesMedia = msgs.contains(where: { !$0.images.isEmpty })
                if !carriesMedia, let m = model,
                   let rendered = Self.autoPrompt(msgs, modelPtr: m, reasoning: reasoningStyle, thinking: wantThinking, addGenerationPrompt: false) {
                    return rendered.hasSuffix("\n") ? String(rendered.dropLast()) : rendered
                }
                return Self.buildCompletedPrompt(messages: msgs, template: promptTemplate)
            }

            // Fit the history into the KV window by dropping WHOLE oldest non-system turns and rebuilding —
            // NEVER by chopping tokens off the front, which would shear the system prompt and the template
            // head mid-conversation. Reserve room for the answer; if even {system prefix + final user turn}
            // overflows, fail with a clear error rather than emit garbage from a half-formed prompt. Each
            // attached image also reserves ~600 tokens — its vision-encoder embeddings consume real context.
            let reserve = Self.answerTokenReserve(maxTokens: params.maxTokens, contextCap: contextCap)
            let budget = contextCap - reserve
            var fittedPromptText = ""
            var fittedPromptTokens: [llama_token] = []
            guard budget > 0, let kept = Self.fitMessages(messages, budget: budget, tokenCount: { candidate in
                let rendered = renderPrompt(candidate)
                let toks = Self.tokenize(vocab: vocab, text: rendered, addSpecial: true)
                fittedPromptText = rendered
                fittedPromptTokens = toks
                return toks.count + Self.imageTokenCount(candidate)
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
            let nBatch = max(128, contextBatchSize)
            var promptTokenCount: Int = 0
            var promptPosAdvance: Int? = nil
            var pendingExtraVisualTokens: Int = sessionCache.extraVisualTokens
            var cachedRollbackTokensCount: Int = 0
            var rollbackDiagnosticMessage: String? = nil
            var cachePathResult: CachePath? = nil
            var suffixTokensToDecode: [llama_token] = []
            var rollbackSucceeded = false
            hasImages = kept.contains { !$0.images.isEmpty }

            // Check if this turn is an incremental continuation of the cached session:
            // Condition:
            // 1. Prefix of `kept` exactly matches `sessionCache.turns`
            // 2. One or more new turns added (e.g. a new user query, or parallel tool results)
            // 3. Physical KV cache has sufficient headroom for suffix + answer reserve
            // 4. The new query carries no images (or kvCheckpointsEnabled enables incremental mtmd)
            let previousCount = sessionCache.turns.count
            let newTurns = (previousCount > 0 && kept.count > previousCount)
                ? Array(kept[previousCount...])
                : []
            let prefixMatched = !newTurns.isEmpty &&
                Array(kept.prefix(previousCount)) == sessionCache.turns
            let newTurnsCarryImages = newTurns.contains(where: { !$0.images.isEmpty })
            let incrementalReserve = min(reserve, 256)

            var incrementalSuffixTokens: [llama_token]? = nil
            var canIncrementalMultimodal = false
            if prefixMatched && !newTurnsCarryImages {
                let suffixText: String
                if !hasImages, let m = model,
                   let prefixRendered = Self.autoPrompt(sessionCache.turns, modelPtr: m,
                                                        reasoning: reasoningStyle, thinking: wantThinking,
                                                        addGenerationPrompt: false) {
                    let cleanPrefix = prefixRendered.hasSuffix("\n")
                        ? String(prefixRendered.dropLast())
                        : prefixRendered
                    if !cleanPrefix.isEmpty && fittedPromptText.hasPrefix(cleanPrefix) {
                        suffixText = String(fittedPromptText.dropFirst(cleanPrefix.count))
                    } else {
                        let fallback = Self.buildPrompt(messages: newTurns, template: promptTemplate,
                                                        reasoning: reasoningStyle, thinking: wantThinking)
                        suffixText = fallback.hasPrefix("\n") ? fallback : ("\n" + fallback)
                    }
                } else {
                    let fallback = Self.buildPrompt(messages: newTurns, template: promptTemplate,
                                                    reasoning: reasoningStyle, thinking: wantThinking)
                    suffixText = fallback.hasPrefix("\n") ? fallback : ("\n" + fallback)
                }
                let tokens = Self.tokenize(vocab: vocab, text: suffixText, addSpecial: false)
                if !tokens.isEmpty && sessionCache.physicalTokenCount + tokens.count + incrementalReserve <= contextCap {
                    incrementalSuffixTokens = tokens
                } else {
                    NSLog("[LlamaEngine][CacheMiss] Incremental continuation skipped: KV cache headroom exceeded or empty tokens (used=%d, suffix=%d, reserve=%d, cap=%d). Falling back to full evaluation.",
                          Int32(sessionCache.physicalTokenCount), Int32(tokens.count), Int32(incrementalReserve), Int32(contextCap))
                }
            } else if params.kvCheckpointsEnabled && prefixMatched && newTurnsCarryImages {
                let fallback = Self.buildPrompt(messages: newTurns, template: promptTemplate,
                                                reasoning: reasoningStyle, thinking: wantThinking)
                let estTokens = Self.tokenize(vocab: vocab, text: fallback, addSpecial: false).count + Self.imageTokenCount(newTurns)
                if sessionCache.physicalTokenCount + estTokens + incrementalReserve <= contextCap {
                    canIncrementalMultimodal = true
                } else {
                    NSLog("[LlamaEngine][CacheMiss] Multimodal incremental continuation skipped: KV headroom exceeded (used=%d, est=%d, reserve=%d, cap=%d).",
                          Int32(sessionCache.physicalTokenCount), Int32(estTokens), Int32(incrementalReserve), Int32(contextCap))
                }
            } else if previousCount > 0 {
                let countOk = kept.count > previousCount
                let prefixOk = countOk && Array(kept.prefix(previousCount)) == sessionCache.turns
                let noImg = !newTurnsCarryImages
                NSLog("[LlamaEngine] Incremental continuation rejected: kept.count=%d (cached %d), prefixMatch=%@, noImages=%@",
                      Int32(kept.count), Int32(previousCount),
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
                NSLog("[LlamaEngine][CacheHit] incremental continuation: reused %d cached tokens, decoded suffix %d tok (skipped history recompute)",
                      Int32(sessionCache.tokenCount), Int32(suffixTokens.count))
                cachePathResult = .incremental
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
                    if Task.isCancelled || governance.isCancelled { throw CancellationError() }
                    guard self.context == context else { throw CancellationError() }
                }
                promptTokenCount = suffixTokens.count
                pendingExtraVisualTokens = sessionCache.extraVisualTokens
                // Save a checkpoint for this turn boundary so an edit-resend can reuse the full
                // resident KV state even when seq_rm is rejected. The complete prompt token list
                // is the cache's existing tokens plus the newly decoded suffix.
                if params.kvCheckpointsEnabled && !sessionCache.hasImages && (checkpoints.isEmpty || suffixTokens.count > 1024) {
                    let fullPromptTokens = sessionCache.tokens + suffixTokens
                    saveCheckpoint(turnCount: kept.count,
                                   promptTokens: fullPromptTokens,
                                   renderedTokens: fittedPromptTokens,
                                   turns: kept,
                                   context: context)
                }
                // Note: conversationTokens for speculative n-gram lookup is built lazily below,
                // only when speculative mode is active and prompt lookup is actually in use.
            } else if hasImages {
                if canIncrementalMultimodal {
                    // Module 1: Prior turns are already resident in sessionCache; evaluate ONLY the newly
                    // added turn(s) carrying images starting from `sessionCache.tokenCount`.
                    isIncrementalContinuation = true
                    cachePathResult = .incremental
                    let mmResult = try await mtmdPrefill(turnsToEval: newTurns,
                                                         fullKeptTurns: kept,
                                                         startPos: sessionCache.tokenCount,
                                                         addSpecial: false,
                                                         saveVisualCheckpoint: params.kvCheckpointsEnabled,
                                                         context: context,
                                                         renderPrompt: renderPrompt,
                                                         nBatch: nBatch,
                                                         governance: governance)
                    promptPosAdvance = mmResult.posAdvanced
                    promptTokenCount = mmResult.totalTokens
                    pendingExtraVisualTokens = mmResult.extraVisualTokens
                    NSLog("[LlamaEngine][CacheHit] multimodal incremental continuation: reused %d cached pos, mtmd decoded %d tok (posAdvance=%d)",
                          Int32(sessionCache.tokenCount), Int32(promptTokenCount), Int32(mmResult.posAdvanced))
                } else {
                    var mmRestored = false
                    if params.kvCheckpointsEnabled {
                        var restoreReason = ""
                        if let match = restoreMultimodalCheckpoint(kept: kept,
                                                                   vocab: vocab,
                                                                   reserve: incrementalReserve,
                                                                   renderPrompt: renderPrompt,
                                                                   context: context,
                                                                   reason: &restoreReason) {
                            switch match {
                            case .visualPrefix(let pos, let tailTokens):
                                if try await decodeSuffix(tailTokens, from: pos,
                                                          nBatch: nBatch, context: context, governance: governance) {
                                    promptTokenCount = tailTokens.count
                                    pendingExtraVisualTokens = sessionCache.extraVisualTokens
                                    cachedRollbackTokensCount = pos
                                    rollbackSucceeded = true
                                    mmRestored = true
                                    cachePathResult = .checkpoint
                                    rollbackDiagnosticMessage = "检查点恢复(多模态视觉前缀): 复用 \(pos + sessionCache.extraVisualTokens) tok, 解码配文 \(tailTokens.count) tok"
                                    NSLog("[LlamaEngine][CacheHit] multimodal visual-prefix checkpoint restore: reused pos=%d (extraVisual=%d), decoded tail %d tok",
                                          Int32(pos), Int32(sessionCache.extraVisualTokens), Int32(tailTokens.count))
                                }
                            case .turnPrefix(let pos, let remainingTurns):
                                let remainingCarryImages = remainingTurns.contains { !$0.images.isEmpty }
                                if !remainingCarryImages {
                                    let rawSuffix = Self.buildPrompt(messages: remainingTurns, template: promptTemplate,
                                                                     reasoning: reasoningStyle, thinking: wantThinking)
                                    let suffixText = (promptTemplate == .deepSeek || promptTemplate == .hunyuan || rawSuffix.hasPrefix("\n"))
                                        ? rawSuffix : ("\n" + rawSuffix)
                                    let suffixTokens = Self.tokenize(vocab: vocab, text: suffixText, addSpecial: false)
                                    if !suffixTokens.isEmpty && sessionCache.physicalTokenCount + suffixTokens.count + incrementalReserve <= contextCap,
                                       try await decodeSuffix(suffixTokens, from: pos,
                                                              nBatch: nBatch, context: context, governance: governance) {
                                        promptTokenCount = suffixTokens.count
                                        pendingExtraVisualTokens = sessionCache.extraVisualTokens
                                        cachedRollbackTokensCount = pos
                                        rollbackSucceeded = true
                                        mmRestored = true
                                        cachePathResult = .checkpoint
                                        rollbackDiagnosticMessage = "检查点恢复(多模态基座): 复用 \(pos + sessionCache.extraVisualTokens) tok, 解码后缀 \(suffixTokens.count) tok"
                                        NSLog("[LlamaEngine][CacheHit] multimodal turn-prefix checkpoint restore: reused pos=%d (extraVisual=%d), decoded suffix %d tok",
                                              Int32(pos), Int32(sessionCache.extraVisualTokens), Int32(suffixTokens.count))
                                    }
                                } else {
                                    let mmResult = try await mtmdPrefill(turnsToEval: remainingTurns,
                                                                         fullKeptTurns: kept,
                                                                         startPos: pos,
                                                                         addSpecial: false,
                                                                         saveVisualCheckpoint: params.kvCheckpointsEnabled,
                                                                         context: context,
                                                                         renderPrompt: renderPrompt,
                                                                         nBatch: nBatch,
                                                                         governance: governance)
                                    promptPosAdvance = mmResult.posAdvanced
                                    promptTokenCount = mmResult.totalTokens
                                    pendingExtraVisualTokens = mmResult.extraVisualTokens
                                    cachedRollbackTokensCount = pos
                                    rollbackSucceeded = true
                                    mmRestored = true
                                    cachePathResult = .checkpoint
                                    rollbackDiagnosticMessage = "检查点恢复(多模态增量): 复用 \(pos + sessionCache.extraVisualTokens) tok, 增量预填充 \(promptTokenCount) tok"
                                    NSLog("[LlamaEngine][CacheHit] multimodal checkpoint + incremental mtmd: reused pos=%d, mtmd decoded %d tok (posAdvance=%d)",
                                          Int32(pos), Int32(promptTokenCount), Int32(mmResult.posAdvanced))
                                }
                            }
                        } else {
                            rollbackDiagnosticMessage = "检查点恢复未命中: \(restoreReason)，回退全量重算"
                            NSLog("[LlamaEngine][CacheMiss] Multimodal checkpoint restore missed: %@", restoreReason)
                        }
                    }
                    if !mmRestored {
                        // Multimodal full evaluation: first image turn or no matching checkpoint
                        sessionCache.reset(context: context)
                        let mmResult = try await mtmdPrefill(turnsToEval: kept,
                                                             fullKeptTurns: kept,
                                                             startPos: 0,
                                                             addSpecial: true,
                                                             saveVisualCheckpoint: params.kvCheckpointsEnabled,
                                                             context: context,
                                                             renderPrompt: renderPrompt,
                                                             nBatch: nBatch,
                                                             governance: governance)
                        promptPosAdvance = mmResult.posAdvanced
                        promptTokenCount = mmResult.totalTokens
                        pendingExtraVisualTokens = mmResult.extraVisualTokens
                    }
                }
            } else {
                // Pure text evaluation: Prefix Rollback optimization with clean slate fallback
                let promptTokens = fittedPromptTokens.isEmpty
                    ? Self.tokenize(vocab: vocab, text: renderPrompt(kept), addSpecial: true)
                    : fittedPromptTokens
                prefilledPromptTokens = promptTokens

                let residentHadImages = sessionCache.hasImages

                // 语义级别识别：
                // 1. 同轮精确重发（Regenerate）：本次 kept 为显存驻留轮次的严格前缀，且 Prompt 在显存中完整存在
                let isHistoricalPrefixTurn = !residentHadImages &&
                    !sessionCache.tokens.isEmpty &&
                    kept.count < sessionCache.turns.count &&
                    Array(sessionCache.turns.prefix(kept.count)) == kept

                // 如果命中精确语义重发，并且记录了该轮 Prompt 当时在显存中的结束位置，
                // 则可以直接复用显存中已解码好的完整 prompt，无需受限于全局整体分词导致的 BPE 边界重组分叉。
                let knownPromptEndPos = isHistoricalPrefixTurn ? sessionCache.turnPromptEndPositions[kept.count] : nil

                // 2. 编辑重发（Edit-and-Resend）第一级：内存轮次闭合边界匹配（零磁盘 I/O）
                // 寻找与显存中驻留轮次严格匹配的最长公共轮次前缀（且以已完成的 .assistant 轮次闭合），
                // 直接复用该轮次在显存中的物理坐标，彻底避开裸 Token LCP 的 BPE 分词切分分歧。
                var matchedTurnCount = 0
                var matchedTurnEndPos = 0
                var matchedTurnSuffixTokens: [llama_token] = []
                if !residentHadImages && !sessionCache.tokens.isEmpty && kept.count > 1 {
                    let maxCheck = min(kept.count - 1, sessionCache.turns.count)
                    var t = maxCheck
                    while t >= 2 {
                        if kept[t - 1].role == .assistant,
                           sessionCache.turns.count >= t,
                           sessionCache.turns[t - 1].role == .assistant,
                           let endPos = sessionCache.turnEndPositions[t],
                           endPos > 0,
                           endPos <= sessionCache.tokens.count,
                           Array(kept.prefix(t)) == Array(sessionCache.turns.prefix(t)) {
                            let remainingTurns = Array(kept[t...])
                            let suffixText: String
                            if let m = model,
                               let prefixRendered = Self.autoPrompt(Array(kept.prefix(t)), modelPtr: m,
                                                                    reasoning: reasoningStyle, thinking: wantThinking,
                                                                    addGenerationPrompt: false) {
                                let cleanPrefix = prefixRendered.hasSuffix("\n") ? String(prefixRendered.dropLast()) : prefixRendered
                                if !cleanPrefix.isEmpty && fittedPromptText.hasPrefix(cleanPrefix) {
                                    suffixText = String(fittedPromptText.dropFirst(cleanPrefix.count))
                                } else {
                                    let fallback = Self.buildPrompt(messages: remainingTurns, template: promptTemplate,
                                                                    reasoning: reasoningStyle, thinking: wantThinking)
                                    suffixText = fallback.hasPrefix("\n") ? fallback : ("\n" + fallback)
                                }
                            } else {
                                let fallback = Self.buildPrompt(messages: remainingTurns, template: promptTemplate,
                                                                reasoning: reasoningStyle, thinking: wantThinking)
                                suffixText = fallback.hasPrefix("\n") ? fallback : ("\n" + fallback)
                            }
                            var sTokens = Self.tokenize(vocab: vocab, text: suffixText, addSpecial: false)
                            if !sTokens.isEmpty {
                                if sTokens.count > 2,
                                   promptTokens.count - sTokens.count == endPos {
                                    let canonicalSuffix = Array(promptTokens[(promptTokens.count - sTokens.count)...])
                                    if canonicalSuffix != sTokens,
                                       canonicalSuffix.suffix(from: 2) == sTokens.suffix(from: 2) {
                                        NSLog("[LlamaEngine] Aligned boundary BPE token divergence in memory rollback to canonical prompt tokens")
                                        sTokens = canonicalSuffix
                                    }
                                }
                                matchedTurnCount = t
                                matchedTurnEndPos = endPos
                                matchedTurnSuffixTokens = sTokens
                            }
                            break
                        }
                        t -= 1
                    }
                }

                // Calculate Longest Common Prefix (LCP) between resident KV tokens and new prompt tokens.
                // LCP matching itself is purely textual and serves as fallback when whole turn boundary doesn't match.
                var commonCount = 0
                if !residentHadImages && !sessionCache.tokens.isEmpty {
                    let maxLcp = min(sessionCache.tokens.count, promptTokens.count)
                    while commonCount < maxLcp && sessionCache.tokens[commonCount] == promptTokens[commonCount] {
                        commonCount += 1
                    }
                    if commonCount > 0 && commonCount < promptTokens.count && commonCount < sessionCache.tokens.count {
                        let oldTok = sessionCache.tokens[commonCount]
                        let newTok = promptTokens[commonCount]
                        NSLog("[LlamaEngine] LCP diverged at index %d: cached token %d ('%@') vs new token %d ('%@')",
                              Int32(commonCount), oldTok, Self.tokenToPiece(vocab: vocab, token: oldTok),
                              newTok, Self.tokenToPiece(vocab: vocab, token: newTok))
                    }
                }

                let isFullPromptMatch = isHistoricalPrefixTurn || (commonCount >= promptTokens.count)

                // 确定安全的回滚点与所需解码的后缀：
                var effectiveCommon: Int
                var totalPromptCountForStats: Int

                if let knownEnd = knownPromptEndPos, knownEnd > 1, knownEnd <= sessionCache.tokens.count {
                    // 精确重发最优路径：Prompt 在显存中完整存在，回滚 1 个 token 刷新 logits，达成 99.9% 复用率
                    effectiveCommon = knownEnd - 1
                    suffixTokensToDecode = [sessionCache.tokens[effectiveCommon]]
                    totalPromptCountForStats = knownEnd
                } else if matchedTurnCount > 0 {
                    // 第一级：语义轮次边界回滚命中！直接复用该闭合助手轮次在显存中的真实物理坐标
                    effectiveCommon = matchedTurnEndPos
                    suffixTokensToDecode = matchedTurnSuffixTokens
                    totalPromptCountForStats = matchedTurnEndPos + matchedTurnSuffixTokens.count
                    NSLog("[LlamaEngine][CacheHit] turn boundary matched: turn %d, reused %d pos, suffix %d tok",
                          Int32(matchedTurnCount), Int32(matchedTurnEndPos), Int32(matchedTurnSuffixTokens.count))
                } else if isFullPromptMatch {
                    effectiveCommon = min(commonCount, max(0, promptTokens.count - 1))
                    suffixTokensToDecode = Array(promptTokens[effectiveCommon...])
                    totalPromptCountForStats = promptTokens.count
                } else {
                    effectiveCommon = commonCount
                    suffixTokensToDecode = Array(promptTokens[effectiveCommon...])
                    totalPromptCountForStats = promptTokens.count
                }

                let incrementalReserve = min(reserve, 256)
                let canRollback = (supportsPartialTrim || isFullPromptMatch) &&
                                  !residentHadImages &&
                                  !sessionCache.tokens.isEmpty &&
                                  effectiveCommon >= 16 &&
                                  (totalPromptCountForStats + incrementalReserve <= contextCap)

                if !canRollback {
                    if !supportsPartialTrim && !isFullPromptMatch {
                        rollbackDiagnosticMessage = "跳过回滚: 当前模型架构不支持局部显存截断 (SSM/Recurrent状态已记录)"
                    } else if residentHadImages {
                        rollbackDiagnosticMessage = "跳过回滚: 包含多模态图片"
                    } else if sessionCache.tokens.isEmpty {
                        rollbackDiagnosticMessage = "跳过回滚: 显存中无历史会话Token"
                    } else if effectiveCommon < 16 {
                        rollbackDiagnosticMessage = "回滚失败: 最长公共前缀过短 (仅匹配 \(commonCount) tok, 需要>=16, resident=\(sessionCache.tokens.count), prompt=\(promptTokens.count))"
                    } else {
                        rollbackDiagnosticMessage = "跳过回滚: 上下文超限 (prompt=\(promptTokens.count), cap=\(contextCap))"
                    }
                }

                NSLog("[LlamaEngine] Prefix rollback evaluation: resident=%d, prompt=%d, common=%d (effectiveCommon=%d, canRollback=%@, residentHadImages=%@)",
                      Int32(sessionCache.tokens.count), Int32(promptTokens.count), Int32(commonCount),
                      Int32(effectiveCommon), canRollback ? "true" : "false", residentHadImages ? "true" : "false")

                if canRollback {
                    var rmSuccess = true
                    if sessionCache.tokens.count > effectiveCommon {
                        rmSuccess = llama_memory_seq_rm(llama_get_memory(context), 0, Int32(effectiveCommon), -1)
                    }
                    if rmSuccess {
                        let suffixTokens = suffixTokensToDecode
                        let hitRatePct = (Double(effectiveCommon) / Double(totalPromptCountForStats)) * 100.0
                        NSLog("[LlamaEngine][CacheHit] seq_rm rollback: reused %d tokens (hit %.1f%%), decoded suffix %d tok (fullMatch=%@)",
                              Int32(effectiveCommon), hitRatePct, Int32(suffixTokens.count), isFullPromptMatch ? "true" : "false")

                        if try await decodeSuffix(suffixTokens, from: effectiveCommon,
                                                  nBatch: nBatch, context: context, governance: governance) {
                            promptTokenCount = suffixTokens.count
                            cachedRollbackTokensCount = effectiveCommon
                            rollbackSucceeded = true
                            cachePathResult = .seqRollback
                            let hitRateText = String(format: "%.1f%%", hitRatePct)
                            if isFullPromptMatch {
                                rollbackDiagnosticMessage = "前缀回滚命中(重发): 复用 \(effectiveCommon) tok (\(hitRateText)), 仅刷新末尾Token"
                            } else if matchedTurnCount > 0 {
                                rollbackDiagnosticMessage = "轮次前缀回滚命中: 复用 \(effectiveCommon) tok (\(hitRateText)), 解码后缀 \(suffixTokens.count) tok"
                            } else {
                                rollbackDiagnosticMessage = "前缀回滚命中: 复用 \(effectiveCommon) tok (\(hitRateText)), 解码后缀 \(suffixTokens.count) tok"
                            }
                        } else {
                            rollbackDiagnosticMessage = "回滚失败: 后缀Token解码失败 (llama_decode error)"
                            NSLog("[LlamaEngine][CacheMiss] Prefix rollback decode failed, falling back to clean slate")
                        }
                    } else {
                        supportsPartialTrim = false
                        rollbackDiagnosticMessage = "回滚跳过: 显存不支持局部截断 (如Qwen3.5等混合SSM/Recurrent架构隐状态在数学上不可逆)，已安全全量重新预填充"
                        NSLog("[LlamaEngine][CacheMiss] Prefix rollback llama_memory_seq_rm rejected partial sequence trim (likely hybrid/recurrent architecture like Qwen 3.5), safely falling back to clean slate")
                    }
                }

                if !rollbackSucceeded, params.kvCheckpointsEnabled {
                    // Edit-resend fallback #2: whole-sequence checkpoint restore. Serves architectures
                    // where llama_memory_seq_rm is rejected (Qwen 3.5 hybrid Gated DeltaNet / recurrent
                    // state) — instead of a full recompute we reload the saved "prompt fully prefilled"
                    // state file for the matching turn boundary and decode only the tokens after the edit
                    // point.
                    var restoreReason = ""
                    if let restored = restoreCheckpoint(kept: kept,
                                                        fittedPromptText: fittedPromptText,
                                                        vocab: vocab,
                                                        thinking: wantThinking,
                                                        newPromptTokens: promptTokens,
                                                        minCommon: 16,
                                                        reserve: incrementalReserve,
                                                        context: context,
                                                        reason: &restoreReason) {
                        let suffixTokens: [llama_token]
                        if restored.suffix.isEmpty {
                            // Exact same prompt as the checkpoint: replay the last token to refresh logits
                            // (mirrors the isFullPromptMatch regenerate path). restored.pos >= 16 here.
                            suffixTokens = [promptTokens[promptTokens.count - 1]]
                        } else {
                            suffixTokens = restored.suffix
                        }
                        effectiveCommon = restored.pos
                        suffixTokensToDecode = suffixTokens
                        totalPromptCountForStats = effectiveCommon + suffixTokens.count
                        if try await decodeSuffix(suffixTokens, from: effectiveCommon,
                                                  nBatch: nBatch, context: context, governance: governance) {
                            promptTokenCount = suffixTokens.count
                            cachedRollbackTokensCount = effectiveCommon
                            rollbackSucceeded = true
                            cachePathResult = .checkpoint
                            let hitRatePct = (Double(effectiveCommon) / Double(totalPromptCountForStats)) * 100.0
                            let hitRateText = String(format: "%.1f%%", hitRatePct)
                            rollbackDiagnosticMessage = "检查点恢复: 复用 \(effectiveCommon) tok (\(hitRateText)), 解码后缀 \(suffixTokens.count) tok"
                            NSLog("[LlamaEngine][CacheHit] checkpoint restore: reused %d prompt tokens, decoded suffix %d tok",
                                  Int32(effectiveCommon), Int32(suffixTokens.count))
                        } else {
                            rollbackDiagnosticMessage = "检查点恢复失败: 后缀Token解码错误, 回退全量重算"
                            NSLog("[LlamaEngine][CacheMiss] Checkpoint restore decode failed, falling back to clean slate")
                        }
                    } else {
                        rollbackDiagnosticMessage = "检查点恢复未命中: \(restoreReason)，回退全量重算"
                        NSLog("[LlamaEngine][CacheMiss] Checkpoint restore missed: %@", restoreReason)
                    }
                }

                if !rollbackSucceeded {
                    // Clean slate fallback: clean slate to ensure 100% position alignment
                    NSLog("[LlamaEngine][CacheMiss] full recompute: prompt %d tok (rollback unavailable or restore failed)",
                          Int32(promptTokens.count))
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
                        if Task.isCancelled || governance.isCancelled { throw CancellationError() }
                        guard self.context == context else { throw CancellationError() }
                    }
                    promptTokenCount = promptTokens.count
                }
            }
            // Save a "prompt fully prefilled" checkpoint for this turn boundary (prefix-rollback path),
            // so that a later edit-resend that seq_rm cannot serve (Qwen 3.5 hybrid recurrent state)
            // can restore it instead of recomputing. The write is SYNCHRONOUS on the actor (see
            // saveCheckpoint) and skipped for short contexts (≤ 1024 tok) where full-prefill is
            // already fast enough.
            if params.kvCheckpointsEnabled && !hasImages && (checkpoints.isEmpty || promptTokenCount > 1024),
               let pt = prefilledPromptTokens, !pt.isEmpty {
                let physicalTokens: [llama_token]
                if rollbackSucceeded && cachedRollbackTokensCount > 0 && sessionCache.tokens.count >= cachedRollbackTokensCount {
                    physicalTokens = Array(sessionCache.tokens.prefix(cachedRollbackTokensCount)) + suffixTokensToDecode
                } else {
                    physicalTokens = pt
                }
                saveCheckpoint(turnCount: kept.count,
                               promptTokens: physicalTokens,
                               renderedTokens: pt,
                               turns: kept,
                               context: context)
            }
            let promptSecs = max(Date().timeIntervalSince(prefillStart), 0.0001)
            let cachedPromptTokensCount: Int = isIncrementalContinuation
                ? sessionCache.physicalTokenCount
                : (cachedRollbackTokensCount > 0 ? cachedRollbackTokensCount + sessionCache.extraVisualTokens : 0)

            // Decode loop. Implicit-open reasoning (Qwen3.5) begins inside the think block. The answer
            // stripper removes a model's answer-wrapper tags (Hunyuan's <answer>…</answer>) so they never
            // reach the UI.
            let promptOpenedThink = wantThinking && (
                reasoningStyle == .thinkTagsImplicitOpen
                || fittedPromptText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("<think>")
            )
            var splitter = ThinkSplitter(startInThink: promptOpenedThink)
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

            if prefilledPromptTokens != nil {
                pendingExtraVisualTokens = 0
            }
            let effectivePromptPosAdvance = promptPosAdvance ?? promptTokenCount
            let baseKvPos = isIncrementalContinuation ? sessionCache.tokenCount : cachedRollbackTokensCount
            var kvPos: llama_pos = Int32(baseKvPos + effectivePromptPosAdvance)
            let effectiveKvPosCap = max(0, contextCap - pendingExtraVisualTokens)
            let physicalHeadroom = max(0, effectiveKvPosCap - Int(kvPos))
            let effectiveMaxTokens = (maxTokens > 0) ? min(maxTokens, physicalHeadroom) : physicalHeadroom
            let answerReserve = min(256, max(64, effectiveMaxTokens / 4))
            let maxAllowedThinking = max(32, effectiveMaxTokens - answerReserve)
            let effectiveThinkingBudget = params.thinkingBudget > 0
                ? min(params.thinkingBudget, maxAllowedThinking)
                : maxAllowedThinking
            var thinkingTokens = 0
            var forcedThinkClose = false
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
                    if Int(kvPos) < effectiveKvPosCap {
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
                if splitter.isInsideThink {
                    thinkingTokens += 1
                }
                genTokens += 1
                generatedTokens.append(tokenID)
                if useSpeculative { conversationTokens.append(tokenID) }

                if splitter.isInsideThink && !forcedThinkClose && thinkingTokens >= effectiveThinkingBudget {
                    forcedThinkClose = true
                    let closeTag = "\n</think>\n\n"
                    let closeTokens = Self.tokenize(vocab: vocab, text: closeTag, addSpecial: false)
                    let allToDecode = [tokenID] + closeTokens
                    if Int(kvPos) + allToDecode.count < effectiveKvPosCap {
                        let closeCap = Int32(max(1, allToDecode.count))
                        var closeBatch = llama_batch_init(closeCap, 0, 1)
                        defer { llama_batch_free(closeBatch) }
                        for (idx, tok) in allToDecode.enumerated() {
                            let isLast = (idx == allToDecode.count - 1)
                            Self.setBatchItem(&closeBatch, at: idx, maxCapacity: closeCap, token: tok, pos: kvPos + Int32(idx), logits: isLast)
                        }
                        closeBatch.n_tokens = Int32(allToDecode.count)
                        guard llama_decode(context, closeBatch) == 0 else { throw EngineError.decodeFailed }
                        kvPos += Int32(allToDecode.count)
                        generatedTokens.append(contentsOf: closeTokens)
                        if useSpeculative { conversationTokens.append(contentsOf: closeTokens) }
                        let flushed = decoder.flush()
                        if !flushed.isEmpty { for d in splitter.feed(flushed) { emit(d) } }
                        for d in splitter.feed(closeTag) { emit(d) }
                        NSLog("[LlamaEngine] Thinking budget reached (%d/%d tokens), forced </think> closure.",
                              Int32(thinkingTokens), Int32(effectiveThinkingBudget))
                        continue
                    }
                }

                if genTokens >= effectiveMaxTokens {
                    if Int(kvPos) < effectiveKvPosCap {
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
                    let remainingKvForDrafts = max(0, effectiveKvPosCap - Int(kvPos) - 1)
                    let nearThinkBudget = splitter.isInsideThink && (thinkingTokens + effectiveMaxDrafts >= effectiveThinkingBudget)
                    if supportsKvRollback && backoffCooldown == 0 && remainingKvForDrafts > 0 && !toolGate.isInsideToolCall && !nearThinkBudget {
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
                                if splitter.isInsideThink { thinkingTokens += 1 }
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
                                    if splitter.isInsideThink { thinkingTokens += 1 }
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
                cachePath: cachePathResult,
                gpuLayers: Int(loadedGpuLayers),
                backend: loadedGpuLayers > 0 ? "Metal GPU" : "CPU",
                rollbackDiagnostic: rollbackDiagnosticMessage,
                effectiveBatchSize: nBatch)))

            // Multi-turn and multimodal reuse: record valid conversational turn on natural EOS completion.
            // If KV rollback failed during speculative decoding, the physical KV cache is dirty and must not be reused.
            if stop == .eos && supportsKvRollback && answerStripper.isNoop && !fullGeneratedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let updatedTurns = kept + [ChatTurn(role: .assistant, content: fullGeneratedAnswer)]
                let currentPromptEndPos = baseKvPos + effectivePromptPosAdvance
                if let suffixTokens = incrementalSuffixTokens {
                    sessionCache.append(turns: updatedTurns,
                                        additionalTokens: suffixTokens + generatedTokens,
                                        additionalCount: suffixTokens.count + generatedTokens.count,
                                        promptEndPos: currentPromptEndPos,
                                        promptTurnCount: kept.count,
                                        completedTurnCount: updatedTurns.count)
                } else if let promptTokens = prefilledPromptTokens {
                    let committedTokens: [llama_token]
                    if rollbackSucceeded && cachedRollbackTokensCount > 0 && sessionCache.tokens.count >= cachedRollbackTokensCount {
                        committedTokens = Array(sessionCache.tokens.prefix(cachedRollbackTokensCount)) + suffixTokensToDecode + generatedTokens
                    } else {
                        committedTokens = promptTokens + generatedTokens
                    }
                    sessionCache.commit(turns: updatedTurns,
                                        tokens: committedTokens,
                                        count: currentPromptEndPos + generatedTokens.count,
                                        promptEndPos: currentPromptEndPos,
                                        promptTurnCount: kept.count,
                                        completedTurnCount: updatedTurns.count)
                } else {
                    // Multimodal evaluation (full or incremental):
                    // No purely textual tokens to match for Prefix Rollback, but the total logical
                    // position and extra M-RoPE visual slot count must be preserved so subsequent turns
                    // can incrementally continue with exact position and capacity accounting.
                    sessionCache.commitMultimodal(turns: updatedTurns,
                                                  count: currentPromptEndPos + generatedTokens.count,
                                                  extraVisualTokens: pendingExtraVisualTokens,
                                                  completedTurnCount: updatedTurns.count)
                }
                cont.finish()
                // Save a turn-completed EOS base checkpoint after finishing the UI stream so the
                // disk write never blocks the final token or completion state on the UI side.
                // For multimodal sessions, a visual-prefix checkpoint was already saved during mtmdPrefill,
                // so only write an additional EOS base snapshot once the conversation has grown by > 1024 tokens
                // past the latest saved checkpoint (avoids writing twice per image turn or on every short text follow-up).
                if params.kvCheckpointsEnabled && sessionCache.tokenCount > 0 {
                    let isMultimodalSession = hasImages || sessionCache.hasImages
                    let maxSavedPos = checkpoints.values
                        .filter { $0.turnCount <= updatedTurns.count }
                        .map(\.promptEndPos).max() ?? 0
                    let shouldSaveEos = !isMultimodalSession || (sessionCache.tokenCount - maxSavedPos > 1024)
                    if shouldSaveEos {
                        let completedRendered = Self.tokenize(vocab: vocab,
                                                              text: renderCompletedHistory(updatedTurns),
                                                              addSpecial: true)
                        let tokenHeader = isMultimodalSession ? completedRendered : sessionCache.tokens
                        if !completedRendered.isEmpty && !tokenHeader.isEmpty {
                            saveCheckpoint(turnCount: updatedTurns.count,
                                           promptTokens: tokenHeader,
                                           renderedTokens: completedRendered,
                                           promptEndPos: sessionCache.tokenCount,
                                           extraVisualTokens: sessionCache.extraVisualTokens,
                                           turns: updatedTurns,
                                           hasImages: isMultimodalSession,
                                           context: context)
                        }
                    }
                }
            } else {
                sessionCache.reset(context: context)
                cont.finish()
            }
        } catch is CancellationError {
            // Only purely incremental continuations (where the verified session prefix was never modified or rolled back)
            // can safely prune back to `initialCachedSessionTokenCount`. Any prefix-rollback or full-recompute path
            // altered the physical KV positions, so pruning to the old length would retain alien tokens and corrupt KV cache.
            // Furthermore, multimodal sessions carrying visual ViT embeddings must never undergo partial KV truncation (per e87379f).
            if isIncrementalContinuation, !hasImages, !sessionCache.hasImages, let context, initialCachedSessionTokenCount > 0 && initialCachedSessionTokensCount > 0 {
                // Retain previously verified conversational prefix: prune only uncommitted tokens added during this cancelled turn.
                if sessionCache.prune(to: initialCachedSessionTokenCount, context: context) {
                    NSLog("[LlamaEngine] Cancellation: retained %d prefix tokens (pruned uncommitted turn)", Int32(initialCachedSessionTokenCount))
                } else {
                    supportsPartialTrim = false
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

    private struct MultimodalPrefillResult {
        let posAdvanced: Int
        let totalTokens: Int
        let extraVisualTokens: Int
    }

    /// Multimodal prefill: render `turnsToEval` with a media marker injected per attached image, split the
    /// rendered prompt around media markers, and feed chunks through the vision encoder into the KV cache
    /// starting at logical position `startPos`. When `saveVisualCheckpoint` is true and the final turn
    /// carries images, saves a visual-prefix checkpoint right after the last image chunk (`idx == nChunks - 2`)
    /// so that regenerating or editing the image caption skips ViT re-encoding completely.
    private func mtmdPrefill(turnsToEval: [ChatTurn],
                             fullKeptTurns: [ChatTurn],
                             startPos: Int = 0,
                             addSpecial: Bool = true,
                             saveVisualCheckpoint: Bool = false,
                             context: OpaquePointer,
                             renderPrompt: ([ChatTurn]) -> String,
                             nBatch: Int,
                             governance: GenerationGovernance) async throws -> MultimodalPrefillResult {
        guard let mtmdCtx = mtmdContext else { throw EngineError.visionUnavailable }
        let marker = String(cString: mtmd_default_marker())
        let rawRendered = renderPrompt(Self.injectMediaMarkers(turnsToEval, marker: marker))
        let promptText: String
        if startPos > 0 && promptTemplate != .deepSeek && promptTemplate != .hunyuan && !rawRendered.hasPrefix("\n") {
            promptText = "\n" + rawRendered
        } else {
            promptText = rawRendered
        }

        // Decode each attached image (encoded JPEG/PNG bytes) into an mtmd bitmap, in prompt order.
        var bitmaps: [OpaquePointer?] = []
        defer { for b in bitmaps { if let b { mtmd_bitmap_free(b) } } }
        for turn in turnsToEval {
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
                                        add_special: addSpecial, parse_special: true)
            var bmpArray = bitmaps
            return bmpArray.withUnsafeMutableBufferPointer { buf in
                mtmd_tokenize(mtmdCtx, chunks, &input, buf.baseAddress, bitmaps.count)
            }
        }
        guard tokenizeRC == 0 else { throw EngineError.imageDecodeFailed }

        // Evaluate chunk-by-chunk into the KV cache; only the last chunk needs logits (for the first sample).
        // NOTE: In llama.cpp's `mtmd_helper_eval_chunk_single` (mtmd-helper.cpp:243), text chunks update
        // `*new_n_past` via in-place addition (`*new_n_past += n_added`), whereas image chunks overwrite
        // `*new_n_past = n_past + n_pos`. Therefore `newNPast` MUST be initialized to `nPast` on each step!
        let safeVisionBatch = Int32(min(nBatch, 512))
        let nChunks = mtmd_input_chunks_size(chunks)
        let shouldSaveVisualPrefix = saveVisualCheckpoint && (fullKeptTurns.last?.images.isEmpty == false) && nChunks >= 2
        var runningExtraVisual = startPos > 0 ? sessionCache.extraVisualTokens : 0
        var nPast: llama_pos = Int32(startPos)
        for idx in 0..<nChunks {
            try await governance.checkpoint()
            guard self.context == context else { throw CancellationError() }
            guard let chunk = mtmd_input_chunks_get(chunks, idx) else { throw EngineError.decodeFailed }
            let isLast = idx == nChunks - 1
            let chunkPosStart = nPast
            var newNPast: llama_pos = nPast
            let rc = mtmd_helper_eval_chunk_single(mtmdCtx, context, chunk, nPast, /*seq_id*/ 0,
                                                   safeVisionBatch, /*logits_last*/ isLast, &newNPast)
            guard rc == 0 else { throw EngineError.decodeFailed }
            nPast = newNPast
            let chunkPosAdvance = max(0, Int(nPast - chunkPosStart))
            let chunkTokens = Int(mtmd_input_chunk_get_n_tokens(chunk))
            runningExtraVisual += max(0, chunkTokens - chunkPosAdvance)
            if Task.isCancelled || governance.isCancelled { throw CancellationError() }
            guard self.context == context else { throw CancellationError() }   // reentrant teardown

            if shouldSaveVisualPrefix && idx == nChunks - 2, let vocab {
                var visualTurns = fullKeptTurns
                if let last = visualTurns.last {
                    visualTurns[visualTurns.count - 1] = ChatTurn(role: last.role, content: "", images: last.images)
                }
                let headerTokens = Self.tokenize(vocab: vocab, text: renderPrompt(visualTurns), addSpecial: true)
                if !headerTokens.isEmpty {
                    saveCheckpoint(turnCount: fullKeptTurns.count,
                                   promptTokens: headerTokens,
                                   renderedTokens: headerTokens,
                                   promptEndPos: Int(nPast),
                                   extraVisualTokens: runningExtraVisual,
                                   turns: visualTurns,
                                   hasImages: true,
                                   context: context)
                }
            }
        }
        let totalTokens = Int(mtmd_helper_get_n_tokens(chunks))
        let advancedPos = Int(nPast) - startPos
        let effectivePosAdvance = advancedPos > 0 ? advancedPos : totalTokens
        return MultimodalPrefillResult(posAdvanced: effectivePosAdvance,
                                       totalTokens: totalTokens,
                                       extraVisualTokens: runningExtraVisual)
    }

    /// Downsample large input images (e.g. 12MP/48MP camera shots) to an optimal max dimension
    /// before feeding into mtmd. On mobile Metal, capping at 512px drastically reduces ViT attention
    /// patch count (from ~1300 down to ~300) and quadratic self-attention latency while producing
    /// ~100-130 visual tokens, slashing ViT forward-pass time from ~8s to ~1.8s.
    static func downsampleImageDataIfNeeded(_ data: Data, maxDimension: CGFloat = 512) -> Data {
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

    /// Serialize completed turns (ending with an `.assistant` turn closed by EOG, without trailing
    /// newline or next-turn assistant opener) so the tokenized result matches the prefix of the next
    /// turn's full prompt up to the assistant EOG boundary.
    static func buildCompletedPrompt(messages: [ChatTurn], template: PromptTemplate) -> String {
        switch template {
        case .chatML, .auto:
            var s = ""
            for m in messages {
                let role: String
                switch m.role { case .system: role = "system"; case .user: role = "user"; case .assistant: role = "assistant" }
                s += "<|im_start|>\(role)\n\(m.content)<|im_end|>\n"
            }
            return s.hasSuffix("\n") ? String(s.dropLast()) : s
        case .deepSeek:
            let eos = "<｜end▁of▁sentence｜>"
            var s = coalescedSystemPrompt(messages)
            for m in messages {
                switch m.role {
                case .system: break
                case .user: s += "<｜User｜>\(m.content)<｜Assistant｜>"
                case .assistant: s += "\(m.content)\(eos)"
                }
            }
            return s
        case .hunyuan:
            let eos = "<｜hy_place▁holder▁no▁2｜>"
            var s = coalescedSystemPrompt(messages)
            for m in messages {
                switch m.role {
                case .system: break
                case .user: s += "<｜hy_User｜>\(m.content)<｜hy_Assistant｜>"
                case .assistant: s += "\(m.content)\(eos)"
                }
            }
            return s
        case .gemma:
            var s = ""
            for m in messages {
                let role: String
                switch m.role { case .system: role = "system"; case .user: role = "user"; case .assistant: role = "model" }
                s += "<|turn>\(role)\n\(m.content)<turn|>\n"
            }
            return s.hasSuffix("\n") ? String(s.dropLast()) : s
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

    /// Output space reserved by context fitting. When `contextCap` is supplied, the planning reserve is
    /// bounded by `ContextPolicy.reservedOutputTokens(for:)` so the engine never silently evicts older turns
    /// before upper-layer compaction (`ContextCompactor` / `ContextCompiler`) considers the window full;
    /// `0` retains the existing "unbounded generation" meaning and uses a finite 256-token planning reserve.
    static func answerTokenReserve(maxTokens: Int, contextCap: Int? = nil) -> Int {
        let raw = max(8, maxTokens > 0 ? maxTokens : 256)
        guard let contextCap else { return raw }
        return min(raw, ContextPolicy.reservedOutputTokens(for: contextCap))
    }

    /// Render the prompt with the template EMBEDDED IN THE GGUF via llama.cpp — the path for arbitrary
    /// community checkpoints (Explore), where no hand-written builder exists. Returns nil when the model
    /// ships no template or llama.cpp can't render it, so the caller can fall back to ChatML.
    static func autoPrompt(_ messages: [ChatTurn], modelPtr: OpaquePointer,
                           reasoning: ReasoningStyle, thinking: Bool,
                           addGenerationPrompt: Bool = true) -> String? {
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
            llama_chat_apply_template(tmpl, $0.baseAddress, chat.count, addGenerationPrompt, &buf, Int32(buf.count))
        }
        if n > Int32(buf.count) {                       // grow once if the template needs more room
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = chat.withUnsafeBufferPointer {
                llama_chat_apply_template(tmpl, $0.baseAddress, chat.count, addGenerationPrompt, &buf, Int32(buf.count))
            }
        }
        guard n > 0 else { return nil }
        let rendered = String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard addGenerationPrompt else { return rendered }
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("<think>") {
            return thinking ? rendered : (rendered + "\n</think>\n\n")
        }
        if trimmed.hasSuffix("</think>") {
            return rendered
        }
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
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(nVocab, 64, Float(params.repetitionPenalty), 0, 0))
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
        /// Extra physical KV slots occupied by M-RoPE images beyond `tokenCount` (which tracks logical `llama_pos`).
        private(set) var extraVisualTokens: Int = 0
        /// Maps turn count (e.g. `kept.count`) to the exact physical KV position where that prompt's prefill ended.
        /// This allows instant 99.9% KV cache reuse on regenerate without re-tokenizing and risking BPE boundary divergence.
        private(set) var turnPromptEndPositions: [Int: Int] = [:]
        /// Maps completed assistant turn count (e.g. `updatedTurns.count`) to the exact physical KV position
        /// where that turn's generation ended naturally (EOS). This allows 99.9% KV cache reuse on edit-and-resend
        /// without relying on fragile token-level LCP comparisons.
        private(set) var turnEndPositions: [Int: Int] = [:]

        var physicalTokenCount: Int { tokenCount + extraVisualTokens }
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
            extraVisualTokens = 0
            turnPromptEndPositions.removeAll()
            turnEndPositions.removeAll()
        }

        /// Prune the session cache to `count` tokens by trimming the physical KV cache.
        ///
        /// **What is pruned**: `tokens` (the authoritative KV-position map) and `tokenCount` are
        /// truncated to `count`. This is the only source of truth for which physical slots are live.
        ///
        /// **What is intentionally NOT pruned**: `turns` is left untouched. `turns` is used solely
        /// as the source of truth for reconstructing the next prompt (KV marker), not as an independent
        /// turn counter. After a successful prefix rollback the logical turn boundaries are still valid —
        /// only the suffix tokens are evicted from the KV cache, so `turns` must remain intact so the
        /// next `chatTurns()` call can rebuild the correct full prompt. Do NOT use `turns.count` to
        /// infer how many rounds of conversation have been physically prefilled; use `tokenCount` for
        /// that. Callers that need to count logical turns should query the conversation store, not this
        /// cache state.
        ///
        /// If `llama_memory_seq_rm` fails (e.g. Qwen 3.5 hybrid Gated DeltaNet / recurrent state
        /// cannot be partially rewound), a full `reset(context:)` is performed to enforce consistency.
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
                extraVisualTokens = 0
                turnPromptEndPositions = turnPromptEndPositions.filter { $0.value <= count }
                turnEndPositions = turnEndPositions.filter { $0.value <= count }
                // `turns` is intentionally left intact — see doc comment above.
                return true
            } else {
                reset(context: context)
                return false
            }
        }

        /// Commit full turns, tokens, and count on natural completion.
        mutating func commit(turns: [ChatTurn], tokens: [llama_token], count: Int,
                             promptEndPos: Int? = nil, promptTurnCount: Int? = nil,
                             completedTurnCount: Int? = nil) {
            self.turns = turns
            self.tokens = tokens
            self.tokenCount = count
            self.extraVisualTokens = 0
            if let promptEndPos, let promptTurnCount {
                self.turnPromptEndPositions[promptTurnCount] = promptEndPos
            }
            if let completedTurnCount {
                self.turnEndPositions[completedTurnCount] = count
            }
        }

        /// Append tokens to existing session cache on incremental suffix turn.
        mutating func append(turns: [ChatTurn], additionalTokens: [llama_token], additionalCount: Int,
                             promptEndPos: Int? = nil, promptTurnCount: Int? = nil,
                             completedTurnCount: Int? = nil) {
            self.turns = turns
            if !tokens.isEmpty {
                self.tokens.append(contentsOf: additionalTokens)
            }
            self.tokenCount += additionalCount
            if let promptEndPos, let promptTurnCount {
                self.turnPromptEndPositions[promptTurnCount] = promptEndPos
            }
            if let completedTurnCount {
                self.turnEndPositions[completedTurnCount] = self.tokenCount
            }
        }

        /// Multimodal evaluation commit: logical position (`count`) and extra M-RoPE visual slot overhead tracked.
        mutating func commitMultimodal(turns: [ChatTurn], count: Int, extraVisualTokens: Int = 0,
                                       completedTurnCount: Int? = nil) {
            self.turns = turns
            self.tokens.removeAll()
            self.tokenCount = count
            self.extraVisualTokens = extraVisualTokens
            if let completedTurnCount {
                self.turnEndPositions[completedTurnCount] = count
            }
        }

        /// Roll the logical cache state back to a whole-sequence checkpoint boundary, used right after
        /// `llama_state_seq_load_file` restored the physical KV / recurrent state. Replaces the token
        /// map with the checkpoint snapshot and keeps only turn boundaries up to `turnCount`.
        mutating func rollbackToCheckpoint(turns: [ChatTurn], tokens: [llama_token], count: Int,
                                           turnCount: Int, promptEndPos: Int, extraVisualTokens: Int = 0) {
            self.turns = turns
            self.tokens = tokens
            self.tokenCount = count
            self.extraVisualTokens = extraVisualTokens
            self.turnPromptEndPositions = self.turnPromptEndPositions.filter { $0.key <= turnCount }
            self.turnPromptEndPositions[turnCount] = promptEndPos
            self.turnEndPositions = self.turnEndPositions.filter { $0.key <= turnCount }
            if turns.last?.role == .assistant {
                self.turnEndPositions[turnCount] = count
            }
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
