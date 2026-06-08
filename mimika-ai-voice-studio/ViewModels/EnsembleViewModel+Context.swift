//
//  EnsembleViewModel+Context.swift
//  mimika-ai-voice-studio
//
//  Point-of-view transcript rendering — the single mechanism that gives every
//  speaker both "shared context" and "unawareness": each persona sees its own
//  lines as the assistant and everyone else (other personas AND the user) as
//  name-prefixed people, never as AIs. Kept as a pure static so it can be unit
//  tested without constructing the whole view model.
//

import Foundation

extension EnsembleViewModel {

    /// Build the `[ChatMessage]` to feed `me`'s LLM request from the canonical
    /// transcript. The model only ever sees a window (rolling summary + the
    /// last N verbatim turns); the full transcript stays app-side.
    static func renderPOV(
        turns: [EnsembleTurn],
        for me: Persona,
        rollingSummary: String = "",
        window: Int = 16
    ) -> [ChatMessage] {
        var out: [ChatMessage] = []

        if !rollingSummary.isEmpty {
            out.append(ChatMessage(role: .user, content: "Earlier in the conversation: \(rollingSummary)"))
        }

        let windowed = Array(turns.suffix(max(0, window)))
        for turn in windowed {
            if turn.speakerID == me.id {
                // My own line — I am the assistant.
                var content = turn.content
                if turn.wasCutOff { content += "  [cut off]" }
                out.append(ChatMessage(role: .assistant, content: content))
            } else {
                // Another persona OR the user — a name-prefixed external person.
                var content = "\(turn.speakerName): \(turn.content)"
                if turn.wasCutOff { content += " [cut off]" }
                out.append(ChatMessage(role: .user, content: content))
            }
        }

        // First turn of the scene — there is nothing to react to yet. Hand the
        // model a concrete, benign kickoff instead of an EMPTY messages array:
        // generating an assistant turn into a void lets a weakly-aligned local
        // model confabulate a request (occasionally a harmful one) out of nothing.
        if windowed.isEmpty {
            out.append(ChatMessage(role: .user, content: "You're opening the scene. Say your first line now — in character, on the established scene and topic, as one short spoken sentence."))
        }

        // If my own line is the most recent, nudge for a NEW line rather than an
        // echo — local models sometimes need the trailing-user-turn convention.
        if windowed.last?.speakerID == me.id {
            out.append(ChatMessage(role: .user, content: "(continue)"))
        }

        return out
    }

    /// Instance convenience used by the turn loop.
    func messagesForPersona(_ me: Persona) -> [ChatMessage] {
        // Render everything not yet folded into the rolling summary (at least the
        // verbatim window), capped at maxContextTurns so a stalled summarizer
        // can't blow the model's context window.
        let unsummarized = max(verbatimWindow, turns.count - summarizedUpTo)
        let effectiveWindow = min(unsummarized, max(verbatimWindow, Self.maxContextTurns))
        return Self.renderPOV(turns: turns, for: me, rollingSummary: rollingSummary, window: effectiveWindow)
    }
}
