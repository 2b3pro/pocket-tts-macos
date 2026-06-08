//
//  ModelPaths.swift  (HEADLESS variant)
//  pockettts (swift build / daemon)
//
//  The app's ModelPaths (mimika-ai-voice-studio/Engine/TTS/ModelPaths.swift) was
//  rewritten in the upstream Phase 8 rebrand to resolve every asset through
//  `BundledMLModelManager` — the @MainActor @Observable runtime-download manager
//  (HF download, unzip, install under Application Support). The headless build
//  deliberately does NOT link that manager (no networking, no first-launch UI,
//  no @Observable surface), so it ships its own ModelPaths with the same accessor
//  names but a different resolution strategy:
//
//      POCKET_TTS_RESOURCES override dir  →  Bundle.main  →  throw
//
//  Set POCKET_TTS_RESOURCES (the CLI's --resources flag) to a directory holding
//  the staged, already-compiled assets (`*.mlmodelc`, `tokenizer*.{model,json}`,
//  `<voice>.safetensors`, `mimi_encoder_weights.safetensors`). The app target
//  never compiles THIS file — Package.swift links it in place of the app's.
//
//  Decision (2026-06-07): keep the env-override strategy for the daemon rather
//  than adopt Phase 8 runtime download — deterministic, offline, no download UI.
//  See docs/HEADLESS_DAEMON.md and docs/UPSTREAM.md.

import Foundation

// MARK: - ModelPaths

nonisolated enum ModelPaths {
    enum LookupError: Error, CustomStringConvertible {
        case missing(name: String, ext: String, subdirectory: String)
        case voiceDirectoryMissing

        var description: String {
            switch self {
            case let .missing(name, ext, subdirectory):
                return "missing resource \(subdirectory)/\(name).\(ext) "
                    + "(set POCKET_TTS_RESOURCES to a dir containing it)"
            case .voiceDirectoryMissing:
                return "no voice KV-state safetensors found "
                    + "(set POCKET_TTS_RESOURCES to a dir containing <voice>.safetensors)"
            }
        }
    }

    // MARK: Core ML packages
    // The app's synchronized-group pipeline compiles each .mlpackage to .mlmodelc;
    // the daemon expects the staged resources dir to already contain the .mlmodelc.

    static func promptPhase() throws -> URL {
        try url(forResource: "prompt_phase", withExtension: "mlmodelc")
    }

    static func calmStateful() throws -> URL {
        try url(forResource: "calm_stateful", withExtension: "mlmodelc")
    }

    static func mimiStateful() throws -> URL {
        try url(forResource: "mimi_stateful", withExtension: "mlmodelc")
    }

    /// Voice-import baker (clone-bake path only).
    static func voicePromptPhase() throws -> URL {
        try url(forResource: "voice_prompt_phase", withExtension: "mlmodelc")
    }

    // MARK: Tokenizer + voices

    static func tokenizerModel() throws -> URL {
        try url(forResource: "tokenizer", withExtension: "model")
    }

    static func tokenizerVocab() throws -> URL {
        try url(forResource: "tokenizer_vocab", withExtension: "json")
    }

    static func voiceKVState(voiceID: String) throws -> URL {
        try url(forResource: voiceID, withExtension: "safetensors")
    }

    /// All `<id>.safetensors` voice files in the override dir (or bundle),
    /// sorted by id, filtering out non-voice model-weight safetensors.
    static func allVoiceKVStateFiles() throws -> [URL] {
        let nonVoicePrefixes = ["lavasr", "mimi_encoder"]
        let isVoice: (URL) -> Bool = { u in
            u.pathExtension == "safetensors"
                && !nonVoicePrefixes.contains { u.lastPathComponent.hasPrefix($0) }
        }

        if let dir = overrideResourcesDir {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            let voices = contents.filter(isVoice)
            if !voices.isEmpty {
                return voices.sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
        }

        guard let urls = Bundle.main.urls(forResourcesWithExtension: "safetensors", subdirectory: nil) else {
            throw LookupError.voiceDirectoryMissing
        }
        return urls.filter(isVoice).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Voice-tools (Mimi encoder weights for the clone-bake path)

    static func mimiEncoderWeights() throws -> URL {
        try url(forResource: "mimi_encoder_weights", withExtension: "safetensors")
    }

    /// Generic override-then-bundle resolver for any caller outside this enum.
    static func resource(_ name: String, _ ext: String) throws -> URL {
        try url(forResource: name, withExtension: ext)
    }

    // MARK: Private

    /// Asset directory from the `POCKET_TTS_RESOURCES` env var (the CLI's
    /// `--resources` flag). Resolved BEFORE `Bundle.main`. The app never sets
    /// this, but the app never compiles this file either.
    private static let overrideResourcesDir: URL? = {
        guard let p = ProcessInfo.processInfo.environment["POCKET_TTS_RESOURCES"],
              !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }()

    private static func url(forResource name: String, withExtension ext: String) throws -> URL {
        if let dir = overrideResourcesDir {
            let candidate = dir.appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        if let u = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: nil) {
            return u
        }
        throw LookupError.missing(name: name, ext: ext, subdirectory: "")
    }
}
