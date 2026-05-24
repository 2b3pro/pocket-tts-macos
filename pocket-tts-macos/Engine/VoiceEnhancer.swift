//
//  VoiceEnhancer.swift
//  pocket-tts-macos
//
//  @Observable SwiftUI-facing shell for the LavaSR voice-enhancement
//  pipeline. Owns lifecycle (idle → loading → ready → enhancing → idle)
//  and file IO; the actual audio math lives in `Engine/LavaSR/`:
//
//      LavaSRPipeline       — top-level coordinator
//      LavaSREnhancerBWE    — Vocos BWE model (the back half)
//      LavaSRISTFTHead      — custom ISTFT head matching Python Vocos
//
//  Phase 10 / Commit 1 — slimmed from 391 → ~120 lines by extracting the
//  MLX model classes into `Engine/LavaSR/`. Behavior is unchanged: today
//  the pipeline still runs BWE-only at 44.1 kHz. Commits 2+ build out
//  the missing denoise + LR-merge stages without touching this file.

@preconcurrency import AVFoundation
import Foundation
import Observation

// MARK: - VoiceEnhancer

@MainActor
@Observable
final class VoiceEnhancer {

    static let shared = VoiceEnhancer()

    enum Status: Equatable {
        case idle
        case loading
        case ready
        case enhancing
        case error(String)
    }

    private(set) var status: Status = .idle
    private var pipeline: LavaSRPipeline?

    // MARK: - Bootstrap

    func bootstrapIfNeeded() async {
        guard status == .idle else { return }
        status = .loading

        do {
            let pipeline = try await LavaSRPipeline.load()
            self.pipeline = pipeline
            status = .ready
            print("[VoiceEnhancer] pipeline loaded")
        } catch {
            status = .error(String(describing: error))
            print("[VoiceEnhancer] failed to load: \(error)")
        }
    }

    // MARK: - Enhance

    func enhance(inputURL: URL, outputURL: URL) async throws {
        guard let pipeline else {
            throw EnhancerError.notLoaded
        }

        status = .enhancing

        let samples = try Self.loadAudio(url: inputURL, targetRate: pipeline.sampleRate)
        print("[VoiceEnhancer] loaded \(samples.count) samples @ \(pipeline.sampleRate)Hz")

        let enhanced = try pipeline.enhance(samples)
        print("[VoiceEnhancer] enhanced → \(enhanced.count) samples")

        let normalized = Self.rmsNormalize(enhanced, targetDB: -16.0)

        try Self.writeWAV(samples: normalized, sampleRate: pipeline.sampleRate, url: outputURL)

        // Free the model memory immediately — voice enhancement is a
        // one-shot operation, no reason to keep ~280 MB of weights resident.
        self.pipeline = nil
        status = .idle
        LavaSRPipeline.clearMemoryCache()
        print("[VoiceEnhancer] saved to \(outputURL.lastPathComponent), model unloaded, cache cleared")
    }

    var isReady: Bool { status == .ready }

    // MARK: - Audio I/O

    private static func loadAudio(url: URL, targetRate: Int) throws -> [Float] {
        do {
            return try AudioPreconditioner.loadMonoFloat32(
                url: url,
                targetRate: targetRate,
                maxSeconds: 30
            )
        } catch {
            throw EnhancerError.audioReadFailed
        }
    }

    private static func writeWAV(samples: [Float], sampleRate: Int, url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw EnhancerError.audioWriteFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<samples.count { channel[i] = samples[i] }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func rmsNormalize(_ samples: [Float], targetDB: Float) -> [Float] {
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        let rms = sqrt(sumSq / Float(samples.count))
        guard rms > 1e-8 else { return samples }
        let targetRMS = pow(10, targetDB / 20.0)
        let gain = targetRMS / rms
        return samples.map { min(max($0 * gain, -1.0), 1.0) }
    }

    // MARK: - Errors

    enum EnhancerError: Error, CustomStringConvertible {
        case notLoaded
        case audioReadFailed
        case audioWriteFailed
        case modelLoadFailed(String)

        var description: String {
            switch self {
            case .notLoaded: return "Voice enhancer not loaded"
            case .audioReadFailed: return "Failed to read audio file"
            case .audioWriteFailed: return "Failed to write audio file"
            case .modelLoadFailed(let msg): return "Model load failed: \(msg)"
            }
        }
    }
}
