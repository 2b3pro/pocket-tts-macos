//
//  SpeakerIsolator.swift
//  pocket-tts-macos
//
//  Pure function that takes mono PCM samples + diarization segments
//  and produces one isolated PCM buffer per speaker. Direct port of
//  the Python pyannote app's preserve-silence mechanism (see
//  `pocket-tts-macos-releases/pyannote/speaker_separation_gui.py:
//  826-861`).
//
//  Two modes:
//    * `preserveSilence == true` (default for video-overlay use):
//        each speaker's output is the same length as the input.
//        Their isolated buffer carries the original samples at each
//        of their segment's timestamps; silence (zero samples)
//        elsewhere. Output length = input length, per speaker.
//        Python parity: lines 832-845 (`AudioSegment.silent(...).
//        overlay(seg, position=start_ms)`).
//
//    * `preserveSilence == false` (concatenate mode):
//        each speaker's output is the back-to-back concatenation
//        of just their spoken slices, with no silence in between.
//        Output length per speaker = sum of their segment durations
//        × sampleRate. Python parity: lines 846-848 (`AudioSegment.
//        empty(); combined_audio += segment`).
//
//  Pure logic — no Foundation I/O, no actor isolation. Easily testable.

import Foundation

nonisolated enum SpeakerIsolator {

    /// Build per-speaker isolated PCM buffers.
    ///
    /// - Parameters:
    ///   - inputSamples: mono Float32 PCM at `sampleRate`.
    ///   - sampleRate: samples-per-second of `inputSamples`. Used to
    ///     map segment seconds → sample indices.
    ///   - segments: chronologically sorted internally.
    ///   - preserveSilence: see top-of-file mode descriptions.
    ///
    /// - Returns: per-speaker `(speakerID, samples)` tuples, sorted
    ///   by each speaker's first-utterance start time so the first
    ///   speaker to talk in the original audio is index 0. Empty if
    ///   `segments` is empty.
    static func isolate(
        inputSamples: [Float],
        sampleRate: Int,
        segments: [DiarizedSegment],
        preserveSilence: Bool
    ) -> [(speakerID: String, samples: [Float])] {
        guard !segments.isEmpty else { return [] }

        let sorted = segments.sorted { $0.startSec < $1.startSec }

        // Group segments by speaker, preserving first-appearance order
        // so the returned tuples are in "who-spoke-first" sequence.
        var orderedSpeakerIDs: [String] = []
        var bySpeaker: [String: [DiarizedSegment]] = [:]
        for seg in sorted {
            if bySpeaker[seg.speakerID] == nil {
                orderedSpeakerIDs.append(seg.speakerID)
                bySpeaker[seg.speakerID] = []
            }
            bySpeaker[seg.speakerID]!.append(seg)
        }

        var result: [(speakerID: String, samples: [Float])] = []
        result.reserveCapacity(orderedSpeakerIDs.count)

        let totalSamples = inputSamples.count

        for speakerID in orderedSpeakerIDs {
            let speakerSegs = bySpeaker[speakerID] ?? []

            if preserveSilence {
                var master = [Float](repeating: 0.0, count: totalSamples)
                for seg in speakerSegs {
                    let startIdx = clampedSampleIndex(seg.startSec, sampleRate: sampleRate, totalSamples: totalSamples)
                    let endIdx = clampedSampleIndex(seg.endSec, sampleRate: sampleRate, totalSamples: totalSamples)
                    if startIdx >= endIdx { continue }
                    for i in startIdx..<endIdx {
                        master[i] = inputSamples[i]
                    }
                }
                result.append((speakerID: speakerID, samples: master))
            } else {
                var concatenated: [Float] = []
                concatenated.reserveCapacity(Int(speakerSegs.reduce(0) { $0 + $1.durationSec } * Double(sampleRate)))
                for seg in speakerSegs {
                    let startIdx = clampedSampleIndex(seg.startSec, sampleRate: sampleRate, totalSamples: totalSamples)
                    let endIdx = clampedSampleIndex(seg.endSec, sampleRate: sampleRate, totalSamples: totalSamples)
                    if startIdx >= endIdx { continue }
                    concatenated.append(contentsOf: inputSamples[startIdx..<endIdx])
                }
                result.append((speakerID: speakerID, samples: concatenated))
            }
        }

        return result
    }

    /// Convert a time-in-seconds boundary to a sample index, clamped
    /// to `[0, totalSamples]`. Out-of-range segments (from a stale
    /// diarization run or rounding artifacts at the end of the file)
    /// get clipped instead of crashing.
    private static func clampedSampleIndex(
        _ seconds: Double,
        sampleRate: Int,
        totalSamples: Int
    ) -> Int {
        let raw = Int((seconds * Double(sampleRate)).rounded())
        return max(0, min(totalSamples, raw))
    }
}
