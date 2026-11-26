// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TTSEngineMLX",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TTSEngineMLX", targets: ["TTSEngineMLX"]),
    ],
    dependencies: [
        .package(path: "../MobileLLMUI"),
        .package(path: "../AppRuntime"),
        .package(
            url: "https://github.com/PrismML-Eng/mlx-swift",
            revision: "e40e0a57a6f7ad08dc3fd87ad598a7aa6407d230"
        ),
    ],
    targets: [
        .target(
            name: "TTSAudioCommon",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "TTSMLXCommon",
            dependencies: [
                "TTSAudioCommon",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "TTSCosyVoice",
            dependencies: [
                "TTSAudioCommon",
                "TTSMLXCommon",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "TTSQwen3",
            dependencies: [
                "TTSAudioCommon",
                "TTSMLXCommon",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "TTSEngineMLX",
            dependencies: [
                "TTSAudioCommon",
                "TTSMLXCommon",
                "TTSCosyVoice",
                "TTSQwen3",
                .product(name: "MobileLLMUI", package: "MobileLLMUI"),
                .product(name: "AppRuntime", package: "AppRuntime"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
        .testTarget(
            name: "TTSEngineMLXTests",
            dependencies: [
                "TTSEngineMLX",
                .product(name: "MobileLLMUI", package: "MobileLLMUI"),
                .product(name: "AppRuntime", package: "AppRuntime"),
            ]
        ),
    ]
)
