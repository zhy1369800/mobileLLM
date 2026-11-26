// SPDX-License-Identifier: MIT

import Foundation

/// A curated speaker preset shipped by a local neural TTS model.
public struct LocalTTSVoicePreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let language: String
    public let detail: String

    public init(id: String, name: String, language: String, detail: String) {
        self.id = id
        self.name = name
        self.language = language
        self.detail = detail
    }
}

/// Supported weight quantization levels for local MLX TTS models.
public enum LocalTTSQuant: String, CaseIterable, Codable, Sendable, Hashable {
    case int4
    case int8

    public var displayName: String {
        switch self {
        case .int4: return "4-bit"
        case .int8: return "8-bit"
        }
    }
}

/// A concrete downloadable variant of a local neural TTS model.
public struct LocalTTSModelVariant: Identifiable, Hashable, Sendable {
    public let id: String
    public let quant: LocalTTSQuant
    public let huggingFaceRepo: String
    public let revision: String
    public let approximateBytes: Int64
    public let minimumRecommendedRAMBytes: Int64

    public init(
        id: String,
        quant: LocalTTSQuant,
        huggingFaceRepo: String,
        revision: String = "main",
        approximateBytes: Int64,
        minimumRecommendedRAMBytes: Int64
    ) {
        self.id = id
        self.quant = quant
        self.huggingFaceRepo = huggingFaceRepo
        self.revision = revision
        self.approximateBytes = approximateBytes
        self.minimumRecommendedRAMBytes = minimumRecommendedRAMBytes
    }
}

/// Metadata for a curated local neural voice model shown in Models → Featured → Voice.
public struct LocalTTSModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let publisher: String
    public let summary: String
    public let license: String
    public let variants: [LocalTTSModelVariant]
    public let defaultQuant: LocalTTSQuant
    public let presetVoices: [LocalTTSVoicePreset]

    public init(
        id: String,
        displayName: String,
        publisher: String,
        summary: String,
        license: String,
        variants: [LocalTTSModelVariant],
        defaultQuant: LocalTTSQuant,
        presetVoices: [LocalTTSVoicePreset]
    ) {
        self.id = id
        self.displayName = displayName
        self.publisher = publisher
        self.summary = summary
        self.license = license
        self.variants = variants
        self.defaultQuant = defaultQuant
        self.presetVoices = presetVoices
    }

    public func variant(for quant: LocalTTSQuant) -> LocalTTSModelVariant? {
        variants.first { $0.quant == quant }
    }

    public var defaultVariant: LocalTTSModelVariant {
        variant(for: defaultQuant) ?? variants[0]
    }
}

/// Curated local MLX TTS catalog kept separate from `LLMCatalog` so activating a voice model
/// never displaces the active chat LLM (ideal for Cloud LLM + Local TTS).
public enum LocalTTSModelCatalog {
    public static let cosyVoice305B = LocalTTSModel(
        id: "cosyvoice3-0.5b",
        displayName: "CosyVoice3 0.5B",
        publisher: "FunAudioLLM · MLX",
        summary: "Low-latency Chinese & multilingual neural speech synthesis with natural prosody and style control. Runs locally on Apple Silicon via MLX.",
        license: "Apache-2.0",
        variants: [
            LocalTTSModelVariant(
                id: "cosyvoice3-0.5b-4bit",
                quant: .int4,
                huggingFaceRepo: "mlx-community/Fun-CosyVoice3-0.5B-2512-4bit",
                revision: "main",
                approximateBytes: 1_228_596_082,
                minimumRecommendedRAMBytes: 6 * 1024 * 1024 * 1024
            ),
            LocalTTSModelVariant(
                id: "cosyvoice3-0.5b-8bit",
                quant: .int8,
                huggingFaceRepo: "mlx-community/Fun-CosyVoice3-0.5B-2512-8bit",
                revision: "main",
                approximateBytes: 1_407_510_034,
                minimumRecommendedRAMBytes: 8 * 1024 * 1024 * 1024
            ),
        ],
        defaultQuant: .int4,
        presetVoices: [
            LocalTTSVoicePreset(id: "default_zh", name: "Default Chinese", language: "zh-CN", detail: "Natural Mandarin voice"),
            LocalTTSVoicePreset(id: "default_en", name: "Default English", language: "en-US", detail: "Natural English voice"),
            LocalTTSVoicePreset(id: "warm_female", name: "Warm Female", language: "zh-CN / en-US", detail: "Warm bilingual female style"),
            LocalTTSVoicePreset(id: "clear_male", name: "Clear Male", language: "zh-CN / en-US", detail: "Clear bilingual male style"),
        ]
    )

