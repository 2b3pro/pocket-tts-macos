//
//  MultiSpeakerRevoicer.swift
//  pocket-tts-macos
//
//  Bridges Speaker Isolation → Voice Changer. Takes per-speaker
//  isolated tracks (silence-padded to full input length, from
//  SpeakerIsolator with preserveSilence=true) plus a voice
//  assignment per speaker, runs the Voice Changer pipeline on each
//  assigned speaker, then sums all per-speaker tracks into ONE
//  combined timeline-aligned buffer.
//
//  Pipeline per speaker:
//    voiceID == nil      → passthrough; speaker's isolated audio
//                          (original samples at original timestamps)
//                          is summed in as-is.
//    voiceID != nil      → write the speaker's isolated audio to a
//                          temp WAV → STT (the STT timestamps come
//                          back in absolute time from t=0 of the
//                          original because the padded buffer IS the
//                          original timeline) → TimelineAlignedRenderer
//                          with the chosen voiceID → result is a
//                          full-length [Float] with the new voice's
//                          synthesized speech at the original
//                          timestamps, silence elsewhere.
//
//  Combination: per-sample sum across all speakers' full-length
//  tracks. Soft-clipped to [-1, +1] post-sum. Since each speaker's
//  track is silent except at their utterance times (and in typical
//  conversational content speakers don't overlap), the sum lays
//  each speaker's audio onto the original timeline without
//  meaningful interference.

import Foundation

// MARK: - MultiSpeakerRevoicing

/// Protocol surface for the multi-speaker revoice + combine step.
/// Lifted out of the concrete `MultiSpeakerRevoicer` actor so the
/// Speaker Isolator VM can take `any MultiSpeakerRevoicing` for
/// dependency injection — production wires the real revoicer;
/// tests stub it to skip Voice Changer model loads entirely.
///
/// The associated types `Disposition` + `SpeakerAssignment` live on
/// the concrete `MultiSpeakerRevoicer` rather than this protocol,
/// because they're shared by every conformance — re-defining them
/// per backend would require shuffling call sites for no benefit.
protocol MultiSpeakerRevoicing: Sendable {
    func revoice(
        sampleRate: Int,
        totalDurationSec: Double,
        assignments: [MultiSpeakerRevoicer.SpeakerAssignment],
        engine: any TTSEngineProtocol,
        stt: STTProvider,
        onProgress: (@Sendable (String, Int, Int) -> Void)?
    ) async throws -> [Float]
}

// MARK: - MultiSpeakerRevoicer

