//
//  SpeakerIsolatorViewModel.swift
//  pocket-tts-macos
//
//  State machine + orchestrator for the Speaker Isolator sheet.
//  Drives the full pipeline:
//
//      input audio/video URL
//        ↓
//      ensureModelsReady (one-time first run)
//        ↓
//      AudioFileLoader.load(url, 24kHz)   ← also captures videoAsset
//        ↓                                   for video inputs
//      DiarizationProvider.diarize(url)
//        ↓
//      SpeakerIsolator.isolate(...)       ← per-speaker buffers
//        ↓
//      [SpeakerTrack] published for the UI
//        ↓
//   ┌──┴──────────────────────────────────────────────────┐
//   │ user picks one of two branches:                     │
//   │ 1. exportIsolated(...)     — per-row or batch WAV   │
//   │ 2. runChangeVoicesPipeline(...) — MultiSpeakerRevo. │
//   │      ↓                                              │
//   │   if videoAsset present → optional VideoMuxer.mux   │
//   └─────────────────────────────────────────────────────┘
//
//  The Stop button calls `cancel()`, which propagates via Task.cancel().

import AppKit
import AVFoundation
import Foundation
import Observation

// MARK: - SpeakerAction
//
// Three mutually-exclusive per-row dispositions the user can pick
// for any detected speaker (or for the background-audio pseudo-row):
//
//   * .useOriginal     — passthrough the speaker's isolated audio
//                        into the final combined output.
//   * .discard         — exclude this speaker from the final output.
//                        Useful for silencing a specific speaker in
//                        the re-voiced video while keeping the others.
//   * .revoice(voiceID)— send this speaker's audio through the
//                        Voice Changer pipeline and substitute the
//                        chosen TTS voice into the timeline-aligned
//                        slot. Not valid for the background row
//                        (you can't re-voice music) — the picker
//                        hides this case there.
//
// Hashable so it can serve as the SwiftUI Picker selection tag.

enum SpeakerAction: Hashable, Sendable {
    case useOriginal
    case discard
    case revoice(voiceID: String)
}

/// Sentinel speaker-ID used for the background-audio pseudo-row.
/// Stable string so the UI and the revoicer can both identify it
/// (the row's voice picker hides revoice options when it sees this
/// ID; the export-filename default also differs).
let backgroundSpeakerID = "_BACKGROUND_"

@MainActor
@Observable
final class SpeakerIsolatorViewModel {

    // MARK: - Status

    enum Status: Equatable, Sendable {
        case idle
        case downloadingModels(progress: Double?)
        case loadingAudio
        case diarizing
        case isolating
        case revoicing(speakerID: String, current: Int, total: Int)
        case muxingVideo
        case done
        case error(String)

        var isWorking: Bool {
            switch self {
            case .idle, .done, .error: return false
            default: return true
            }
        }

        var isDone: Bool {
            if case .done = self { return true }
            return false
        }
    }

    // MARK: - Speaker row data

    struct SpeakerTrack: Identifiable, Equatable, Sendable {
        let id: String                // SpeakerID (e.g. "SPEAKER_00") or backgroundSpeakerID
        var displayName: String       // user-editable; used in export filenames
        let segments: Int
        let durationSec: Double
        let isolatedSamples: [Float]
        /// Time ranges (in seconds, original timeline) of this
        /// speaker's individual utterances (or non-speech regions
        /// for the background row). Drawn as an activity bar in the
        /// row's MiniAudioPlayer so the user can see where on the
        /// timeline this track was active.
        let segmentRanges: [ClosedRange<Double>]
        /// User's per-row disposition. Default `.useOriginal`.
        var action: SpeakerAction = .useOriginal

        /// True for the synthetic background-audio row produced from
        /// the complement of all speaker ranges (music / SFX /
        /// ambient). UI hides voice options in the picker; revoicer
        /// rejects `.revoice` for it.
        var isBackground: Bool { id == backgroundSpeakerID }

