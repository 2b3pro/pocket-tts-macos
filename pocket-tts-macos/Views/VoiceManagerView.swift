//
//  VoiceManagerView.swift
//  pocket-tts-macos
//
//  Central voice management. Import a WAV once → it gets processed for
//  both TTS backends. Single unified list of voices with status badges.

import SwiftUI
import UniformTypeIdentifiers

struct VoiceManagerView: View {
    @Binding var isPresented: Bool
    var onEncodeVoice: ((String) -> Void)?
    var onEnhanceVoice: ((String) -> Void)?

    @State private var showImporter = false
    @State private var enhanceOnImport = true
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var voiceToDelete: FishVoice?

    var body: some View {
        ModalContainer(title: "Voice Manager", onClose: { isPresented = false }) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                importSection
                Divider().background(Theme.borderColor)
                voicesList
                Divider().background(Theme.borderColor)
                actions
            }
            .frame(maxWidth: 560, maxHeight: 500)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.wav, .mp3, .aiff, .audio],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .task { await verifyAndEncodeVoices() }
        .alert("Delete Voice", isPresented: Binding(
            get: { voiceToDelete != nil },
            set: { if !$0 { voiceToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { voiceToDelete = nil }
            Button("Delete", role: .destructive) {
                if let voice = voiceToDelete {
                    FishVoiceManager.shared.deleteVoice(id: voice.id)
                    voiceToDelete = nil
                }
            }
        } message: {
            Text("Delete \"\(voiceToDelete?.name ?? "")\"? This removes the voice and all its encoded data from both backends.")
        }
    }

    private func verifyAndEncodeVoices() async {
        let needsEncoding = FishVoiceManager.shared.verifyVoiceStates()
        for voiceID in needsEncoding {
            onEncodeVoice?(voiceID)
        }
    }

    // MARK: - Import

    private var importSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            HStack {
                Text("Add a Voice")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(action: { showImporter = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13))
                        Text("Import WAV")
                            .font(Theme.fontXS)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
                .buttonStyle(.plain)
            }
            Text("Import a voice recording (.wav, .mp3, .aiff). The voice will be processed for both TTS backends automatically.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)

            Toggle(isOn: $enhanceOnImport) {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 11))
                    Text("Enhance with LavaSR")
                        .font(Theme.fontXS)
                }
                .foregroundStyle(Theme.textPrimary)
            }
            .toggleStyle(.checkbox)
            .disabled(!VoiceEnhancer.shared.isReady && VoiceEnhancer.shared.status != .idle)

            if let statusMessage {
                Text(statusMessage)
                    .font(Theme.fontXS)
                    .foregroundStyle(statusIsError ? Theme.errorFG : Theme.successFG)
            }
        }
    }

    // MARK: - Voices list

    private var voicesList: some View {
        let voices = FishVoiceManager.shared.voices

        return VStack(alignment: .leading, spacing: Theme.space3) {
            HStack {
                Text("My Voices")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(voices.count)")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
            }

            if voices.isEmpty {
                Text("No voices imported yet. Use \"Import WAV\" above to add a voice.")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, Theme.space2)
            } else {
                ScrollView {
                    VStack(spacing: Theme.space1) {
                        ForEach(voices) { voice in
                            voiceRow(voice)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack {
            Spacer()
            Button(action: { isPresented = false }) {
                Text("Done")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Voice row

    private func voiceRow(_ voice: FishVoice) -> some View {
        HStack(spacing: Theme.space3) {
            Text(voice.name)
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer()

            ForEach(statusBadges(voice), id: \.self) { badge in
                Text(badge)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
            }

            Button(action: { voiceToDelete = voice }) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.errorFG)
            }
            .buttonStyle(.plain)
            .help("Delete voice")
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2)
        .background(Theme.bgTertiary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
    }

    private func statusBadges(_ voice: FishVoice) -> [String] {
        var badges: [String] = []
        if voice.isEnhanced { badges.append("Enhanced") }
        if voice.cachedCodesPath != nil && voice.pocketTTSKVPath != nil {
            badges.append("Ready")
        } else if voice.cachedCodesPath != nil || voice.pocketTTSKVPath != nil {
            badges.append("Partial")
        } else {
            badges.append("Pending")
        }
        return badges
    }

    // MARK: - Import handler

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let name = url.deletingPathExtension().lastPathComponent

        guard url.startAccessingSecurityScopedResource() else {
            statusMessage = "Cannot access file"
            statusIsError = true
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let voice = try FishVoiceManager.shared.importVoice(from: url, name: name)
            statusIsError = false

            if enhanceOnImport {
                statusMessage = "Enhancing \"\(name)\"..."
                onEnhanceVoice?(voice.id)
            } else {
                statusMessage = "Encoding \"\(name)\"..."
                onEncodeVoice?(voice.id)
            }
            statusMessage = "Imported \"\(name)\""
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { statusMessage = nil }
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
            statusIsError = true
        }
    }
}
