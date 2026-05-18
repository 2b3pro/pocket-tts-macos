//
//  VoiceManagerView.swift
//  pocket-tts-macos
//
//  Central voice management. Drop/upload a WAV → name it → enhance →
//  processed for both TTS backends. Mirrors the Electron app's flow:
//  Reference Audio drop zone → Save Voice Preset → Enhancement.

import SwiftUI
import UniformTypeIdentifiers

struct VoiceManagerView: View {
    @Binding var isPresented: Bool
    var onEncodeVoice: ((String) -> Void)?
    var onEnhanceVoice: ((String) -> Void)?

    // Import flow state
    @State private var showImporter = false
    @State private var pendingFileURL: URL?
    @State private var voiceName = ""
    @State private var voiceDescription = ""
    @State private var enhanceOnImport = true
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isDropTargeted = false
    @State private var voiceToDelete: FishVoice?

    var body: some View {
        ModalContainer(title: "Voice Manager", onClose: { isPresented = false }) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                if pendingFileURL != nil {
                    saveVoiceForm
                } else {
                    dropZone
                }
                Divider().background(Theme.borderColor)
                voicesList
                Divider().background(Theme.borderColor)
                actions
            }
            .frame(maxWidth: 560, maxHeight: 600)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.wav, .mp3, .aiff, .audio],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                pendingFileURL = url
                voiceName = url.deletingPathExtension().lastPathComponent
                voiceDescription = ""
            }
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
            Text("Delete \"\(voiceToDelete?.name ?? "")\"? This removes the voice and all its encoded data.")
        }
    }

    private func verifyAndEncodeVoices() async {
        let needsEncoding = FishVoiceManager.shared.verifyVoiceStates()
        for voiceID in needsEncoding {
            onEncodeVoice?(voiceID)
        }
    }

    // MARK: - Drop zone (Reference Audio)

    private var dropZone: some View {
        VStack(spacing: Theme.space3) {
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Text("Reference Audio")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { showImporter = true }) {
                VStack(spacing: Theme.space3) {
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Drop Audio Here")
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textPrimary)
                    Text("- or -")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                    Text("Click to Upload")
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.accent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.space6)
                .background(isDropTargeted ? Theme.bgTertiary : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                        .foregroundStyle(isDropTargeted ? Theme.accent : Theme.borderColor)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
            .onDrop(of: [.audio, .fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(Theme.fontXS)
                    .foregroundStyle(statusIsError ? Theme.errorFG : Theme.successFG)
            }
        }
    }

    // MARK: - Save Voice form

    private var saveVoiceForm: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("Save Voice Preset")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)

            if let url = pendingFileURL {
                HStack(spacing: 6) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Source: \(url.lastPathComponent)")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, Theme.space3)
                .padding(.vertical, Theme.space2)
                .background(Theme.bgTertiary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
            }

            VStack(alignment: .leading, spacing: Theme.space1) {
                Text("Voice Name *")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                TextField("e.g., My Voice, John's Voice", text: $voiceName)
                    .textFieldStyle(.plain)
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Theme.space3)
                    .padding(.vertical, Theme.space2)
                    .themeInputField()
            }

            VStack(alignment: .leading, spacing: Theme.space1) {
                Text("Description (optional)")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                TextField("e.g., Male, casual tone", text: $voiceDescription)
                    .textFieldStyle(.plain)
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Theme.space3)
                    .padding(.vertical, Theme.space2)
                    .themeInputField()
            }

            Toggle(isOn: $enhanceOnImport) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 11))
                        Text("Enhance with LavaSR")
                            .font(Theme.fontXS)
                    }
                    Text("Improves audio quality for better voice cloning")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
                .foregroundStyle(Theme.textPrimary)
            }
            .toggleStyle(.checkbox)

            HStack {
                Button(action: { pendingFileURL = nil; voiceName = ""; voiceDescription = "" }) {
                    Text("Cancel")
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Theme.space4)
                        .padding(.vertical, Theme.space2)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: saveVoice) {
                    Text("Save Voice")
                        .font(Theme.fontSMBold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.space4)
                        .padding(.vertical, Theme.space2)
                        .background(canSave ? Theme.accent : Color.gray.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(Theme.fontXS)
                    .foregroundStyle(statusIsError ? Theme.errorFG : Theme.successFG)
            }
        }
    }

    private var canSave: Bool {
        pendingFileURL != nil && !voiceName.trimmingCharacters(in: .whitespaces).isEmpty
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
                Text("No voices yet. Drop or upload a recording above.")
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
                .frame(maxHeight: 200)
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

    // MARK: - Save handler

    private func saveVoice() {
        guard let url = pendingFileURL else { return }
        let name = voiceName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        guard url.startAccessingSecurityScopedResource() else {
            statusMessage = "Cannot access file"
            statusIsError = true
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            var voice = try FishVoiceManager.shared.importVoice(from: url, name: name)
            if !voiceDescription.isEmpty {
                FishVoiceManager.shared.setDescription(voiceDescription, for: voice.id)
            }
            statusIsError = false

            if enhanceOnImport {
                statusMessage = "Enhancing \"\(name)\"..."
                onEnhanceVoice?(voice.id)
            } else {
                statusMessage = "Encoding \"\(name)\"..."
                onEncodeVoice?(voice.id)
            }
            statusMessage = "Saved \"\(name)\""
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { statusMessage = nil }

            // Reset form
            pendingFileURL = nil
            voiceName = ""
            voiceDescription = ""
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
            statusIsError = true
        }
    }

    // MARK: - Drop handler

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.audio.identifier) { item, _ in
                if let url = item as? URL {
                    DispatchQueue.main.async {
                        pendingFileURL = url
                        voiceName = url.deletingPathExtension().lastPathComponent
                    }
                }
            }
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async {
                        pendingFileURL = url
                        voiceName = url.deletingPathExtension().lastPathComponent
                    }
                }
            }
            return true
        }

        return false
    }
}
