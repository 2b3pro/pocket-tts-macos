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

    // MARK: - Background extraction

    /// Build a "background" PCM track containing everything in
    /// `inputSamples` that is NOT covered by any speaker's diarization
    /// segments. Captures non-speech content: music, SFX, ambient
    /// noise, etc. The result is silence-padded to the full input
    /// length (same shape as isolated speaker tracks) so the
    /// downstream combine step in `MultiSpeakerRevoicer` can sum it
    /// alongside speakers' tracks without special-casing.
    ///
    /// - Returns: A `(samples, ranges)` tuple, OR `nil` if there are
    ///   no qualifying non-speech ranges (e.g. continuous speech with
    ///   no gaps, or only inter-word breaths shorter than
    ///   `minBackgroundChunkSec`).
    static func extractBackground(
        inputSamples: [Float],
        sampleRate: Int,
        speakerSegments: [DiarizedSegment],
        totalDurationSec: Double,
        minBackgroundChunkSec: Double = 0.1
    ) -> (samples: [Float], ranges: [ClosedRange<Double>])? {
        guard totalDurationSec > 0, !inputSamples.isEmpty else { return nil }

        // 1. Merge overlapping speaker ranges into a non-overlapping
        //    "speech coverage" timeline.
        let speakerRanges = speakerSegments.map { $0.startSec...$0.endSec }
        let merged = mergeOverlapping(speakerRanges)

        // 2. Subtract merged speech ranges from [0, totalDurationSec]
        //    → complement = non-speech ranges.
        let complement = computeComplement(merged, totalDurationSec: totalDurationSec)

        // 3. Drop sub-threshold slivers (inter-word breaths, brief
        //    silence between speakers). 100 ms default avoids
        //    capturing artifacts that aren't meaningful background.
        let significant = complement.filter {
            ($0.upperBound - $0.lowerBound) >= minBackgroundChunkSec
        }
        guard !significant.isEmpty else { return nil }

        // 4. Build the silence-padded background track. Same pattern
        //    as `isolate(preserveSilence: true)`.
        var master = [Float](repeating: 0.0, count: inputSamples.count)
        for range in significant {
            let startIdx = clampedSampleIndex(range.lowerBound, sampleRate: sampleRate, totalSamples: inputSamples.count)
            let endIdx = clampedSampleIndex(range.upperBound, sampleRate: sampleRate, totalSamples: inputSamples.count)
            if startIdx >= endIdx { continue }
            for i in startIdx..<endIdx {
                master[i] = inputSamples[i]
            }
        }
        return (samples: master, ranges: significant)
    }

    /// Merge overlapping / touching time ranges into a non-overlapping
    /// sorted list. Used as the "speech coverage" prep before
    /// computing the complement.
    nonisolated static func mergeOverlapping(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = [sorted[0]]
        for next in sorted.dropFirst() {
            let last = merged.last!
            if next.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, next.upperBound)
            } else {
                merged.append(next)
            }
        }
        return merged
    }

    /// Subtract a sorted, non-overlapping list of ranges from
    /// `[0, totalDurationSec]`. Returns the gaps between (and around)
    /// the input ranges. Edge cases:
    ///   * Empty input → returns `[0...totalDurationSec]`.
    ///   * Input fully covers timeline → returns `[]`.
    ///   * Sub-zero or past-total ranges → clamped silently.
    nonisolated static func computeComplement(
        _ mergedRanges: [ClosedRange<Double>],
        totalDurationSec: Double
    ) -> [ClosedRange<Double>] {
        guard totalDurationSec > 0 else { return [] }
        guard !mergedRanges.isEmpty else { return [0...totalDurationSec] }

        var result: [ClosedRange<Double>] = []
        var cursor: Double = 0

        for range in mergedRanges {
            let start = max(0, range.lowerBound)
            let end = min(totalDurationSec, range.upperBound)
            if start > cursor {
                result.append(cursor...start)
            }
            cursor = max(cursor, end)
        }
        if cursor < totalDurationSec {
            result.append(cursor...totalDurationSec)
        }
        return result
    }
}
