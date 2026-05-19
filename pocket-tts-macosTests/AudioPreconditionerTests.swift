//  AudioPreconditionerTests.swift
//  pocket-tts-macosTests
//
//  Regression tests for AudioPreconditioner. The bugs this guards against:
//   1. Output buffer sized from input frame count, truncating SRC output.
//   2. Input block returning destination buffer as input (memory aliasing).
//   3. Input block reporting .haveData forever with no .endOfStream.
//
//  The fixture is a synthetic sine wave written at 2ch / 24 kHz / Int16
//  (matching the broken ElevenLabs export format that prompted the fix).

@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import pocket_tts_macos

@Suite("AudioPreconditioner")
struct AudioPreconditionerTests {

    // MARK: - Helpers

    /// Writes a 440 Hz sine to a 2-channel WAV at `sampleRate` for `seconds`,
    /// returns the URL.
    private func writeStereoSineWAV(
        seconds: Double,
        sampleRate: Double = 24_000,
        frequency: Double = 440
    ) throws -> URL {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: true
        ) else {
            Issue.record("Cannot create input format")
            throw CocoaError(.fileWriteUnknown)
        }

        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else {
            Issue.record("Cannot allocate buffer")
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frameCount

        let ptr = buffer.int16ChannelData![0]  // interleaved → single pointer, 2 samples per frame
        let amp: Double = 0.5 * 32_767
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let s = Int16(amp * sin(2 * .pi * frequency * t))
            ptr[i * 2 + 0] = s   // L
            ptr[i * 2 + 1] = s   // R
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audioprecond_test_\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        try file.write(from: buffer)
        return url
    }

    // MARK: - loadMonoFloat32 — duration preservation across SRC

    @Test("loadMonoFloat32 preserves duration when resampling 24kHz stereo → 44.1kHz mono")
    func loadMonoFloat32_durationPreserved_2ch24k_to_1ch44k() throws {
        let url = try writeStereoSineWAV(seconds: 5.0, sampleRate: 24_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioPreconditioner.loadMonoFloat32(
            url: url,
            targetRate: 44_100,
            maxSeconds: nil
        )

        let expected = Int(5.0 * 44_100)
        let tolerance = Int(0.05 * 44_100)  // 50 ms SRC tail tolerance
        let delta = abs(samples.count - expected)
        #expect(
            delta < tolerance,
            "Expected ~\(expected) frames, got \(samples.count) (delta=\(delta), tol=\(tolerance))"
        )
    }

    @Test("loadMonoFloat32 preserves duration when resampling 24kHz stereo → 24kHz mono (downmix only)")
    func loadMonoFloat32_durationPreserved_2ch24k_to_1ch24k() throws {
        let url = try writeStereoSineWAV(seconds: 3.0, sampleRate: 24_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioPreconditioner.loadMonoFloat32(
            url: url,
            targetRate: 24_000,
            maxSeconds: nil
        )

        let expected = Int(3.0 * 24_000)
        let delta = abs(samples.count - expected)
        #expect(delta < 100, "Expected ~\(expected) frames, got \(samples.count)")
    }

    // MARK: - loadMonoFloat32 — content sanity

    @Test("loadMonoFloat32 produces non-silent, in-range samples")
    func loadMonoFloat32_contentIsValid() throws {
        let url = try writeStereoSineWAV(seconds: 2.0, sampleRate: 24_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioPreconditioner.loadMonoFloat32(
            url: url,
            targetRate: 44_100,
            maxSeconds: nil
        )

        // RMS of a 0.5-amplitude sine should be ~0.354. Allow wide tolerance
        // for SRC ripple.
        var sumSq: Double = 0
        for s in samples { sumSq += Double(s) * Double(s) }
        let rms = sqrt(sumSq / Double(samples.count))

        #expect(rms > 0.1, "RMS too low (\(rms)) — likely silent output")
        #expect(rms < 1.0, "RMS too high (\(rms)) — likely clipping")

        // All samples must be within [-1, 1] for Float32 PCM.
        let outOfRange = samples.filter { abs($0) > 1.0 }
        #expect(outOfRange.isEmpty, "Found \(outOfRange.count) out-of-range samples")
    }

    // MARK: - maxSeconds clamp

    @Test("maxSeconds caps output duration")
    func loadMonoFloat32_maxSecondsClamps() throws {
        let url = try writeStereoSineWAV(seconds: 10.0, sampleRate: 24_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioPreconditioner.loadMonoFloat32(
            url: url,
            targetRate: 44_100,
            maxSeconds: 2.0
        )

        let expected = Int(2.0 * 44_100)
        #expect(samples.count <= expected + 100, "maxSeconds not enforced")
    }

    // MARK: - convertToMonoWAV round-trip

    @Test("convertToMonoWAV produces a readable 44.1kHz mono WAV with preserved duration")
    func convertToMonoWAV_writesValidFile() throws {
        let src = try writeStereoSineWAV(seconds: 4.0, sampleRate: 24_000)
        defer { try? FileManager.default.removeItem(at: src) }

        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("audioprecond_out_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: dst) }

        try AudioPreconditioner.convertToMonoWAV(source: src, destination: dst, targetRate: 44_100)

        let outFile = try AVAudioFile(forReading: dst)
        #expect(outFile.processingFormat.channelCount == 1, "Output is not mono")
        #expect(Int(outFile.processingFormat.sampleRate) == 44_100, "Output is not 44.1kHz")

        let expected = Int(4.0 * 44_100)
        let actual = Int(outFile.length)
        let delta = abs(actual - expected)
        #expect(delta < Int(0.05 * 44_100), "Duration drift: expected \(expected), got \(actual)")
    }

    // MARK: - needsConversion

    @Test("needsConversion detects stereo 24kHz as needing conversion")
    func needsConversion_detectsStereo24k() throws {
        let url = try writeStereoSineWAV(seconds: 1.0, sampleRate: 24_000)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(AudioPreconditioner.needsConversion(url: url, targetRate: 44_100) == true)
    }

    @Test("needsConversion returns false for already-correct mono 44.1kHz")
    func needsConversion_passesMono44k() throws {
        // Build a mono 44.1kHz file directly so we don't depend on the
        // converter under test.
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audioprecond_mono_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        try file.write(from: buffer)

        #expect(AudioPreconditioner.needsConversion(url: url, targetRate: 44_100) == false)
    }
}
