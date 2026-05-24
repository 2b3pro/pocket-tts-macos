//
//  LavaSRPipeline.swift
//  pocket-tts-macos
//
//  Top-level coordinator for the LavaSR voice-enhancement pipeline.
//  Stages mirror `LavaSR.model.LavaEnhance2.enhance(...)`:
//
//      audio[T] @ 16 kHz mono
//        → (optional) ULUNAS denoiser  [Commits 3-5]
//        → resample 16 → 48 kHz        [Commit 2]
//        → Vocos BWE                   [today; SR moves 44.1→48 in Commit 2]
//        → FastLRMerge refiner         [Commit 2]
//        → audio[T] @ 48 kHz mono
//
//  Phase 10 / Commit 1 — pipeline introduced as a thin wrapper around the
//  existing BWE-only path. Subsequent commits build out the missing
//  stages without changing this file's call shape. `VoiceEnhancer`
//  delegates to a single `LavaSRPipeline.enhance(_:)` call so the
//  observable shell stays focused on file IO + state.

@preconcurrency import AVFoundation
import Foundation
import MLX

// MARK: - LavaSRPipeline

/// Owns the LavaSR voice-enhancement model graph and exposes a single
/// `enhance(_ samples: [Float]) -> [Float]` entry point.
///
/// Today's behavior (BWE-only, 44.1 kHz mono) is unchanged from the
/// pre-Phase-10 implementation. Stages are added in subsequent commits;
/// `enhance(...)` keeps the same signature throughout.
@MainActor
final class LavaSRPipeline {

    // MARK: - Stored state

    /// Vocos BWE model. Loaded once during `load()`.
    private let bwe: LavaSREnhancerBWE

    /// Sample rate the pipeline currently operates at. Today this matches
    /// the BWE's configured rate (44.1 kHz). Commit 2 introduces a
    /// resample stage and the pipeline's output SR becomes 48 kHz while
    /// the input continues to come in at 16 kHz; Commit 6 wires the
    /// inputs to the production 16 kHz convention.
    var sampleRate: Int { LavaSREnhancerBWE.sampleRate }

    // MARK: - Init / load

    private init(bwe: LavaSREnhancerBWE) {
        self.bwe = bwe
    }

    /// Bootstrap the pipeline: load every required model from
    /// `ModelPaths` and prepare it for inference. Equivalent to the
    /// pre-Phase-10 `LavaSREnhancer.load()` call but lifted up a level
    /// so subsequent stages (denoiser, LR-merge) can join here without
    /// touching `VoiceEnhancer`.
    static func load() async throws -> LavaSRPipeline {
        let bwe = try await LavaSREnhancerBWE.load()
        return LavaSRPipeline(bwe: bwe)
    }

    // MARK: - Enhance

    /// Run the full enhancement pipeline on a mono Float32 buffer.
    /// `samples` is expected to be at the pipeline's input SR
    /// (`sampleRate` today; 16 kHz after Commit 6 once the denoiser
    /// stage is wired). Returns the enhanced buffer.
    func enhance(_ samples: [Float]) throws -> [Float] {
        let input = MLXArray(samples)
        let enhanced = try bwe.enhance(input)
        eval(enhanced)
        return enhanced.asArray(Float.self)
    }

    // MARK: - Teardown

    /// Free MLX-side memory after a one-shot enhancement. Voice enhancement
    /// is rare enough (per-import) that we don't keep ~280 MB of BWE
    /// weights resident between calls. After this returns the caller
    /// should drop its strong reference to the `LavaSRPipeline`.
    static func clearMemoryCache() {
        MLX.Memory.clearCache()
    }
}
