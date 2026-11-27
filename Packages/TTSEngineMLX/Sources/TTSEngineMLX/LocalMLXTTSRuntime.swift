// SPDX-License-Identifier: MIT

import Foundation
import MLX
import MobileLLMUI
import TTSAudioCommon
@preconcurrency import TTSCosyVoice
@preconcurrency import TTSQwen3

/// Errors surfaced by the local MLX speech runtime.
public enum LocalMLXTTSError: LocalizedError, Sendable {
    case simulatorUnsupported
    case noInstalledModel
    case unsupportedModel(String)
    case missingWeights(String)
    case emptyAudio
    case audioPlaybackFailed

    public var errorDescription: String? {
        switch self {
        case .simulatorUnsupported:
            return "Local MLX voice synthesis requires an Apple Silicon device (not supported in the iOS Simulator)."
        case .noInstalledModel:
            return "No local MLX voice model is downloaded yet."
        case .unsupportedModel(let modelID):
            return "Unsupported local MLX voice model: \(modelID)"
        case .missingWeights(let path):
            return "Local MLX voice weights are incomplete at \(path)."
        case .emptyAudio:
            return "Local MLX voice synthesis produced empty audio."
        case .audioPlaybackFailed:
            return "Failed to decode or play local MLX voice audio."
        }
    }
}

/// Reference clip + transcript passed when speaking with a zero-shot cloned voice.
public struct LocalMLXTTSVoiceCloneReference: Sendable, Equatable {
    public let profileID: String
    public let audioURL: URL
    public let referenceTranscript: String?

    public init(profileID: String, audioURL: URL, referenceTranscript: String?) {
        self.profileID = profileID
        self.audioURL = audioURL
        self.referenceTranscript = referenceTranscript
    }
}

/// Self-contained inference request passed into `LocalMLXTTSRuntime`.
public struct LocalMLXTTSRequest: Sendable {
    public let text: String
    public let modelID: String
    public let variantID: String
    public let weightsDirectory: URL
    public let voiceID: String?
    public let rate: Double
    public let cloneReference: LocalMLXTTSVoiceCloneReference?

    public init(
        text: String,
        modelID: String,
        variantID: String,
        weightsDirectory: URL,
        voiceID: String?,
        rate: Double,
        cloneReference: LocalMLXTTSVoiceCloneReference? = nil
    ) {
        self.text = text
        self.modelID = modelID
        self.variantID = variantID
        self.weightsDirectory = weightsDirectory
        self.voiceID = voiceID
        self.rate = rate
        self.cloneReference = cloneReference
    }
}

/// Pure text/voice mapping helpers shared between runtime and unit tests.
public enum LocalMLXTTSMapping {
    public static func detectLanguage(for text: String, voiceID: String?) -> String {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF:
                return "japanese"
            case 0xAC00...0xD7AF, 0x1100...0x11FF:
                return "korean"
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
                return "chinese"
            default:
                continue
            }
        }
        if let voiceID = voiceID?.lowercased(), voiceID.contains("zh") {
            return "chinese"
        }
        return "english"
    }

    public static func cosyVoiceInstruction(for voiceID: String?) -> String {
        switch voiceID?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "warm_female":
            return "Speak in a warm, gentle female voice."
        case "clear_male":
            return "Speak in a clear, calm male voice."
        case "default_en", "default_zh", "", nil:
            return "You are a helpful assistant."
        default:
            return "You are a helpful assistant."
        }
    }

    public static func qwen3Speaker(for voiceID: String?) -> String {
        let trimmed = voiceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || ClonedVoiceProfile.isClonedVoiceID(trimmed) {
            return "vivian"
        }
        return trimmed.lowercased()
    }

    /// Splits a request into short chunks so DiT + HiFi-GAN intermediate Metal tensors stay
    /// well within iOS memory budgets even for long unpunctuated replies.
    public static func splitIntoSafeChunks(_ text: String, maxCharacters: Int = 85) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let limit = max(1, maxCharacters)
        guard trimmed.count > limit else { return [trimmed] }

        let sentenceEnds: Set<Character> = ["。", "！", "？", "!", "?"]
        let clauseEnds: Set<Character> = ["，", ",", "；", ";", "：", ":", "\n"]
        var chunks: [String] = []
        var cursor = trimmed.startIndex

        while cursor < trimmed.endIndex {
            let remaining = trimmed.distance(from: cursor, to: trimmed.endIndex)
            if remaining <= limit {
                let tail = String(trimmed[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { chunks.append(tail) }
                break
            }

            let hardEnd = trimmed.index(cursor, offsetBy: limit)
            let window = trimmed[cursor..<hardEnd]

            var splitAt: String.Index?
            if let idx = window.lastIndex(where: { sentenceEnds.contains($0) }) {
                let next = trimmed.index(after: idx)
                if next > cursor { splitAt = next }
            }
            if splitAt == nil, let idx = window.lastIndex(where: { clauseEnds.contains($0) }) {
                let next = trimmed.index(after: idx)
                if next > cursor { splitAt = next }
            }
            if splitAt == nil, let idx = window.lastIndex(where: { $0.isWhitespace }) {
                let next = trimmed.index(after: idx)
                if next > cursor { splitAt = next }
            }

            let chosenEnd = splitAt ?? hardEnd
            let piece = String(trimmed[cursor..<chosenEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                chunks.append(piece)
            }
            cursor = chosenEnd
            while cursor < trimmed.endIndex, trimmed[cursor].isWhitespace {
                cursor = trimmed.index(after: cursor)
            }
        }

        return chunks
    }

    /// Joins multiple synthesized PCM chunks with brief zero-crossing fades and silence gaps
    /// so inner-chunk boundaries avoid audible clicks while single-chunk outputs stay untouched.
    public static func stitchAudioChunks(
        _ chunks: [[Float]],
        sampleRate: Int,
        gapSeconds: Double = 0.08,
        edgeFadeSeconds: Double = 0.015
    ) -> [Float] {
        let nonEmpty = chunks.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return [] }
        if nonEmpty.count == 1 {
            return nonEmpty[0]
        }

        let gapCount = max(0, Int(Double(sampleRate) * gapSeconds))
        let fadeCount = max(0, Int(Double(sampleRate) * edgeFadeSeconds))
        let totalCount = nonEmpty.reduce(0) { $0 + $1.count } + gapCount * (nonEmpty.count - 1)
        var output: [Float] = []
        output.reserveCapacity(totalCount)

        for (index, chunk) in nonEmpty.enumerated() {
            var samples = chunk
            let n = min(fadeCount, samples.count / 2)
            if n > 0 {
                for i in 0..<n {
                    let t = Double(i + 1) / Double(n + 1)
                    samples[i] *= Float(sin(t * (.pi / 2)))
                }
                let tailStart = samples.count - n
                for i in 0..<n {
                    let t = Double(i + 1) / Double(n + 1)
                    samples[tailStart + i] *= Float(cos(t * (.pi / 2)))
                }
            }
            if index > 0 && gapCount > 0 {
                output.append(contentsOf: repeatElement(Float(0), count: gapCount))
            }
            output.append(contentsOf: samples)
        }
        return output
    }
}

