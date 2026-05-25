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

    /// Frequency-domain crossover refiner — see LavaSRFastLRMerge.
    /// Production parameters match `LavaEnhance.load_audio()` in the
    /// upstream Python:  cutoff = 8000 Hz, transition = 1024 bins.
    private let lrMerge: LavaSRFastLRMerge

    /// Sample rate the pipeline operates at end-to-end (input AND
    /// output). Matches `LavaSREnhancerBWE.sampleRate` so the BWE
    /// receives audio at its trained operating point.
    ///
    /// Phase 10 / Commit 6 introduces a separate `inputSampleRate` of
    /// 16 kHz (denoiser's domain) with an internal 16 → 48 kHz resample
    /// before the BWE stage. Today's path expects callers to provide
    /// audio already at this SR.
    var sampleRate: Int { LavaSREnhancerBWE.sampleRate }

    // MARK: - Init / load

    private init(bwe: LavaSREnhancerBWE, lrMerge: LavaSRFastLRMerge) {
        self.bwe = bwe
        self.lrMerge = lrMerge
    }

    /// Bootstrap the pipeline: load every required model from
    /// `ModelPaths` and prepare it for inference. Equivalent to the
    /// pre-Phase-10 `LavaSREnhancer.load()` call but lifted up a level
    /// so subsequent stages (denoiser, LR-merge) can join here without
    /// touching `VoiceEnhancer`.
    static func load() async throws -> LavaSRPipeline {
        let bwe = try await LavaSREnhancerBWE.load()
        let lr = LavaSRFastLRMerge(
            sampleRate: LavaSREnhancerBWE.sampleRate,
            cutoff: 8_000,
            transitionBins: 1024
        )
        return LavaSRPipeline(bwe: bwe, lrMerge: lr)
    }

    // MARK: - Enhance

    /// Run the full enhancement pipeline on a mono Float32 buffer.
    /// `samples` is expected to be at `sampleRate` (48 kHz). Returns
    /// the enhanced buffer at the same SR.
    ///
    /// Stages (matches `LavaSR.enhancer.LavaBWE.infer` in the upstream
    /// Python):
    ///
    ///   1. BWE forward: mel → ConvNeXt → ISTFT head.
    ///   2. Length align: truncate both BWE output and the original
    ///      input to whichever is shorter (matches the Python
    ///      `pred_audio[:, :wav.shape[1]]` / `wav[:, :pred_audio.shape[1]]`
    ///      truncation inside `LavaBWE.infer`).
    ///   3. FastLRMerge: low freqs from input + high freqs from BWE.
    ///      Smoothstep transition centered at 8 kHz.
    func enhance(_ samples: [Float]) throws -> [Float] {
        let input = MLXArray(samples)

        // Stage 1 — BWE.
        let bweOutput = try bwe.enhance(input)
        eval(bweOutput)

        // Stage 2 — length align.
        let inputLen = input.shape[0]
        let bweLen = bweOutput.shape[0]
        let n = min(inputLen, bweLen)
        let a = bweLen == n ? bweOutput : bweOutput[0..<n]
        let b = inputLen == n ? input : input[0..<n]

        // Stage 3 — LR-merge.
        let merged = lrMerge.merge(a: a, b: b)
        eval(merged)
        return merged.asArray(Float.self)
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
