// swift-tools-version: 5.10
import PackageDescription

// Offline neural TTS engine powered by sherpa-onnx + Kokoro v1.1 (int8).
// Kept separate from `MobileLLMUI` so `MobileLLMUI` stays C++/ONNX-free and fast to test.
let package = Package(
    name: "TTSEngineKokoro",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TTSEngineKokoro", targets: ["TTSEngineKokoro"]),
    ],
    dependencies: [
        .package(path: "../MobileLLMUI"),
        .package(url: "https://github.com/k2-fsa/sherpa-onnx", exact: "2.0.2"),
        .package(url: "https://github.com/tsolomko/SWCompression", from: "4.9.0"),
    ],
    targets: [
        .target(
            name: "TTSEngineKokoro",
            dependencies: [
                .product(name: "MobileLLMUI", package: "MobileLLMUI"),
                .product(name: "sherpa-onnx", package: "sherpa-onnx"),
                .product(name: "SWCompression", package: "SWCompression"),
            ]
        ),
    ]
)
