// swift-tools-version: 6.0
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
    targets: [
        .executableTarget(
            name: "pockettts",
            path: ".",
            sources: [
                "headless/main.swift",
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
            ]
        )
    ]
)
