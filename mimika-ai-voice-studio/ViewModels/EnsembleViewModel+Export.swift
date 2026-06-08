//
//  EnsembleViewModel+Export.swift
//  mimika-ai-voice-studio
//
//  Phase 6 — export + history. Render the finished episode as a {Name}-tagged
//  Multi-Talk script (real names), then either open it in the Multi-Talk tab
//  (reuses that tab's render/export — no new audio code) or save it to History.
//

import Foundation

extension EnsembleViewModel {

    /// True when there's a non-empty transcript to export or save.
    var canExport: Bool {
        turns.contains { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// `{Name} line` per turn (real names), stage directions stripped per the
    /// active backend. Directly consumable by MultiTalkScriptParser.
    func formatTranscriptMultiTalk() -> String {
        Self.formatMultiTalkScript(
            turns: turns,
            stripBrackets: appState.chatSettings.activeBackend == .pocketTTS
        )
    }

    /// Pure renderer (static for testing).
    static func formatMultiTalkScript(turns: [EnsembleTurn], stripBrackets: Bool) -> String {
        var lines: [String] = []
        for turn in turns {
            let cleaned = TextNormalizer.stripStageDirections(turn.content, stripBracketedTags: stripBrackets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let name = turn.speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("{\(name.isEmpty ? "Speaker" : name)} \(cleaned)")
        }
        return lines.joined(separator: "\n")
    }

    /// Speaker → voice for the export: each cast member's voice, plus a stock
    /// fallback for the user so their interjections still render.
    func exportSpeakers() -> [SpeakerRef] {
        var refs: [SpeakerRef] = []
        var seen = Set<String>()
        for persona in cast {
            let name = persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            refs.append(SpeakerRef(name: name, voiceID: persona.voiceID))
        }
        let userName = userPeer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userName.isEmpty,
           turns.contains(where: { $0.speakerID == nil }),
           seen.insert(userName).inserted {
            refs.append(SpeakerRef(name: userName, voiceID: cast.first?.voiceID ?? "cosette"))
        }
        return refs
    }

    /// Open this episode in the Multi-Talk tab (reuses its render/export path).
    func openInMultiTalk() {
        guard canExport else { return }
        appState.queueReuse(.multi(script: formatTranscriptMultiTalk(), speakers: exportSpeakers()))
    }

    /// Save the episode so it appears in History (+ the Ensemble session store).
    func saveEpisodeToHistory() {
        guard let ctx = appState.modelContext, canExport else { return }
        let script = formatTranscriptMultiTalk()
        let speakers = exportSpeakers()
        HistoryStore.appendMulti(script: script, speakers: speakers, context: ctx)
        EnsembleStore.appendSession(ctx, scene: scene, mood: mood,
                                    transcriptMultiTalk: script, speakers: speakers)
        showNotice("Saved to History")
    }
}
