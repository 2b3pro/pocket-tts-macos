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

actor MultiSpeakerRevoicer {

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

    /// One row from the user's per-speaker voice-mapping table.
    struct SpeakerAssignment: Sendable {
        let speakerID: String
        /// The speaker's isolated PCM, silence-padded to the full
        /// input length (i.e. what SpeakerIsolator emits with
        /// preserveSilence=true).
        let isolatedSamples: [Float]
        /// Voice to revoice with; nil = passthrough the isolated
        /// audio unchanged.
        let voiceID: String?
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
            if let voiceID = assignment.voiceID, !voiceID.isEmpty {
                perSpeaker = try await revoiceSingleSpeaker(
                    assignment: assignment,
                    voiceID: voiceID,
                    sampleRate: sampleRate,
                    totalDurationSec: totalDurationSec,
                    engine: engine,
                    stt: stt,
                    onProgress: onProgress
                )
            } else {
                perSpeaker = assignment.isolatedSamples
            }

            // Sum into the combined master (clamped to the master's
            // length in case the per-speaker track is slightly off
            // from totalSamples due to int-rounding at the boundary).
            let copyCount = min(perSpeaker.count, totalSamples)
            for i in 0..<copyCount {
                combined[i] += perSpeaker[i]
            }
        }

        // Soft-clip to [-1, +1]. With non-overlapping speaker timing
        // this almost never triggers; for accidental overlaps it
        // prevents hard digital clipping without scaling the whole
        // track down.
        for i in 0..<combined.count {
            if combined[i] > 1.0 { combined[i] = 1.0 }
            else if combined[i] < -1.0 { combined[i] = -1.0 }
        }

        return combined
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

        // Hand off to TimelineAlignedRenderer with the chosen voice.
        // The per-segment progress callback gets wrapped so the
        // speakerID label flows up to the UI ("Synthesizing
        // Speaker A: segment 3/12…").
        let speakerID = assignment.speakerID
        let samples = await TimelineAlignedRenderer.render(
            segments: segments,
            totalDurationSec: totalDurationSec,
            voiceID: voiceID,
            engine: engine,
            options: SynthesisOptions(),
            onProgress: { current, total in
                onProgress?(speakerID, current, total)
            }
        )
        return samples
    }
}
