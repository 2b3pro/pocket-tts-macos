// swift-tools-version: 6.2
import PackageDescription

// Headless build of the Core ML pocket-tts engine — a CLI/daemon that links the
// app's UI-free Engine/ + Audio/ sources directly (no SwiftUI, no MLX, no
// AVFoundation). P1 scope: `say` with a built-in or pre-baked KV-state voice,
// emitting a WAV. Assets are supplied at runtime via POCKET_TTS_RESOURCES
// (e.g. the installed .app's Contents/Resources), resolved by ModelPaths.
//
// Coexists with pocket-tts-macos.xcodeproj — `swift build` uses this manifest;
// Xcode keeps using the project. The explicit `sources:` list compiles only the
// minimal Core ML synthesis path; the MLX/Whisper/Fish/AVFoundation files are
// simply not listed.
let package = Package(
    name: "pockettts",
    platforms: [.macOS(.v15)],
    dependencies: [
        // MimiEncoder (the clone-bake path) is MLX-native. Pin to the same
        // version the app resolves. Only mlx-swift is needed — the Fish/LavaSR
        // backends (mlx-audio-swift) are not part of the headless build.
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.3"),
    ],
    targets: [
        .executableTarget(
            name: "pockettts",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ],
            path: ".",
            sources: [
                "headless/main.swift",
                // --- Core ML synthesis path (P1, MLX-free) ---
                "pocket-tts-macos/Engine/TTSEngine.swift",
                "pocket-tts-macos/Engine/TTSEngineProtocol.swift",
                "pocket-tts-macos/Engine/Tokenizer.swift",
                "pocket-tts-macos/Engine/SentencePieceTokenizer.swift",
                "pocket-tts-macos/Engine/VoiceLoader.swift",
                "pocket-tts-macos/Engine/Voice.swift",
                "pocket-tts-macos/Engine/ModelPaths.swift",
                "pocket-tts-macos/Engine/TextNormalizer.swift",
                "pocket-tts-macos/Engine/TextNormalizer+Data.swift",
                "pocket-tts-macos/Engine/TextNormalizer+DomainTerms.swift",
                "pocket-tts-macos/Engine/TextNormalizer+Units.swift",
                "pocket-tts-macos/Engine/TextPreprocessor.swift",
                "pocket-tts-macos/Engine/NumberToWords.swift",
                "pocket-tts-macos/Engine/SynthesisCancellation.swift",
                "pocket-tts-macos/Audio/WAVEncoder.swift",
                // --- Clone-bake path (P2, MLX) ---
                "pocket-tts-macos/Engine/PocketTTSVoiceEncoder.swift",
                "pocket-tts-macos/Engine/MimiEncoder.swift",
                "pocket-tts-macos/Engine/AudioPreconditioner.swift",
            ],
            swiftSettings: [
                // Match the app's build (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor,
                // SWIFT_APPROACHABLE_CONCURRENCY = YES) so the shared Engine sources
                // compile under the same concurrency model and we don't fork them.
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        )
    ]
)