        static func == (lhs: SpeakerTrack, rhs: SpeakerTrack) -> Bool {
            // Compare identity + UI-mutable fields. Skip
            // isolatedSamples + segmentRanges (large + immutable;
            // identity is sufficient).
            lhs.id == rhs.id
                && lhs.displayName == rhs.displayName
                && lhs.segments == rhs.segments
                && lhs.durationSec == rhs.durationSec
                && lhs.action == rhs.action
        }
    }

    // MARK: - Inputs

    var inputAudioURL: URL?
    var inputDurationSec: Double?
    /// When true, isolated-WAV exports carry the silence-padded
    /// full-length tracks. When false, each export concatenates only
    /// that speaker's speech (no silences). Internally forced to ON
    /// for the Change-Voices pipeline regardless of this toggle —
    /// the multi-speaker sum requires timeline-aligned tracks.
    var preserveSilenceForIsolatedExport: Bool = true
    /// Which row's inline mini-player is currently expanded. Only one
    /// at a time. Set in tandem with `playingSpeakerID` when the user
    /// hits a row's play button — clicking another row collapses the
    /// previous and expands the new one.
    var expandedSpeakerID: String? = nil

    /// Which row is currently playing audio. `nil` = nothing is
    /// playing. Bound bidirectionally to each row's MiniAudioPlayer:
    /// the row's button toggles it; MiniAudioPlayer writes back `nil`
    /// when playback reaches the end naturally. Independent from
    /// `expandedSpeakerID` so an expanded row can be paused without
    /// collapsing the player (lets the user scrub mid-pause).
    var playingSpeakerID: String? = nil

    /// User-supplied tuning for the diarization step. Bound to the
    /// "Diarization Settings" disclosure section in the sheet.
    /// Default values preserve the SpeakerKit out-of-the-box behavior;
    /// the user only sees a difference if they touch a knob.
    /// Re-applied on each `convertAndIsolate()` so the user can tweak
    /// after a bad first pass, hit "Start Over", and try again.
    var diarizationSettings: DiarizationSettings = DiarizationSettings()

    // MARK: - Observable state

    private(set) var status: Status = .idle
    var speakers: [SpeakerTrack] = []
    /// Non-nil for video inputs. Held for the VideoMuxer step.
    private(set) var videoAsset: AVURLAsset?

    // MARK: - Deps

    private let engine: any TTSEngineProtocol
    private let loader: AudioFileLoader
    private let diarizationProvider: SpeakerKitDiarizationProvider
    private let revoicer: MultiSpeakerRevoicer
    private let muxer: VideoMuxer
    private var inflightTask: Task<Void, Never>?

    /// Cached STT instance for the Change Voices pipeline. Lazily
    /// built on the first run, then reused across subsequent
    /// "Change Voices…" clicks as long as the user hasn't switched
    /// transcription models in the meantime. Avoids re-paying the
    /// WhisperKit model-load cost (1-2 s for base, 5-10 s for
    /// large-v3) when the user tweaks per-speaker voice assignments
    /// and re-runs.
    ///
    /// Eviction policy: when `cachedSTTKey` differs from the key
    /// passed to `runChangeVoicesPipeline`, the cached instance is
    /// dropped and a new one is built. The `clear()` / `clearResults()`
    /// methods deliberately do NOT evict — the model is orthogonal to
    /// the input file, and tossing it across input swaps would be
    /// gratuitous.
    private var cachedSTT: STTProvider?
    private var cachedSTTKey: String?

    // MARK: - Init

    init(engine: any TTSEngineProtocol) {
        self.engine = engine
        self.loader = AudioFileLoader()
        self.diarizationProvider = SpeakerKitDiarizationProvider(loader: self.loader)
        self.revoicer = MultiSpeakerRevoicer()
        self.muxer = VideoMuxer()
    }

    // MARK: - Input loading

