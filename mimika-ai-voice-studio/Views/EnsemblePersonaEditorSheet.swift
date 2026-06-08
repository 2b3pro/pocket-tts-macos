//
//  EnsemblePersonaEditorSheet.swift
//  mimika-ai-voice-studio
//
//  Fail-safe at the Confirm-voices step: open a generated persona and review or
//  rewrite its name + persona script before the cast goes live (catches a bogus
//  or off-tone script the writer returned — local or cloud). Edits write
//  straight into PersonaWriter.personas, which startEnsemble() reads, so changes
//  flow into the cast with no extra plumbing.
//

import SwiftUI

struct EnsemblePersonaEditorSheet: View {
    @Bindable var writer: PersonaWriter
    let index: Int
    let onClose: () -> Void

    var body: some View {
        ModalContainer(title: "Edit Persona", onClose: onClose, fillsSheet: true) {
            VStack(alignment: .leading, spacing: Theme.space3) {
                if writer.personas.indices.contains(index) {
                    HStack {
                        Text("Name").font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
                            .frame(width: 70, alignment: .leading)
                        TextField("", text: $writer.personas[index].name)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, Theme.space3).padding(.vertical, Theme.space2)
                            .themeInputField()
                    }

                    Text("Persona script — who this character is and how they speak. This is the system prompt the model gets every turn; tweak it if the writer returned anything off.")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextEditor(text: $writer.personas[index].personaPrompt)
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(Theme.space3)
                        .frame(minHeight: 220, maxHeight: 340)
                        .themeInputField()
                } else {
                    Text("This persona is no longer available.")
                        .font(Theme.fontSM).foregroundStyle(Theme.textSecondary)
                }

                Spacer()
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Text("Done")
                            .font(Theme.fontSMBold).foregroundStyle(.white)
                            .padding(.horizontal, Theme.space4).padding(.vertical, Theme.space2)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ensemble.personaEditor.done")
                }
            }
            .frame(minWidth: 440, minHeight: 380)
        }
    }
}
