// swift-tools-version: 6.2
import PackageDescription

// Headless build of the Core ML pocket-tts engine — a CLI/daemon that links the
// app's UI-free Engine/ + Audio/ sources directly (no SwiftUI, no MLX, no
// AVFoundation). P1 scope: `say` with a built-in or pre-baked KV-state voice,
// emitting a WAV. Assets are supplied at runtime via POCKET_TTS_RESOURCES
// (e.g. the installed .app's Contents/Resources), resolved by ModelPaths.
//
// Coexists with mimika-ai-voice-studio.xcodeproj — `swift build` uses this
// manifest; Xcode keeps using the project. The explicit `sources:` list compiles
// only the minimal Core ML synthesis path; the MLX/Demucs/LavaSR/STT/AVFoundation
// files are simply not listed.
//
// Source layout note: upstream (Mimika rebrand) reorganized the tree —
// `pocket-tts-macos/Engine/` → `mimika-ai-voice-studio/Engine/{TTS,Audio,TextProcessing}`
// and `pocket-tts-macos/Audio/` → `mimika-ai-voice-studio/Audio/`. Paths below
// track that layout. See docs/HEADLESS_DAEMON.md.
let package = Package(
    name: "pockettts",
    // The Mimika rebrand added localized resources somewhere under the repo
    // root; since this target uses `path: "."`, SwiftPM discovers them and
    // requires a default localization even though the headless target lists no
    // resources. Declaring it satisfies the manifest check.
    defaultLocalization: "en",
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
                "headless/Server.swift",   // --- Streaming HTTP daemon (P3, MLX-free) ---
                // --- Core ML synthesis path (P1, MLX-free) ---
                "mimika-ai-voice-studio/Engine/TTS/TTSEngine.swift",
                "mimika-ai-voice-studio/Engine/TTS/TTSEngineProtocol.swift",
                "mimika-ai-voice-studio/Engine/TTS/Tokenizer.swift",
                "mimika-ai-voice-studio/Engine/TTS/SentencePieceTokenizer.swift",
                "mimika-ai-voice-studio/Engine/TTS/VoiceLoader.swift",
                "mimika-ai-voice-studio/Engine/TTS/Voice.swift",
                // Headless ModelPaths (env-override strategy) replaces the app's
                // BundledMLModelManager-coupled ModelPaths — see headless/ModelPaths.swift.
                "headless/ModelPaths.swift",
                "mimika-ai-voice-studio/Engine/TextProcessing/TextNormalizer.swift",
                "mimika-ai-voice-studio/Engine/TextProcessing/TextNormalizer+Data.swift",
                "mimika-ai-voice-studio/Engine/TextProcessing/TextNormalizer+DomainTerms.swift",
                "mimika-ai-voice-studio/Engine/TextProcessing/TextNormalizer+Units.swift",
                "mimika-ai-voice-studio/Engine/TextProcessing/TextPreprocessor.swift",
                "mimika-ai-voice-studio/Engine/TextProcessing/NumberToWords.swift",
                "mimika-ai-voice-studio/Engine/TTS/SynthesisCancellation.swift",
                "mimika-ai-voice-studio/Engine/Audio/AudioBuffer.swift",
                "mimika-ai-voice-studio/Audio/WAVEncoder.swift",
                // --- Clone-bake path (P2, MLX) ---
                "mimika-ai-voice-studio/Engine/TTS/PocketTTSVoiceEncoder.swift",
                "mimika-ai-voice-studio/Engine/TTS/MimiEncoder.swift",
                "mimika-ai-voice-studio/Engine/Audio/AudioPreconditioner.swift",
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
