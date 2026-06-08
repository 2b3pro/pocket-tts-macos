//
//  Voice.swift
//  mimika-ai-voice-studio
//
//  Plain value-type models for the saved-voice catalog, extracted from
//  VoiceManager.swift so the engine layer (VoiceLoader, the headless CLI /
//  daemon) can use them WITHOUT pulling in VoiceManager's AVFoundation /
//  Observation imports. VoiceManager keeps the catalog behavior; these types
//  are just the on-disk/in-memory shapes.
//

import Foundation

// MARK: - Voice

struct Voice: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var description: String
    /// In memory: absolute path to the WAV file in the current container.
    /// On disk (voices.json): basename only (`<UUID>.wav`). VoiceManager
    /// translates at the load/save boundary so the catalog is portable
    /// across container moves / bundle-ID changes / sandbox migrations.
    var wavPath: String
    let createdAt: Date
    var transcript: String?
    var transcribedAt: Date?
    var cachedCodesPath: String?
    var codesLength: Int?
    var isEnhanced: Bool = false
    var pocketTTSKVPath: String?
    /// Per-voice RMS target in dB (P1-N1). `nil` falls back to the global
    /// `VoiceLevel.defaultTargetDB` (-16 dB), matching pre-feature behavior
    /// and Python's `_normalize_audio_rms` default. Decoded lazily so
    /// existing voices.json catalogs upgrade without migration.
    var rmsTargetDB: Float?
}

// MARK: - OrphanedVoice
// Files-on-disk-without-a-catalog-row case (the dual of stale catalog
// rows handled by `verifyVoiceStates`). Surfaced by `scanForOrphans`
// so the Voice Manager UI can offer adoption. An orphan only qualifies
// if both the KV and WAV are present and the KV passes a cheap
// header-parse — partial / corrupt files are logged and skipped so
// the user only sees adoptable candidates.

struct OrphanedVoice: Identifiable, Equatable, Sendable {
    /// UUID extracted from the `<UUID>_kv.safetensors` filename.
    let id: String
    /// Always true (a precondition for being surfaced).
    let hasKV: Bool
    /// Always true (a precondition for being surfaced).
    let hasWAV: Bool
    /// Whether Fish DAC codes are present too. Influences post-adopt
    /// behavior (false → Fish backend will need to re-encode the WAV).
    let hasCodes: Bool
    /// Whether the LavaSR-enhanced WAV is present too.
    let hasEnhanced: Bool
}
