# Third-Party Notices (`Packages/TTSEngineMLX`)

`Packages/TTSEngineMLX` incorporates Apache License 2.0 components derived from:

- **soniqo/speech-swift** (commit `8effd8f8cbcb6aa1b9355cc6120c2290f05eafd7`)
  - Website / Source: https://github.com/soniqo/speech-swift
  - License: Apache License 2.0
  - Adapted into the internal `TTSAudioCommon`, `TTSMLXCommon`, `TTSCosyVoice`, and `TTSQwen3` modules to remove network/Hub downloader dependencies and align with `PrismML-Eng/mlx-swift` (`e40e0a57`) and iOS 17.0 / macOS 14.0 deployment targets.

- **FunAudioLLM / Fun-CosyVoice3-0.5B-2512** (model weights downloaded on demand from `aufklarer/CosyVoice3-0.5B-MLX-4bit` and `aufklarer/CosyVoice3-0.5B-MLX-8bit-full`)
  - License: Apache License 2.0

- **Alibaba Qwen / Qwen3-TTS** (model weights downloaded on demand from `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit` and `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit`)
  - License: Apache License 2.0
