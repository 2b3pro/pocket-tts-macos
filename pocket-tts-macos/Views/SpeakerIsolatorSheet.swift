//
//  SpeakerIsolatorSheet.swift
//  pocket-tts-macos
//
//  Modal sheet for the Speaker Isolation feature. Input audio or
//  video (.mp4) → diarize via SpeakerKit → isolated PCM per speaker
//  → user picks how to export:
//
//   * Per-row "Export" — save just that speaker's isolated WAV.
//   * Footer "Export Isolated…" — batch all speakers into a folder.
//   * Per-row voice picker + footer "Change Voices…" — re-voice each
//     assigned speaker via the existing Voice Changer pipeline, sum
//     into one combined track, optionally re-mux into the original
//     video for closed-loop .mp4 in → .mp4 out.
//
//  Reachable from:
//   * Multi-Talk sidebar's "Isolate Speakers from Recording…" button.
//   * File → Isolate Speakers… menu (⌥⌘I).
//  Both paths toggle `AppState.showsSpeakerIsolator`.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SpeakerIsolatorSheet: View {
    @Binding var isPresented: Bool
    @Bindable var viewModel: SpeakerIsolatorViewModel
    let voices: [BundledVoice]
    @Bindable var modelManager: WhisperModelManager
    @Binding var chatSettings: ChatSettings

    @State private var showImporter: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var showDiarizationSettings: Bool = false
    @State private var showModelManagerSheet: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.space4) {
                    inputAudioSection
                    optionsSection
                    diarizationSettingsSection
                    transcriptionModelSection

                    if case let .error(message) = viewModel.status {
                        errorSection(message)
                    }

                    if !viewModel.speakers.isEmpty {
                        resultsSection
                    }
                }
                .padding(.horizontal, Theme.space4)
                .padding(.bottom, Theme.space4)
            }

            footer
        }
        .frame(width: 620, height: 720)
        .background(Theme.bgPrimary)
        // Sub-sheet for WhisperKit's Manage Models view. Mirrors
        // VoiceChangerSheet's wiring so the user can switch / download
        // a transcription model without leaving the Speaker Isolator —
        // the Change-Voices pipeline uses the same STT as Voice Changer.
        .sheet(isPresented: $showModelManagerSheet) {
            WhisperModelManagerSheet(
                isPresented: $showModelManagerSheet,
                modelManager: modelManager
            )
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.wav, .mp3, .aiff, .audio, .movie, .mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                viewModel.clear()
                viewModel.setInputAudio(url)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Speaker Isolation")
                    .font(Theme.fontLG)
                    .foregroundStyle(Theme.textPrimary)
                Text("Diarize a multi-speaker recording and split it into one track per speaker. Optionally re-voice each speaker and re-encode back into video.")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.space4)
        .padding(.top, Theme.space4)
    }

    // MARK: - Input audio

    private var inputAudioSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            sectionLabel("Input Audio or Video", systemImage: "waveform")

            if let url = viewModel.inputAudioURL {
                loadedAudioRow(url)
            } else {
                dropZone
            }
        }
        .themePanel()
    }

    private var dropZone: some View {
        Button(action: { showImporter = true }) {
            VStack(spacing: Theme.space3) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.textSecondary)
                Text("Drop Audio or Video Here")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textPrimary)
                Text("- or -")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                Text("Click to Upload")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.accent)
                Text(".wav · .mp3 · .aiff · .m4a · .mp4 · .mov")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.space4)
            .background(isDropTargeted ? Theme.bgTertiary : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    .foregroundStyle(isDropTargeted ? Theme.accent : Theme.borderColor)
            )
        }
        .buttonStyle(.plain)
        .onDrop(of: [.audio, .fileURL, .movie, .mpeg4Movie], isTargeted: $isDropTargeted) { handleDrop($0) }
        .disabled(viewModel.status.isWorking)
    }

    private func loadedAudioRow(_ url: URL) -> some View {
        // X (clear) is locked down once isolation results exist —
        // tapping it mid-render would crash the row bindings whose
        // captured `Int` index would go stale. The "Start Over"
        // button in the results section header is the deliberate
        // way to reset from that state.
        let canClear = !viewModel.status.isWorking && viewModel.speakers.isEmpty
        return HStack(spacing: Theme.space3) {
            Image(systemName: isVideoURL(url) ? "film" : "waveform.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let secs = viewModel.inputDurationSec {
                        Text(timeString(secs))
                            .font(Theme.fontXS)
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("Loading…")
                            .font(Theme.fontXS)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if isVideoURL(url) {
                        Text("· Video — frames preserved if you re-encode")
                            .font(Theme.fontXS)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Spacer()
            Button(action: { viewModel.clear() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(canClear ? Theme.textSecondary : Theme.textSecondary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .help(canClear
                  ? "Clear input"
                  : "Locked — use \"Start Over\" below to reset and load a different file")
            .disabled(!canClear)
        }
        .padding(Theme.space3)
        .background(Theme.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    // MARK: - Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            sectionLabel("Options", systemImage: "slider.horizontal.3")

            Toggle(isOn: $viewModel.preserveSilenceForIsolatedExport) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preserve original timing in exported tracks")
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textPrimary)
                    Text("When on, each isolated WAV matches the input length with silence where the other speakers were talking. When off, each export concatenates only that speaker's speech back-to-back. The Change Voices flow always uses preserved timing internally regardless of this toggle.")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(viewModel.status.isWorking)
        }
        .themePanel()
    }

    // MARK: - Diarization settings (advanced)

    /// Disclosure panel with the tuning knobs that the diarizer
    /// accepts. Collapsed by default — most users get good results
    /// with the SpeakerKit defaults, and the section is here for the
    /// "more than 2 speakers, output is being merged/split badly"
    /// case. Once isolation has produced results the controls
    /// disable themselves (no point editing settings whose pass is
    /// already done — the user uses Start Over + tweak + Isolate
    /// again to retry).
    private var diarizationSettingsSection: some View {
        let settings = viewModel.diarizationSettings
        let isModified = settings.numberOfSpeakers != nil
            || settings.sensitivity != DiarizationSettings.defaultSensitivity

        return VStack(alignment: .leading, spacing: Theme.space3) {
            // Custom collapsible header — wraps the WHOLE row in a
            // Button + `.contentShape(Rectangle())` so the entire
            // header (icon, title, "(modified)" tag, trailing space)
            // is clickable, not just the chevron. SwiftUI's stock
            // `DisclosureGroup` only registers taps on the triangle
            // itself, which is too small a hit target for a sheet
            // that already has plenty of horizontal real estate.
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showDiarizationSettings.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .rotationEffect(.degrees(showDiarizationSettings ? 90 : 0))
                        .frame(width: 12)
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Diarization Settings")
                        .font(Theme.fontSMBold)
                        .foregroundStyle(Theme.textPrimary)
                    if isModified {
                        Text("(modified)")
                            .font(Theme.fontXS)
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showDiarizationSettings
                  ? "Hide diarization tuning controls"
                  : "Show advanced controls for the speaker-detection step")

            if showDiarizationSettings {
                VStack(alignment: .leading, spacing: Theme.space3) {
                    diarizationSpeakerCountControl
                    Divider().opacity(0.3)
                    diarizationSensitivityControl

                    HStack {
                        Spacer()
                        Button(action: {
                            viewModel.diarizationSettings = DiarizationSettings()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Reset to defaults")
                                    .font(Theme.fontXS)
                            }
                            .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.status.isWorking || !isModified)
                    }
                }
                .padding(.top, Theme.space2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .themePanel()
    }

    /// Number-of-speakers stepper. 0 = Auto (no constraint passed to
    /// the diarizer); 1...10 forces an exact count. Clamps at 10 to
    /// keep the UI sane — beyond that the auto-detect is probably the
    /// better path anyway.
    private var diarizationSpeakerCountControl: some View {
        let count = viewModel.diarizationSettings.numberOfSpeakers ?? 0
        return HStack(alignment: .top, spacing: Theme.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Number of Speakers")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textPrimary)
                Text("Force the diarizer to find exactly this many speakers. Leave on Auto unless the detection is consistently merging or splitting the wrong way.")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack(spacing: Theme.space2) {
                Text(count == 0 ? "Auto" : "\(count)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 36, alignment: .trailing)
                Stepper(value: speakerCountBinding, in: 0...10) {
                    EmptyView()
                }
                .labelsHidden()
                .controlSize(.small)
            }
            .disabled(viewModel.status.isWorking || !viewModel.speakers.isEmpty)
        }
    }

    /// Sensitivity slider. 0.0 = merge aggressively (fewer speakers);
    /// 1.0 = split aggressively (more speakers); 0.5 = SpeakerKit's
    /// default. The value maps onto pyannote's clusterDistanceThreshold
    /// inside `DiarizationSettings.pyannoteClusterDistanceThreshold`.
    private var diarizationSensitivityControl: some View {
        let sens = viewModel.diarizationSettings.sensitivity
        return VStack(alignment: .leading, spacing: Theme.space2) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speaker Sensitivity")
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Bump up if different voices are being lumped into one speaker. Pull down if one person's voice is being split across multiple speakers.")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(sensitivityLabel(sens))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 56, alignment: .trailing)
            }
            Slider(value: sensitivityBinding, in: 0.0...1.0, step: 0.05)
                .controlSize(.small)
                .tint(Theme.accent)
            HStack {
                Text("Merge more")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("Default")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                Spacer()
                Text("Split more")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
            }
            .disabled(viewModel.status.isWorking || !viewModel.speakers.isEmpty)
        }
        .disabled(viewModel.status.isWorking || !viewModel.speakers.isEmpty)
    }

    private func sensitivityLabel(_ s: Double) -> String {
        // Show one decimal place; tag the default exactly.
        if abs(s - DiarizationSettings.defaultSensitivity) < 0.001 {
            return "Default"
        }
        return String(format: "%.2f", s)
    }

    // MARK: - Transcription model

    /// Mirror of `VoiceChangerSheet.modelSection`. Surfaced here too
    /// because the Change Voices pipeline uses Whisper for STT (per-
    /// speaker isolated audio → transcript → revoice). Letting the
    /// user download / switch models without bouncing over to Single
    /// Voice → Change Voice saves a context shift.
    private var transcriptionModelSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            sectionLabel("Transcription Model", systemImage: "doc.text.viewfinder")

            HStack(spacing: Theme.space3) {
                if let active = modelManager.active {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(active.displayName)
                            .font(Theme.fontSMBold)
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(active.approxSize) · \(active.speedDescription)")
                            .font(Theme.fontXS)
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warningFG)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Speech Recognition (fallback)")
                            .font(Theme.fontSMBold)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Used only for the Change Voices step. Slower and less accurate than Whisper — download a model for higher quality re-voicing.")
                            .font(Theme.fontXS)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button("Manage Models…") {
                    showModelManagerSheet = true
                }
                .buttonStyle(.plain)
                .font(Theme.fontSM)
                .foregroundStyle(Theme.accent)
                .disabled(viewModel.status.isWorking)
            }
        }
        .themePanel()
    }

    // MARK: - Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            HStack {
                sectionLabel("Detected Speakers", systemImage: "person.2.wave.2")
                Spacer()
                Button(action: { viewModel.clearResults() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Start Over")
                            .font(Theme.fontXS)
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Theme.space3)
                    .padding(.vertical, 4)
                    .background(Theme.bgPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.status.isWorking)
                .help("Discard the current isolation results and keep the input file loaded so you can tweak settings and re-run")
            }

            VStack(spacing: Theme.space2) {
                ForEach(Array(viewModel.speakers.enumerated()), id: \.element.id) { index, speaker in
                    speakerRow(speaker: speaker, index: index)
                }
            }
        }
        .themePanel()
    }

    @ViewBuilder
    private func speakerRow(speaker: SpeakerIsolatorViewModel.SpeakerTrack, index: Int) -> some View {
        let isExpanded = viewModel.expandedSpeakerID == speaker.id
        let isPlayingThis = viewModel.playingSpeakerID == speaker.id

        VStack(spacing: 6) {
            HStack(spacing: Theme.space3) {
                // Editable display name
                TextField("Speaker name", text: nameBinding(forIndex: index))
                    .textFieldStyle(.plain)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: 140, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Theme.borderColor.opacity(0.5), lineWidth: 1)
                    )
                    .disabled(viewModel.status.isWorking)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(timeString(speaker.durationSec)) · \(speaker.segments) segment\(speaker.segments == 1 ? "" : "s")")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                // Voice picker (per-row, for Change Voices flow)
                voicePicker(forIndex: index)
                    .frame(width: 160)

                // Play button. Icon mirrors the ACTUAL playback state
                // (not just the row's expansion) so the user can tell
                // at a glance whether sound is coming out. Three cases
                // on click:
                //   * Row not expanded → expand + start playing.
                //   * Row expanded AND playing → pause (keep expanded
                //     so the scrubber stays available).
                //   * Row expanded AND paused → resume.
                Button(action: { handleRowPlayTap(speaker.id) }) {
                    Image(systemName: isPlayingThis ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.status.isWorking)
                .help(isPlayingThis ? "Pause this speaker's isolated audio" : "Preview this speaker's isolated audio")

                // Per-row export
                Button(action: { viewModel.exportSingleSpeaker(at: index) }) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.status.isWorking)
                .help("Export this speaker's isolated WAV")
            }

            if isExpanded {
                MiniAudioPlayer(
                    samples: speaker.isolatedSamples,
                    sampleRate: 24_000,
                    segments: speaker.segmentRanges,
                    isPlaying: playingBinding(for: speaker.id)
                )
                .padding(.horizontal, 4)
            }
        }
        .padding(Theme.space3)
        .background(Theme.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    // MARK: - Action picker (3-way: Use original / Discard / Revoice)

    @ViewBuilder
    private func voicePicker(forIndex index: Int) -> some View {
        let isBackground = index < viewModel.speakers.count
            && viewModel.speakers[index].isBackground
        let allBuiltIn = voices
            .filter { $0.type == .predefined }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let imported = VoiceManager.shared.voices.filter { $0.pocketTTSKVPath != nil }

        Picker(selection: actionBinding(forIndex: index)) {
            Text("Use original audio").tag(SpeakerAction.useOriginal)
            Text("Discard (exclude from output)").tag(SpeakerAction.discard)

            // Background row can't be re-voiced (you can't TTS music).
            // Speaker rows show the full voice catalog grouped into
            // Built-in + My Voices sections.
            if !isBackground {
                Section("Built-in") {
                    ForEach(allBuiltIn, id: \.id) { v in
                        Text(v.name).tag(SpeakerAction.revoice(voiceID: v.id))
                    }
                }
                if !imported.isEmpty {
                    Section("My Voices") {
                        ForEach(imported) { v in
                            Text(v.isEnhanced ? "✨ \(v.name)" : v.name)
                                .tag(SpeakerAction.revoice(voiceID: "imported:\(v.id)"))
                        }
                    }
                }
            }
        } label: { EmptyView() }
        .pickerStyle(.menu)
        .labelsHidden()
        .disabled(viewModel.status.isWorking)
    }

    // MARK: - Error

    private func errorSection(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: Theme.space2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.errorFG)
            Text(msg)
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.space3)
        .background(Theme.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.space3) {
            if viewModel.status.isWorking {
                ProgressView()
                    .controlSize(.small)
                Text(workingLabel)
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Stop") { viewModel.cancel() }
                    .buttonStyle(.plain)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.errorFG)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            } else if viewModel.speakers.isEmpty {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(Theme.fontSM)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))

                Button("Isolate Speakers") { viewModel.convertAndIsolate() }
                    .buttonStyle(.plain)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(viewModel.canConvertAndIsolate ? Theme.accent : Theme.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .disabled(!viewModel.canConvertAndIsolate)
            } else {
                // Post-isolation: export + change-voices actions
                Spacer()

                Button("Export Isolated…") { viewModel.exportAllIsolated() }
                    .buttonStyle(.plain)
                    .font(Theme.fontSM)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))

                Button("Change Voices…") { runChangeVoices() }
                    .buttonStyle(.plain)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(viewModel.hasAnyActionableChange ? Theme.accent : Theme.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .disabled(!viewModel.hasAnyActionableChange)
                    .help(viewModel.hasAnyActionableChange
                          ? "Re-voice / passthrough / discard each row per its picker selection, then combine into one track"
                          : "Change at least one row's dropdown (pick a voice OR Discard) to enable")
            }
        }
        .padding(.horizontal, Theme.space4)
        .padding(.bottom, Theme.space4)
    }

    private var workingLabel: String {
        switch viewModel.status {
        case .downloadingModels(let progress):
            if let progress {
                return "Downloading diarization models… \(Int(progress * 100))%"
            }
            return "Downloading diarization models…"
        case .loadingAudio:
            return "Loading audio…"
        case .diarizing:
            return "Detecting speakers…"
        case .isolating:
            return "Splitting speaker tracks…"
        case let .revoicing(speakerID, current, total):
            let label = displayNameForSpeaker(speakerID)
            return "Re-voicing \(label): segment \(current) of \(total)…"
        case .muxingVideo:
            return "Re-encoding video…"
        default:
            return ""
        }
    }

    // MARK: - Bindings

    // The bindings below capture an `Int` index into
    // `viewModel.speakers`. If the array shrinks (e.g. user hits the
    // X button on the input row while a row is mid-render), the
    // captured index is stale and a raw subscript would trap with
    // "Index out of range". The lifecycle lock (X disabled when
    // results are present, "Start Over" as the deliberate path)
    // prevents the race in practice, but defensive guards stay as
    // a safety net — SwiftUI render order isn't a contract we
    // should rely on.

    private func nameBinding(forIndex index: Int) -> Binding<String> {
        Binding(
            get: {
                guard index >= 0, index < viewModel.speakers.count else { return "" }
                return viewModel.speakers[index].displayName
            },
            set: { newValue in
                guard index >= 0, index < viewModel.speakers.count else { return }
                viewModel.speakers[index].displayName = newValue
            }
        )
    }

    private func actionBinding(forIndex index: Int) -> Binding<SpeakerAction> {
        Binding(
            get: {
                guard index >= 0, index < viewModel.speakers.count else { return .useOriginal }
                return viewModel.speakers[index].action
            },
            set: { newValue in
                guard index >= 0, index < viewModel.speakers.count else { return }
                viewModel.speakers[index].action = newValue
            }
        )
    }

    /// Stepper binding: 0 in the UI ↔ `nil` (Auto) on the model;
    /// 1...10 ↔ a forced numeric count. Clamps at the UI bounds so
    /// flaky Stepper events (it occasionally over-shoots when held)
    /// can't poison the model.
    private var speakerCountBinding: Binding<Int> {
        Binding(
            get: { viewModel.diarizationSettings.numberOfSpeakers ?? 0 },
            set: { newValue in
                let clamped = min(max(newValue, 0), 10)
                viewModel.diarizationSettings.numberOfSpeakers = (clamped == 0)
                    ? nil
                    : clamped
            }
        )
    }

    /// Slider binding for sensitivity. Updates the nested
    /// `diarizationSettings` value-type directly — SwiftUI's
    /// `@Bindable` + `@Observable` plumbing handles change
    /// propagation for nested struct mutations.
    private var sensitivityBinding: Binding<Double> {
        Binding(
            get: { viewModel.diarizationSettings.sensitivity },
            set: { newValue in
                viewModel.diarizationSettings = DiarizationSettings(
                    numberOfSpeakers: viewModel.diarizationSettings.numberOfSpeakers,
                    sensitivity: newValue
                )
            }
        )
    }

    /// Bidirectional play-state binding for a specific row. Setting
    /// it to true makes THIS speaker the currently-playing one
    /// (auto-pauses any other); setting false clears the field iff
    /// THIS speaker is the current one (avoids racing against a
    /// concurrent switch).
    private func playingBinding(for speakerID: String) -> Binding<Bool> {
        Binding(
            get: { viewModel.playingSpeakerID == speakerID },
            set: { newValue in
                if newValue {
                    viewModel.playingSpeakerID = speakerID
                } else if viewModel.playingSpeakerID == speakerID {
                    viewModel.playingSpeakerID = nil
                }
            }
        )
    }

    // MARK: - Actions

    /// Row-level play-button handler. See the inline comment at the
    /// button declaration for the three-case logic.
    private func handleRowPlayTap(_ speakerID: String) {
        let isExpanded = viewModel.expandedSpeakerID == speakerID
        let isPlayingThis = viewModel.playingSpeakerID == speakerID

        if !isExpanded {
            // Open this row + start playing. Implicitly collapses any
            // previously-expanded row (only one expanded at a time).
            viewModel.expandedSpeakerID = speakerID
            viewModel.playingSpeakerID = speakerID
        } else if isPlayingThis {
            // Pause but keep open so the scrubber stays usable.
            viewModel.playingSpeakerID = nil
        } else {
            // Resume.
            viewModel.playingSpeakerID = speakerID
        }
    }

    private func runChangeVoices() {
        // STT selection mirrors VoiceChangerViewModel: WhisperKit when
        // a model is downloaded, SpeechFramework as the fallback. The
        // `cacheKey` lets the VM reuse a previously-loaded STT
        // instance across subsequent Change-Voices clicks without
        // re-paying the model-load cost, but evict the cache cleanly
        // if the user has since switched models via Manage Models.
        let stt: STTProvider
        let cacheKey: String
        if let activeVariant = WhisperModelManager.shared.active {
            let folderURL = WhisperModelManager.shared.modelFolderURL(for: activeVariant)
            stt = WhisperKitSTT(variant: activeVariant, modelFolderURL: folderURL)
            cacheKey = "whisper:\(activeVariant.rawValue)"
        } else {
            stt = SpeechFrameworkSTT()
            cacheKey = "apple-speech"
        }
        viewModel.runChangeVoicesPipeline(stt: stt, cacheKey: cacheKey)
    }

    // MARK: - Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        for typeID in [UTType.audio.identifier, UTType.movie.identifier, UTType.fileURL.identifier] {
            if provider.hasItemConformingToTypeIdentifier(typeID) {
                provider.loadItem(forTypeIdentifier: typeID) { item, _ in
                    if let url = item as? URL {
                        DispatchQueue.main.async {
                            viewModel.clear()
                            viewModel.setInputAudio(url)
                        }
                    } else if let data = item as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            viewModel.clear()
                            viewModel.setInputAudio(url)
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    // MARK: - Helpers

    private func dismiss() {
        viewModel.clear()
        isPresented = false
    }

    private func sectionLabel(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Text(text)
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func timeString(_ secs: Double) -> String {
        let total = Int(secs.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func displayNameForSpeaker(_ id: String) -> String {
        viewModel.speakers.first(where: { $0.id == id })?.displayName ?? id
    }

    private func isVideoURL(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }
}