/// Single-resident MLX TTS execution actor.
/// Holds at most one loaded TTS model at a time, clears MLX reuse cache after each utterance,
/// and supports explicit unloading for idle / background / erase / deletion events.
public actor LocalMLXTTSRuntime {
    private enum LoadedBackend {
        case cosyVoice(CosyVoiceTTSModel, variantID: String)
        case qwen3(Qwen3TTSModel, variantID: String)

        var variantID: String {
            switch self {
            case .cosyVoice(_, let id), .qwen3(_, let id):
                return id
            }
        }

        func unload() {
            switch self {
            case .cosyVoice(let model, _):
                model.unload()
            case .qwen3(let model, _):
                model.unload()
            }
        }
    }

    private struct CloneProfileCacheKey: Equatable {
        let variantID: String
        let profileID: String
        let audioPath: String
        let fileModificationDate: Date?
        let referenceTranscript: String?
    }

    private var loaded: LoadedBackend?
    private var cachedCosyVoiceProfile: (key: CloneProfileCacheKey, profile: CosyVoiceVoiceProfile)?

    public init() {}

    public func prewarm(modelID: String, variantID: String, weightsDirectory: URL) throws {
        #if targetEnvironment(simulator)
        throw LocalMLXTTSError.simulatorUnsupported
        #else
        try Task.checkCancellation()
        _ = try ensureLoaded(modelID: modelID, variantID: variantID, directory: weightsDirectory)
        Memory.clearCache()
        #endif
    }

    public func synthesize(_ request: LocalMLXTTSRequest) throws -> (samples: [Float], sampleRate: Int) {
        #if targetEnvironment(simulator)
        throw LocalMLXTTSError.simulatorUnsupported
        #else
        try Task.checkCancellation()
        defer { Memory.clearCache() }

        let backend = try ensureLoaded(
            modelID: request.modelID,
            variantID: request.variantID,
            directory: request.weightsDirectory
        )
        try Task.checkCancellation()

        let language = LocalMLXTTSMapping.detectLanguage(for: request.text, voiceID: request.voiceID)
        let chunks = LocalMLXTTSMapping.splitIntoSafeChunks(request.text, maxCharacters: 85)
        guard !chunks.isEmpty else {
            throw LocalMLXTTSError.emptyAudio
        }

        var renderedChunks: [[Float]] = []
        renderedChunks.reserveCapacity(chunks.count)
        var sampleRate = 24_000

        switch backend {
        case .cosyVoice(let model, let variantID):
            sampleRate = model.config.sampleRate
            let cloneProfile: CosyVoiceVoiceProfile?
            if let cloneRef = request.cloneReference {
                cloneProfile = try ensureCosyVoiceProfile(
                    model: model,
                    variantID: variantID,
                    weightsDirectory: request.weightsDirectory,
                    reference: cloneRef
                )
            } else {
                cloneProfile = nil
            }
            let instruction = LocalMLXTTSMapping.cosyVoiceInstruction(for: request.voiceID)

            for chunk in chunks {
                try Task.checkCancellation()
                let chunkLang = LocalMLXTTSMapping.detectLanguage(for: chunk, voiceID: request.voiceID)
                let chunkSamples: [Float]
                if let cloneProfile {
                    chunkSamples = model.synthesize(
                        text: chunk,
                        voiceProfile: cloneProfile,
                        language: chunkLang.isEmpty ? language : chunkLang
                    )
                } else {
                    chunkSamples = model.synthesize(
                        text: chunk,
                        language: chunkLang.isEmpty ? language : chunkLang,
                        instruction: instruction
                    )
                }
                Memory.clearCache()
                try Task.checkCancellation()
                if !chunkSamples.isEmpty {
                    renderedChunks.append(chunkSamples)
                }
            }
        case .qwen3(let model, _):
            sampleRate = model.sampleRate
            let speaker = LocalMLXTTSMapping.qwen3Speaker(for: request.voiceID)

            for chunk in chunks {
                try Task.checkCancellation()
                let chunkLang = LocalMLXTTSMapping.detectLanguage(for: chunk, voiceID: request.voiceID)
                let chunkSamples = try model.synthesizeCheckingCancellation(
                    text: chunk,
                    language: chunkLang.isEmpty ? language : chunkLang,
                    speaker: speaker
                )
                Memory.clearCache()
                try Task.checkCancellation()
                if !chunkSamples.isEmpty {
                    renderedChunks.append(chunkSamples)
                }
            }
        }

        try Task.checkCancellation()
        let combinedSamples = LocalMLXTTSMapping.stitchAudioChunks(renderedChunks, sampleRate: sampleRate)
        guard !combinedSamples.isEmpty else {
            throw LocalMLXTTSError.emptyAudio
        }
        let rateAdjustedSamples = LocalTTSAudioTimeStretcher.stretch(
            samples: combinedSamples,
            sampleRate: sampleRate,
            rate: request.rate
        )
        return (rateAdjustedSamples, sampleRate)
        #endif
    }

    public func unload() {
        cachedCosyVoiceProfile = nil
        guard let loaded else { return }
        loaded.unload()
        self.loaded = nil
        Memory.clearCache()
    }

    private func ensureCosyVoiceProfile(
        model: CosyVoiceTTSModel,
        variantID: String,
        weightsDirectory: URL,
        reference: LocalMLXTTSVoiceCloneReference
    ) throws -> CosyVoiceVoiceProfile {
        let normalizedTranscript: String? = {
            let trimmed = reference.referenceTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }()
        let modDate = (try? FileManager.default.attributesOfItem(atPath: reference.audioURL.path)[.modificationDate]) as? Date
        let key = CloneProfileCacheKey(
            variantID: variantID,
            profileID: reference.profileID,
            audioPath: reference.audioURL.path,
            fileModificationDate: modDate,
            referenceTranscript: normalizedTranscript
        )
        if let cached = cachedCosyVoiceProfile, cached.key == key {
            return cached.profile
        }

        let tokenizerURL = weightsDirectory.appending(component: "speech_tokenizer.safetensors")
        guard FileManager.default.fileExists(atPath: tokenizerURL.path) else {
            throw LocalMLXTTSError.missingWeights(tokenizerURL.path)
        }

        let decoded = try AudioSampleDecoder.loadMonoFloatSamples(from: reference.audioURL)
        try Task.checkCancellation()

        let profile: CosyVoiceVoiceProfile = try {
            let speechTokenizer = try SpeechTokenizerModel.fromSafetensors(at: tokenizerURL)
            return try model.extractVoiceProfile(
                audio: decoded.samples,
                sampleRate: decoded.sampleRate,
                speechTokenizer: speechTokenizer,
                referenceTranscript: normalizedTranscript
            )
        }()
        // Release the 484 MB S3-Tokenizer buffers immediately after extracting compact FSQ + Mel tensors.
        Memory.clearCache()
        cachedCosyVoiceProfile = (key, profile)
        return profile
    }

    private func ensureLoaded(
        modelID: String,
        variantID: String,
        directory: URL
    ) throws -> LoadedBackend {
        if let loaded, loaded.variantID == variantID {
            return loaded
        }

        unload()

        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else {
            throw LocalMLXTTSError.missingWeights(directory.path)
        }

        let next: LoadedBackend
        switch modelID {
        case LocalTTSModelCatalog.cosyVoice305B.id:
            let model = try CosyVoiceTTSModel.fromLocal(directory: directory)
            next = .cosyVoice(model, variantID: variantID)
        case LocalTTSModelCatalog.qwen3TTS06B.id:
            let tokenizerDir = directory.appending(component: "speech_tokenizer")
            let resolvedTokenizerDir = fm.fileExists(atPath: tokenizerDir.path) ? tokenizerDir : directory
            let model = try Qwen3TTSModel.fromLocal(
                modelDirectory: directory,
                tokenizerDirectory: resolvedTokenizerDir,
                wiredMemoryPolicy: .none
            )
            next = .qwen3(model, variantID: variantID)
        default:
            throw LocalMLXTTSError.unsupportedModel(modelID)
        }

        loaded = next
        return next
    }
}
