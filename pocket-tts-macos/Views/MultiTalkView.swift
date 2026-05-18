//
//  MultiTalkView.swift
//  pocket-tts-macos
//
//  Ports Electron's Multi-Talk tab. Sidebar has the Speakers panel + standard
//  Synth/Status/Player triplet; right side has the script editor.

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct MultiTalkView: View {
    @Bindable var viewModel: MultiTalkViewModel
    let voices: [Voice]
    @Binding var pendingReuse: PendingReuse?
    @Environment(\.modelContext) private var modelContext

    @Binding var chatSettings: ChatSettings
    var onEncodeVoice: ((String) -> Void)?

    @State private var showPauseModal = false
    @State private var showGenerator = false
    @State private var showVoiceImporter = false
    @State private var voiceImportMessage: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: Theme.space6) {
                // Left sidebar
                VStack(spacing: Theme.space4) {
                    BackendSelector(
                        activeBackend: $chatSettings.activeBackend,
                        fishParams: $chatSettings.fishParams,
                        disabled: viewModel.status.isWorking
                    )

                    speakersPanel

                    SynthesizeButton(
                        status: viewModel.status,
                        canSynthesize: viewModel.status.canSynthesize && !viewModel.script.trimmingCharacters(in: .whitespaces).isEmpty,
                        onSynthesize: { viewModel.synthesize() },
                        onStop:       { viewModel.stop() },
                        onPause:      { viewModel.pause() },
                        onResume:     { viewModel.resume() },
                        accessibilityIDPrefix: "multi"
                    )

                    if chatSettings.activeBackend == .pocketTTS {
                        StatusIndicator(status: viewModel.status)
                    }

                    if let samples = viewModel.lastResultSamples {
                        AudioPlayer(samples: samples, accessibilityIDPrefix: "multi")
                    }

                    Spacer(minLength: 0)
                }
                .frame(width: Theme.sidebarWidth)

                // Right: script editor (NSTextView-backed so the speaker
                // tag + pause buttons can insert at the cursor instead of
                // appending to the end of the buffer).
                TextInput(
                    text: $viewModel.script,
                    label: "Script",
                    placeholder: "Use {SpeakerName} to tag speakers and [Xs] for pauses.\n\nExample:\n{Alice} Hello there!\n[1.5s]\n{Bob} Hi, Alice.",
                    disabled: viewModel.status.isWorking,
                    onGenerateClick: { showGenerator = true },
                    onPauseClick: { showPauseModal = true },
                    accessibilityID: "multi.scriptEditor",
                    editorBridge: viewModel.editorBridge
                )
            }
            .padding(.horizontal, Theme.space6)
            .padding(.vertical, Theme.space4)

            if showPauseModal {
                PauseModal(
                    isPresented: $showPauseModal,
                    onInsert: { dur in viewModel.insertPause(seconds: dur) }
                )
            }

            if showGenerator {
                ScriptGeneratorModal(
                    isPresented: $showGenerator,
                    mode: .multiTalk,
                    chatSettings: $chatSettings,
                    onAccept: { script, speakerNames in
                        viewModel.script = script
                        viewModel.applySpeakersFromGeneration(names: speakerNames, voices: voices)
                    }
                )
            }
        }
        .onAppear {
            viewModel.setModelContext(modelContext)
            if case let .multi(script, speakers) = pendingReuse {
                if chatSettings.activeBackend == .fishSpeech {
                    let fishSpeakers = speakers.map { SpeakerRef(name: $0.name, voiceID: "fish-default") }
                    viewModel.applyReuse(script: script, speakers: fishSpeakers)
                } else {
                    viewModel.applyReuse(script: script, speakers: speakers)
                }
                pendingReuse = nil
            }
        }
        .fileImporter(
            isPresented: $showVoiceImporter,
            allowedContentTypes: [.wav, .mp3, .aiff, .audio],
            allowsMultipleSelection: false
        ) { result in
            handleVoiceImport(result)
        }
    }

    // MARK: - Voice import

    private func handleVoiceImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let name = url.deletingPathExtension().lastPathComponent

        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let voice = try FishVoiceManager.shared.importVoice(from: url, name: name)
            voiceImportMessage = "Encoding voice..."
            onEncodeVoice?(voice.id)
            voiceImportMessage = "Imported \"\(name)\""
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { voiceImportMessage = nil }
            // Set all speakers to the new voice
            for i in viewModel.speakers.indices {
                viewModel.speakers[i].voiceID = voice.id
            }
        } catch {
            print("[MultiTalkView] voice import failed: \(error)")
        }
    }

    // MARK: - Speakers panel

    private var speakersPanel: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            HStack {
                Text("Speakers")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if chatSettings.activeBackend == .fishSpeech {
                    Button(action: { showVoiceImporter = true }) {
                        Text("+ Import Voice")
                            .font(Theme.fontXS)
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.status.isWorking)
                }
                Button(action: { viewModel.addSpeaker() }) {
                    Text("+ Add Speaker")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.status.isWorking)
                .accessibilityIdentifier("multi.addSpeakerButton")
            }

            if let voiceImportMessage {
                Text(voiceImportMessage)
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.successFG)
            }

            VStack(spacing: Theme.space2) {
                ForEach(Array(viewModel.speakers.enumerated()), id: \.element.id) { (idx, _) in
                    SpeakerCard(
                        speaker: $viewModel.speakers[idx],
                        voices: voices,
                        activeBackend: chatSettings.activeBackend,
                        canRemove: viewModel.speakers.count > 1,
                        disabled: viewModel.status.isWorking,
                        onInsertToScript: { name in viewModel.insertSpeakerTag(name) },
                        onRemove: { viewModel.removeSpeaker(at: idx) },
                        cardIndex: idx
                    )
                }
            }
        }
        .themePanel()
    }
}