    public static let qwen3TTS06B = LocalTTSModel(
        id: "qwen3-tts-12hz-0.6b-customvoice",
        displayName: "Qwen3-TTS 0.6B",
        publisher: "Alibaba Qwen · MLX",
        summary: "Multilingual neural speech synthesis with preset Chinese & English voices. Runs locally on Apple Silicon via MLX.",
        license: "Apache-2.0",
        variants: [
            LocalTTSModelVariant(
                id: "qwen3-tts-0.6b-customvoice-4bit",
                quant: .int4,
                huggingFaceRepo: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit",
                revision: "main",
                approximateBytes: 1_693_602_151,
                minimumRecommendedRAMBytes: 6 * 1024 * 1024 * 1024
            ),
            LocalTTSModelVariant(
                id: "qwen3-tts-0.6b-customvoice-8bit",
                quant: .int8,
                huggingFaceRepo: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
                revision: "main",
                approximateBytes: 1_973_572_801,
                minimumRecommendedRAMBytes: 8 * 1024 * 1024 * 1024
            ),
        ],
        defaultQuant: .int4,
        presetVoices: [
            LocalTTSVoicePreset(id: "Vivian", name: "Vivian", language: "zh-CN / en-US", detail: "Bright female voice"),
            LocalTTSVoicePreset(id: "Serena", name: "Serena", language: "zh-CN / en-US", detail: "Warm female voice"),
            LocalTTSVoicePreset(id: "Uncle_Fu", name: "Uncle Fu", language: "zh-CN", detail: "Mature male voice"),
            LocalTTSVoicePreset(id: "Dylan", name: "Dylan", language: "zh-CN", detail: "Natural Beijing male voice"),
            LocalTTSVoicePreset(id: "Eric", name: "Eric", language: "zh-CN", detail: "Clear Sichuan-accented male voice"),
            LocalTTSVoicePreset(id: "Ryan", name: "Ryan", language: "en-US", detail: "Dynamic English male voice"),
            LocalTTSVoicePreset(id: "Aiden", name: "Aiden", language: "en-US", detail: "Calm English male voice"),
            LocalTTSVoicePreset(id: "Ono_Anna", name: "Ono Anna", language: "ja-JP", detail: "Japanese female voice"),
            LocalTTSVoicePreset(id: "Sohee", name: "Sohee", language: "ko-KR", detail: "Korean female voice"),
        ]
    )

    public static let all: [LocalTTSModel] = [cosyVoice305B, qwen3TTS06B]

    public static var defaultModel: LocalTTSModel {
        cosyVoice305B
    }

    public static var defaultVariant: LocalTTSModelVariant {
        defaultModel.defaultVariant
    }

    public static var defaultVoiceID: String {
        defaultModel.presetVoices.first?.id ?? "default_zh"
    }

    public static func model(id: String) -> LocalTTSModel? {
        all.first { $0.id == id }
    }

    public static func variant(id: String) -> (model: LocalTTSModel, variant: LocalTTSModelVariant)? {
        for model in all {
            if let variant = model.variants.first(where: { $0.id == id }) {
                return (model, variant)
            }
        }
        return nil
    }
}
