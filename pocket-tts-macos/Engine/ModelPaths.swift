//
//  ModelPaths.swift
//  pocket-tts-macos
//

import Foundation

// MARK: - ModelPaths
// Single source of truth for every model / asset URL the engine reads. The
// engine layer never hardcodes paths or string literals; everything resolves
// through one of the static lookups below.
//
// Two resolution strategies live side-by-side here:
//
//   * Core ML mlpackages (prompt_phase, calm_stateful, mimi_stateful,
//     voice_prompt_phase) — Phase 8 moves these out of the .app bundle and
//     into a runtime-downloaded location under Application Support, managed
//     by `BundledMLModelManager`. The accessors below check the manager
//     FIRST; if not yet installed, they fall back to the Bundle.main
//     location so that a build that still bundles them (legacy / dev with
//     sync-assets.sh populated Resources/) keeps working unchanged.
//
//   * Tokenizer + voice KV states — these stay bundled. They're small
//     (<10 MB combined), they ship with the app, and Bundle.main is the
//     only location they ever live at.
//
// Bundled assets land under Resources/ via scripts/sync-assets.sh and are
// auto-included in the app target via Xcode's
// PBXFileSystemSynchronizedRootGroup.

nonisolated enum ModelPaths {
    /// Resolution errors thrown when an expected asset is missing from
    /// both the runtime download manager AND the app bundle.
    enum LookupError: Error, CustomStringConvertible {
        case missing(name: String, ext: String, subdirectory: String)
        case voiceDirectoryMissing
        /// One of the runtime-downloaded mlpackages isn't installed yet
        /// and isn't in the bundle either. The user should never see
        /// this — AppState gates engine bootstrap on
        /// `BundledMLModelManager.shared.isReady` — but the case exists
        /// so a misconfigured manager surfaces a useful message.
        case mlpackageNotInstalled(BundledMLModel)

        var description: String {
            switch self {
            case let .missing(name, ext, subdirectory):
                return "missing bundle resource \(subdirectory)/\(name).\(ext)"
            case .voiceDirectoryMissing:
                return "Resources/voice_kv_states/ is not bundled"
            case let .mlpackageNotInstalled(model):
                return "\(model.displayName) is not installed (run first-launch download)"
            }
        }
    }

    // MARK: Core ML packages
    //
    // Each accessor follows the same pattern:
    //   1. Ask BundledMLModelManager — already downloaded?
    //   2. If yes, return the Application Support URL.
    //   3. If no, look in Bundle.main (sync-assets.sh path, legacy
    //      builds, App Store builds that still bundle).
    //   4. If neither, throw `.mlpackageNotInstalled`.
    //
    // The manager-first ordering matters: once a user has downloaded a
    // model, that copy is the source of truth. A future bundled build
    // shipped over an existing install wouldn't shadow the user's
    // download. (In practice the bundle is going to be empty by v1.4
    // release anyway, but the order is defensive.)
    //
    // The manager's `compiledModelURL(for:)` is `nonisolated` (file-
    // system read, no @Observable touch) so these accessors stay
    // callable from inside TTSEngine's actor isolation without an
    // actor hop.

    static func promptPhase() throws -> URL {
        try resolveMLPackage(.promptPhase, bundleName: "prompt_phase")
    }

    static func calmStateful() throws -> URL {
        try resolveMLPackage(.calmStateful, bundleName: "calm_stateful")
    }

    static func mimiStateful() throws -> URL {
        try resolveMLPackage(.mimiStateful, bundleName: "mimi_stateful")
    }

    /// Resolver for the voice-import baker. Same dual-source pattern as
    /// the synthesis trio above; consumed by `PocketTTSVoiceEncoder` on
    /// the voice-import path only.
    static func voicePromptPhase() throws -> URL {
        try resolveMLPackage(.voicePromptPhase, bundleName: "voice_prompt_phase")
    }

    /// Shared lookup logic for the four runtime-downloadable mlpackages.
    /// Pulled out so adding a fifth model (if we ever do) is one line
    /// in the accessor + one case in `BundledMLModel`.
    ///
    /// Uses the static `BundledMLModelManager.compiledModelURL` (not
    /// the instance method) so the lookup doesn't have to cross
    /// MainActor isolation from inside TTSEngine's actor context.
    private static func resolveMLPackage(
        _ model: BundledMLModel,
        bundleName: String
    ) throws -> URL {
        // 1) Runtime-downloaded copy under Application Support.
        if let downloaded = BundledMLModelManager.compiledModelURL(for: model) {
            return downloaded
        }
        // 2) Bundled copy (sync-assets.sh / legacy builds).
        if let bundled = Bundle.main.url(
            forResource: bundleName, withExtension: "mlmodelc", subdirectory: nil
        ) {
            return bundled
        }
        // 3) Neither. Should be unreachable in production — engine
        //    bootstrap gates on `BundledMLModelManager.isReady`.
        throw LookupError.mlpackageNotInstalled(model)
    }

    // MARK: Tokenizer + voices

    static func tokenizerModel() throws -> URL {
        try url(forResource: "tokenizer", withExtension: "model", subdirectory: nil)
    }

    /// URL for one voice's KV state safetensors file.
    static func voiceKVState(voiceID: String) throws -> URL {
        try url(forResource: voiceID, withExtension: "safetensors", subdirectory: nil)
    }

    /// All `<id>.safetensors` files in the main bundle, sorted by id.
    /// Used by VoiceLoader to build the catalog without a hardcoded list — any
    /// voice file added at sync time shows up automatically.
    static func allVoiceKVStateFiles() throws -> [URL] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "safetensors", subdirectory: nil) else {
            throw LookupError.voiceDirectoryMissing
        }
        // Filter out non-voice safetensors (model weights, not voice KV states)
        let nonVoicePrefixes = ["lavasr", "mimi_encoder"]
        return urls
            .filter { name in !nonVoicePrefixes.contains { name.lastPathComponent.hasPrefix($0) } }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Private

    private static func url(forResource name: String, withExtension ext: String, subdirectory: String?) throws -> URL {
        if let u = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
            return u
        }
        throw LookupError.missing(name: name, ext: ext, subdirectory: subdirectory ?? "")
    }
}