actor MultiSpeakerRevoicer: MultiSpeakerRevoicing {

    enum RevoicerError: Error, CustomStringConvertible {
        case sttFailed(speakerID: String, Error)
        case writeTempFailed(speakerID: String, Error)

        var description: String {
            switch self {
            case .sttFailed(let id, let e):
                return "STT failed for \(id): \(e.localizedDescription)"
            case .writeTempFailed(let id, let e):
                return "Couldn't stage \(id)'s audio for re-voicing: \(e.localizedDescription)"
            }
        }
    }

    /// Disposition for a single row in the user's per-speaker
    /// mapping table. Maps onto `SpeakerAction` from the view-model
    /// layer; restated here so the engine layer doesn't import view
    /// model types.
    enum Disposition: Sendable {
        case useOriginal
        case discard
        case revoice(voiceID: String)
    }

    /// One row from the user's per-speaker voice-mapping table.
    struct SpeakerAssignment: Sendable {
        let speakerID: String
        /// The speaker's isolated PCM, silence-padded to the full
        /// input length (i.e. what SpeakerIsolator emits with
        /// preserveSilence=true).
        let isolatedSamples: [Float]
        let disposition: Disposition
    }

    /// Revoice + combine. Returns one master [Float] of exactly
    /// `Int(totalDurationSec * sampleRate)` samples.
    func revoice(
        sampleRate: Int,
        totalDurationSec: Double,
        assignments: [SpeakerAssignment],
        engine: any TTSEngineProtocol,
        stt: STTProvider,
        onProgress: (@Sendable (String, Int, Int) -> Void)? = nil
    ) async throws -> [Float] {
        let totalSamples = Int(totalDurationSec * Double(sampleRate))
        var combined = [Float](repeating: 0.0, count: totalSamples)

        for assignment in assignments {
            try Task.checkCancellation()

            let perSpeaker: [Float]
            switch assignment.disposition {
            case .discard:
                // User excluded this row from the final output.
                // Skip the sum entirely.
                print("[Revoicer] \(assignment.speakerID) discarded — excluded from output")
                continue
            case .useOriginal:
                perSpeaker = assignment.isolatedSamples
            case .revoice(let voiceID):
                perSpeaker = try await revoiceSingleSpeaker(
                    assignment: assignment,
                    voiceID: voiceID,
                    sampleRate: sampleRate,
                    totalDurationSec: totalDurationSec,
                    engine: engine,
                    stt: stt,
                    onProgress: onProgress
                )
            }

            // Sum into the combined master (clamped to the master's
            // length in case the per-speaker track is slightly off
            // from totalSamples due to int-rounding at the boundary).
            let copyCount = min(perSpeaker.count, totalSamples)
            for i in 0..<copyCount {
                combined[i] += perSpeaker[i]
            }
        }

        // Soft-clip to ±1.0 via tanh — see `softClip` docstring.
        Self.softClip(&combined)
        return combined
    }

    // MARK: - Soft clip

    /// Piecewise soft-clip applied to the combined revoiced master
    /// post-sum. Replaces the v1 brick-wall hard-clip — but does
    /// NOT color in-range samples (the failure mode of a global
    /// `tanh(x * 0.9)` curve).
    ///
    /// Curve:
    ///   * |x| ≤ knee (= 0.9)          → output = x (identity)
    ///   * |x| > knee                  → output = sign(x) * (
    ///         knee + (1 - knee) * tanh((|x| - knee) / (1 - knee)) )
    ///
    /// The identity branch guarantees ZERO coloration on typical-
    /// content samples (anywhere a hard-clip would also have been
    /// a no-op). Above the knee, the tanh-shaped folding curve
    /// brings any overload — including the Phase 7 case where the
    /// Background music stem is summed alongside revoiced speech
    /// — smoothly toward ±1 instead of producing the audible
    /// "pop" of a brick-wall limiter.
    ///
    /// Continuity check at the knee:
    ///   value: knee + 0 * tanh(0) = knee ✓
    ///   slope: d/dx[knee + (1-knee) * tanh((x-knee)/(1-knee))]
    ///        = (1-knee) * sech²(0) * 1/(1-knee)
    ///        = 1 (matches the identity branch's slope) ✓
    ///
    /// Asymptote: as |x| → ∞, tanh → 1, so output → knee + (1 -
    /// knee) = 1.0. Never crosses ±1 for finite input.
    ///
    /// Cheap — tanh is invoked only on the small subset of samples
    /// past the knee, plus a branch + abs per sample below. Total
    /// cost for a 30 min @ 24 kHz master with typical content
    /// (~99% of samples in-range) is dominated by the per-sample
    /// branch, ~50 ms.
    ///
    /// `nonisolated static` so tests can exercise the curve
    /// directly without spinning up the revoice pipeline.
    nonisolated static func softClip(_ samples: inout [Float]) {
        for i in 0..<samples.count {
            samples[i] = softClip(samples[i])
        }
    }

    /// Single-sample variant. Lets tests assert curve points
    /// (monotonicity, asymptote, in-range identity) without
    /// allocating arrays.
    nonisolated static func softClip(_ value: Float) -> Float {
        let knee: Float = 0.9
        let absX = abs(value)
        if absX <= knee {
            return value
        }
        let remaining: Float = 1.0 - knee   // headroom to the ±1 asymptote
        let excess = absX - knee
        let compressed = remaining * tanh(excess / remaining)
        return value < 0 ? -(knee + compressed) : (knee + compressed)
    }

    // MARK: - Per-speaker revoice

    private func revoiceSingleSpeaker(
        assignment: SpeakerAssignment,
        voiceID: String,
        sampleRate: Int,
        totalDurationSec: Double,
        engine: any TTSEngineProtocol,
        stt: STTProvider,
        onProgress: (@Sendable (String, Int, Int) -> Void)?
    ) async throws -> [Float] {
        // Stage the speaker's isolated audio as a temp WAV so it can
        // be fed to STT (which is URL-based for both WhisperKit and
        // SpeechFramework backends).
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voice-isolator-\(assignment.speakerID)-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            try WAVEncoder.write(samples: assignment.isolatedSamples, to: tempURL, sampleRate: sampleRate)
        } catch {
            throw RevoicerError.writeTempFailed(speakerID: assignment.speakerID, error)
        }

        let segments: [TranscribedSegment]
        do {
            segments = try await stt.transcribeSegments(tempURL)
        } catch {
            throw RevoicerError.sttFailed(speakerID: assignment.speakerID, error)
        }

        // Console log every transcribed segment so we can spot
        // Whisper artifacts that aren't in the strip whitelist yet
        // (TextNormalizer.stripWhisperArtifacts). When the user sees
        // a `[brand new tag]` slipping through to TTS, the line
        // showing the exact bracketed text is right here in the log.
        print("[Revoicer] STT for \(assignment.speakerID) produced \(segments.count) segments:")
        for seg in segments {
            print(String(format: "  [%.2f-%.2fs] \"%@\"", seg.startSec, seg.endSec, seg.text))
        }

        // Hand off to TimelineAlignedRenderer with the chosen voice.
        // The per-segment progress callback gets wrapped so the
        // speakerID label flows up to the UI ("Synthesizing
        // Speaker A: segment 3/12…").
        let speakerID = assignment.speakerID
        let synthesized = await TimelineAlignedRenderer.render(
            segments: segments,
            totalDurationSec: totalDurationSec,
            voiceID: voiceID,
            engine: engine,
            options: SynthesisOptions(),
            onProgress: { current, total in
                onProgress?(speakerID, current, total)
            }
        )

        // Match the synthesized track's loudness to the speaker's
        // original audio. Without this, the TTS voice plays at the
        // per-voice baked-in RMS target which is typically louder than
        // (and inconsistent across) the original speakers' levels.
        // Compute RMS over non-silence samples only on both sides so
        // the comparison is fair (silence-padded regions don't pull
        // the average down).
        let inputRMS = Self.rmsOfActiveSamples(assignment.isolatedSamples)
        let outputRMS = Self.rmsOfActiveSamples(synthesized)
        if inputRMS > 0, outputRMS > 0 {
            // Cap the gain to ±12 dB so a quiet original doesn't
            // amplify TTS noise floor into audibility, and a loud
            // original doesn't clip the output.
            let raw = inputRMS / outputRMS
            let clamped = max(0.25, min(raw, 4.0))
            print(String(format: "[Revoicer] %@ RMS normalize: input=%.4f output=%.4f gain=%.3fx (clamped from %.3fx)",
                         speakerID, inputRMS, outputRMS, clamped, raw))
            var scaled = synthesized
            for i in 0..<scaled.count {
                scaled[i] *= clamped
            }
            return scaled
        } else {
            print("[Revoicer] \(speakerID) RMS normalize skipped (inputRMS=\(inputRMS), outputRMS=\(outputRMS))")
            return synthesized
        }
    }

    // MARK: - RMS

    /// Mean-squared average of samples whose magnitude exceeds a
    /// silence threshold. Skipping near-zero samples gives a fair
    /// comparison between silence-padded isolated tracks and the
    /// TTS output (which has small non-zero values during pause
    /// regions due to fade ramps).
    nonisolated static func rmsOfActiveSamples(_ samples: [Float], silenceThreshold: Float = 0.001) -> Float {
        var sumSq: Double = 0
        var n: Int = 0
        for s in samples where abs(s) > silenceThreshold {
            sumSq += Double(s) * Double(s)
            n += 1
        }
        guard n > 0 else { return 0 }
        return Float(sqrt(sumSq / Double(n)))
    }
}