    func setInputAudio(_ url: URL) {
        inputAudioURL = url
        inputDurationSec = nil
        Task { @MainActor in
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                let secs = CMTimeGetSeconds(duration)
                if secs.isFinite, secs > 0 {
                    self.inputDurationSec = secs
                }
            } catch {
                FileHandle.standardError.write(Data("[SpeakerIsolator] duration load failed: \(error)\n".utf8))
            }
        }
    }

    /// Full wipe — drops the input file in addition to the results.
    /// Used by the X button on the input row (when allowed) and by
    /// dismiss. After this, the user has to drop a new file before
    /// "Isolate Speakers" can re-enable.
    func clear() {
        cancel()
        inputAudioURL = nil
        inputDurationSec = nil
        speakers = []
        videoAsset = nil
        expandedSpeakerID = nil
        playingSpeakerID = nil
        status = .idle
    }

    /// Results-only reset — keeps the input file loaded so the user
    /// can tweak Diarization Settings and re-run on the same file
    /// without re-dropping. Backs the "Start Over" button in the
    /// results section header.
    func clearResults() {
        cancel()
        speakers = []
        videoAsset = nil
        expandedSpeakerID = nil
        playingSpeakerID = nil
        status = .idle
    }

    // MARK: - Isolate

    var canConvertAndIsolate: Bool {
        !status.isWorking && inputAudioURL != nil
    }

    func convertAndIsolate() {
        // Belt-and-suspenders re-entry guard. The UI hides the
        // button while `status.isWorking`, but defending in the VM
        // means a future keyboard shortcut, programmatic trigger,
        // or test path can't orphan `inflightTask` by silently
        // overwriting it mid-run.
        guard !status.isWorking else { return }
        guard canConvertAndIsolate, let inputURL = inputAudioURL else { return }
        let preserveSilence = self.preserveSilenceForIsolatedExport
        let settings = self.diarizationSettings
        let loader = self.loader
        let provider = self.diarizationProvider

        inflightTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // 1. Ensure SpeakerKit models are downloaded.
                let alreadyDownloaded = await provider.isModelDownloaded()
                if !alreadyDownloaded {
                    self.status = .downloadingModels(progress: nil)
                    try await provider.ensureModelsReady(progress: { [weak self] progress in
                        Task { @MainActor in
                            self?.status = .downloadingModels(progress: progress.fractionCompleted)
                        }
                    })
                }
                try Task.checkCancellation()

                // 2. Load audio at 24 kHz (the rate isolation slices
                //    are copied at). Pull the videoAsset for later
                //    re-mux if the input is a video.
                self.status = .loadingAudio
                let loaded = try await loader.load(inputURL, targetSampleRate: 24_000)
                try Task.checkCancellation()
                self.videoAsset = loaded.videoAsset
                if self.inputDurationSec == nil {
                    self.inputDurationSec = loaded.durationSec
                }

                // 3. Diarize via SpeakerKit. The provider feeds the
                //    diarizer 16 kHz internally; returned segments are
                //    seconds so they line up against our 24 kHz samples.
                //    User-supplied tuning (number of speakers, cluster
                //    sensitivity) flows in via `settings`; default
                //    values preserve the original out-of-the-box
                //    behavior.
                self.status = .diarizing
                let segments = try await provider.diarize(inputURL, settings: settings)
                try Task.checkCancellation()

                guard !segments.isEmpty else {
                    self.status = .error("No speakers detected in the input audio.")
                    return
                }

                // 4. Isolate. Always run with preserveSilence=true so
                //    the buffers are full-length-aligned — the
                //    Change-Voices pipeline requires that, and the
                //    isolated-export path uses the toggle separately.
                self.status = .isolating
                let isolated = SpeakerIsolator.isolate(
                    inputSamples: loaded.samples,
                    sampleRate: 24_000,
                    segments: segments,
                    preserveSilence: true  // see comment above
                )

                // Build SpeakerTrack rows for the UI. Pre-populate
                // displayName as "Speaker N" (1-indexed) — friendlier
                // than "SPEAKER_00" but the diarizer's stable label
                // stays as the routing ID. Capture per-speaker
                // segment ranges so the row's MiniAudioPlayer can
                // render its activity bar.
                var rows: [SpeakerTrack] = []
                for (idx, item) in isolated.enumerated() {
                    let mySegs = segments.filter { $0.speakerID == item.speakerID }
                    let dur = mySegs.reduce(0.0) { $0 + $1.durationSec }
                    let ranges = mySegs.map { $0.startSec...$0.endSec }
                    rows.append(SpeakerTrack(
                        id: item.speakerID,
                        displayName: "Speaker \(idx + 1)",
                        segments: mySegs.count,
                        durationSec: dur,
                        isolatedSamples: item.samples,
                        segmentRanges: ranges,
                        action: .useOriginal
                    ))
                }

                // Background-audio pseudo-row: complement of all
                // speaker ranges → music / SFX / ambient noise. Only
                // appended if meaningful non-speech content exists
                // (extractBackground returns nil for continuous
                // speech with no significant gaps).
                if let bg = SpeakerIsolator.extractBackground(
                    inputSamples: loaded.samples,
                    sampleRate: 24_000,
                    speakerSegments: segments,
                    totalDurationSec: loaded.durationSec
                ) {
                    let bgDur = bg.ranges.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
                    rows.append(SpeakerTrack(
                        id: backgroundSpeakerID,
                        displayName: "Background (music, SFX, ambient)",
                        segments: bg.ranges.count,
                        durationSec: bgDur,
                        isolatedSamples: bg.samples,
                        segmentRanges: bg.ranges,
                        action: .useOriginal
                    ))
                }

                self.speakers = rows
                self.status = .done
            } catch is CancellationError {
                self.status = .idle
            } catch {
                self.status = .error(String(describing: error))
            }
        }
    }

    // MARK: - Export isolated (per-row or batch)

    /// Per-row Save panel for a single speaker. Caller supplies the
    /// speaker's row index (since the UI passes it from the row's
    /// action closure). Honors `preserveSilenceForIsolatedExport`.
    func exportSingleSpeaker(at index: Int) {
        guard index >= 0, index < speakers.count else { return }
        let track = speakers[index]
        let panel = NSSavePanel()
        panel.title = "Export Isolated Speaker"
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(track.displayName).wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeTrack(track, to: url)
    }

    /// Batch export to a chosen folder. Each speaker writes
    /// `<displayName>.wav`.
    func exportAllIsolated() {
        let panel = NSOpenPanel()
        panel.title = "Choose folder to export isolated speakers"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        for track in speakers {
            let url = folder.appendingPathComponent("\(track.displayName).wav")
            writeTrack(track, to: url)
        }
    }

    /// Honors `preserveSilenceForIsolatedExport`. When false, writes a
    /// concatenated WAV (no silence) by re-running SpeakerIsolator with
    /// the speaker's pre-recorded segments — we cache the silence-
    /// padded buffer; concat mode needs the segment list, which we
    /// don't retain across the convert step. So for the concat case,
    /// we re-derive concat by collapsing the silence-padded buffer:
    /// scanning for non-zero ranges. Pragmatic and avoids re-running
    /// diarization.
    private func writeTrack(_ track: SpeakerTrack, to url: URL) {
        do {
            let samples: [Float]
            if preserveSilenceForIsolatedExport {
                samples = track.isolatedSamples
            } else {
                samples = Self.stripSilence(track.isolatedSamples)
            }
            try WAVEncoder.write(samples: samples, to: url, sampleRate: 24_000)
        } catch {
            FileHandle.standardError.write(Data("[SpeakerIsolator] export failed for \(track.displayName): \(error)\n".utf8))
        }
    }

    /// Collapse a silence-padded buffer to its non-zero ranges only,
    /// concatenated back-to-back. Mirrors the
    /// `SpeakerIsolator.isolate(preserveSilence: false)` output without
    /// re-running diarization. Acceptable because the silence regions
    /// in an isolated track are EXACT zeros (we copied input samples
    /// at speaker times into a zero-filled buffer).
    private static func stripSilence(_ samples: [Float]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(samples.count / 4)  // rough guess
        for s in samples where s != 0 {
            out.append(s)
        }
        return out
    }

    // MARK: - Change Voices pipeline

    /// True when at least one row has been switched off the default
    /// `.useOriginal` action — that is, the user has picked either a
    /// voice OR Discard for at least one speaker / background. Drives
    /// the "Change Voices…" button's enabled state.
    var hasAnyActionableChange: Bool {
        speakers.contains { $0.action != .useOriginal }
    }

    /// Run the multi-speaker revoice pipeline and offer the user
    /// either a WAV save (audio input) or — for video inputs — the
    /// re-encode-with-video prompt followed by a .mp4 save.
    ///
    /// - Parameters:
    ///   - stt: The STT provider to use IF the cache has nothing for
    ///     `cacheKey` (or holds a different key). The caller is free
    ///     to construct this eagerly — STT initialization is cheap
    ///     (the expensive model load is deferred to first transcribe).
    ///   - cacheKey: Stable identifier for the supplied STT (e.g.
    ///     `"whisper:base.en"`, `"apple-speech"`). Subsequent
    ///     pipeline invocations with the same `cacheKey` reuse the
    ///     cached STT instance — and therefore its already-loaded
    ///     model — instead of paying the load cost again.
    func runChangeVoicesPipeline(stt: STTProvider, cacheKey: String) {
        // Belt-and-suspenders re-entry guard. See the comment on
        // `convertAndIsolate()` for the rationale.
        guard !status.isWorking else { return }
        guard hasAnyActionableChange else { return }
        guard let totalDuration = inputDurationSec, totalDuration > 0 else { return }

        // STT cache resolution. If the key matches the cached
        // instance, reuse it (model stays loaded). Otherwise install
        // the freshly-supplied one as the new cached value.
        let effectiveSTT: STTProvider
        if let cached = cachedSTT, cachedSTTKey == cacheKey {
            effectiveSTT = cached
        } else {
            cachedSTT = stt
            cachedSTTKey = cacheKey
            effectiveSTT = stt
        }

        let assignments: [MultiSpeakerRevoicer.SpeakerAssignment] = speakers.map { track in
            let disposition: MultiSpeakerRevoicer.Disposition
            switch track.action {
            case .useOriginal:
                disposition = .useOriginal
            case .discard:
                disposition = .discard
            case .revoice(let voiceID):
                disposition = .revoice(voiceID: voiceID)
            }
            return MultiSpeakerRevoicer.SpeakerAssignment(
                speakerID: track.id,
                isolatedSamples: track.isolatedSamples,
                disposition: disposition
            )
        }
        let engine = self.engine
        let revoicer = self.revoicer
        let muxer = self.muxer
        let videoAssetSnapshot = self.videoAsset

        inflightTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let combined: [Float] = try await revoicer.revoice(
                    sampleRate: 24_000,
                    totalDurationSec: totalDuration,
                    assignments: assignments,
                    engine: engine,
                    stt: effectiveSTT,
                    onProgress: { [weak self] speakerID, current, total in
                        Task { @MainActor in
                            self?.status = .revoicing(
                                speakerID: speakerID, current: current, total: total)
                        }
                    }
                )

                try Task.checkCancellation()

                // Save flow depends on whether the input was a video.
                if let videoAsset = videoAssetSnapshot {
                    // Video input → ask the user whether to re-mux into
                    // the original video or save audio only.
                    let alert = NSAlert()
                    alert.messageText = "Re-encode with original video?"
                    alert.informativeText = "The combined re-voiced audio can replace the audio track of the original video and export as a new .mp4. Choose No to save only the audio (.wav)."
                    alert.addButton(withTitle: "Yes — Save as .mp4")
                    alert.addButton(withTitle: "No — Save audio (.wav)")
                    alert.addButton(withTitle: "Cancel")
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        let panel = NSSavePanel()
                        panel.title = "Export re-voiced video"
                        panel.allowedContentTypes = [.mpeg4Movie]
                        // Default to the input's directory + a
                        // `<basename>_re-voiced.mp4` filename so the
                        // panel never lands on the input file's own
                        // name — which previously made it too easy
                        // to accidentally overwrite the source.
                        Self.configureExportPanel(
                            panel,
                            inputURL: self.inputAudioURL,
                            suffix: "re-voiced",
                            ext: "mp4",
                            fallbackFilename: "re-voiced-output.mp4"
                        )
                        guard panel.runModal() == .OK, let outURL = panel.url else {
                            self.status = .done
                            return
                        }
                        // Hard guard: never write the muxed output
                        // over the input file. Even with the better
                        // default filename above, the user can still
                        // navigate the save panel anywhere. If they
                        // pick the input file's exact path, bail
                        // with a clear error instead of clobbering.
                        if let err = Self.refuseOverwriteError(outURL: outURL, inputURL: self.inputAudioURL) {
                            self.status = .error(err)
                            return
                        }
                        self.status = .muxingVideo
                        try await muxer.mux(
                            audioSamples: combined,
                            sampleRate: 24_000,
                            videoAsset: videoAsset,
                            outputURL: outURL
                        )
                        self.status = .done
                    } else if response == .alertSecondButtonReturn {
                        saveCombinedAudio(combined)
                    } else {
                        self.status = .done
                    }
                } else {
                    // Audio input → directly to WAV save panel.
                    saveCombinedAudio(combined)
                }
            } catch is CancellationError {
                self.status = .idle
            } catch {
                self.status = .error(String(describing: error))
            }
        }
    }

    private func saveCombinedAudio(_ samples: [Float]) {
        let panel = NSSavePanel()
        panel.title = "Export re-voiced audio"
        panel.allowedContentTypes = [.wav]
        Self.configureExportPanel(
            panel,
            inputURL: self.inputAudioURL,
            suffix: "re-voiced",
            ext: "wav",
            fallbackFilename: "re-voiced-output.wav"
        )
        guard panel.runModal() == .OK, let outURL = panel.url else {
            status = .done
            return
        }
        if let err = Self.refuseOverwriteError(outURL: outURL, inputURL: self.inputAudioURL) {
            status = .error(err)
            return
        }
        do {
            try WAVEncoder.write(samples: samples, to: outURL, sampleRate: 24_000)
            status = .done
        } catch {
            status = .error("Failed to write \(outURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Save-panel helpers

    /// Configure an `NSSavePanel` to default into the input file's
    /// directory with a `<basename>_<suffix>.<ext>` filename. Prevents
    /// the "I accidentally overwrote my input" failure mode where the
    /// panel's blank default landed wherever the user last saved a
    /// file (and they navigated to the input's folder + kept hitting
    /// Save without noticing the filename collision).
    ///
    /// `static` so it can be unit-tested without an instance.
    static func configureExportPanel(
        _ panel: NSSavePanel,
        inputURL: URL?,
        suffix: String,
        ext: String,
        fallbackFilename: String
    ) {
        guard let inputURL else {
            panel.nameFieldStringValue = fallbackFilename
            return
        }
        panel.directoryURL = inputURL.deletingLastPathComponent()
        panel.nameFieldStringValue = suggestedExportFilename(
            for: inputURL, suffix: suffix, ext: ext
        )
    }

    /// `interview.mp4` + `re-voiced` + `mp4` → `interview_re-voiced.mp4`.
    static func suggestedExportFilename(
        for inputURL: URL,
        suffix: String,
        ext: String
    ) -> String {
        let base = inputURL.deletingPathExtension().lastPathComponent
        return "\(base)_\(suffix).\(ext)"
    }

    /// Returns a human-readable error string if `outURL` resolves to
    /// the same path as `inputURL` (including across symlinks), nil
    /// otherwise. Used as the last line of defense against
    /// accidentally clobbering the source file when the user
    /// navigates the save panel to the input's filename.
    static func refuseOverwriteError(
        outURL: URL,
        inputURL: URL?
    ) -> String? {
        guard let inputURL else { return nil }
        let outPath = outURL.resolvingSymlinksInPath().standardizedFileURL.path
        let inPath = inputURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard outPath == inPath else { return nil }
        return "Refusing to overwrite the input file at \(inPath). Pick a different filename or location and try again."
    }

    // MARK: - Cancel

    func cancel() {
        inflightTask?.cancel()
        inflightTask = nil
        if status.isWorking { status = .idle }
    }
}
