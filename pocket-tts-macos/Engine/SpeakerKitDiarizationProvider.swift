//
//  SpeakerKitDiarizationProvider.swift
//  pocket-tts-macos
//
//  DiarizationProvider built on Argmax's SpeakerKit (pyannote-equivalent
//  Core ML, on-device). Mirrors `WhisperKitSTT`'s wrapping pattern —
//  lazy model load on first transcribe (here: first diarize), cached
//  in-actor for subsequent calls.
//
//  Storage layout (under the sandbox container):
//      Application Support/pocket-tts-macos/diarization-models/
//          ... whatever SpeakerKit's ModelDownloader lays out under
//              <downloadBase>/<repo>/<variant>/
//
//  No per-variant picker like the Whisper Manage Models sheet — the
//  pyannote bundle is a single set of models (segmenter + embedder +
//  PLDA cluster projector). Auto-downloaded on first use via
//  `ensureModelsReady(progress:)`.

import Foundation
import SpeakerKit

actor SpeakerKitDiarizationProvider: DiarizationProvider {

    enum ProviderError: Error, CustomStringConvertible {
        case modelLoadFailed(Error)
        case diarizationFailed(Error)
        case audioLoadFailed(Error)

        var description: String {
            switch self {
            case .modelLoadFailed(let e):
                return "Diarization model load failed: \(e.localizedDescription)"
            case .diarizationFailed(let e):
                return "Diarization failed: \(e.localizedDescription)"
            case .audioLoadFailed(let e):
                return "Audio load failed: \(e.localizedDescription)"
            }
        }
    }

    private let modelsDir: URL
    private let loader: AudioFileLoader
    private var diarizer: SpeakerKitDiarizer?
    private var modelsResolved: Bool = false

    init(loader: AudioFileLoader = AudioFileLoader()) {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("pocket-tts-macos", isDirectory: true)
        self.modelsDir = appDir.appendingPathComponent("diarization-models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        self.loader = loader
    }

    /// True if SpeakerKit's pyannote model bundle is already on disk at
    /// `modelsDir`. Used by the UI to decide whether to surface a
    /// "Downloading models…" status on the first run.
    func isModelDownloaded() -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path)) ?? []
        return !entries.isEmpty
    }

    /// Ensure the pyannote model bundle is downloaded and resolved.
    /// Idempotent — subsequent calls after the first successful resolve
    /// are no-ops. Progress reports during the actual download phase
    /// (in-cache resolves report zero progress and return immediately).
    func ensureModelsReady(progress: (@Sendable (Progress) -> Void)?) async throws {
        if modelsResolved, diarizer != nil { return }

        let kit = makeOrReuseDiarizer()
        do {
            try await kit.downloadModels(progressCallback: progress)
            modelsResolved = true
        } catch {
            throw ProviderError.modelLoadFailed(error)
        }
    }

    func diarize(_ audio: URL) async throws -> [DiarizedSegment] {
        // Make sure models are resolved before invoking diarize. If the
        // caller already called `ensureModelsReady` this is a no-op;
        // otherwise it downloads inline (without UI progress — caller
        // should prefer the explicit two-phase flow).
        try await ensureModelsReady(progress: nil)

        // SpeakerKit's pyannote was trained at 16 kHz. We feed it 16
        // kHz mono Float32 for the diarization pass even though the
        // rest of the app's pipeline is 24 kHz — the resulting
        // segments are time-domain (seconds), so the sample-rate
        // mismatch with isolation downstream doesn't matter.
        let loaded: AudioFileLoader.LoadedAudio
        do {
            loaded = try await loader.load(audio, targetSampleRate: 16_000)
        } catch {
            throw ProviderError.audioLoadFailed(error)
        }

        let kit = makeOrReuseDiarizer()

        let result: DiarizationResult
        do {
            result = try await kit.diarize(
                audioArray: loaded.samples,
                options: nil,
                progressCallback: nil
            )
        } catch {
            throw ProviderError.diarizationFailed(error)
        }

        // Map SpeakerKit `SpeakerSegment` -> project's `DiarizedSegment`.
        // We use the cluster-id-based label "SPEAKER_NN" so two segments
        // for the same speaker share an ID (the per-row UI can rename
        // the display string while keeping the routing key stable).
        let mapped: [DiarizedSegment] = result.segments.compactMap { seg in
            guard let cid = seg.speaker.speakerId else { return nil }
            return DiarizedSegment(
                speakerID: String(format: "SPEAKER_%02d", cid),
                startSec: Double(seg.startTime),
                endSec: Double(seg.endTime)
            )
        }
        return mapped.sorted { $0.startSec < $1.startSec }
    }

    // MARK: - Diarizer construction

    private func makeOrReuseDiarizer() -> SpeakerKitDiarizer {
        if let existing = diarizer { return existing }
        let config = PyannoteConfig(
            downloadBase: modelsDir.path,
            modelRepo: "argmaxinc/speakerkit-coreml",
            download: true,
            load: false   // models are loaded lazily inside diarize()
        )
        let new = SpeakerKitDiarizer.pyannote(config: config)
        diarizer = new
        return new
    }
}
