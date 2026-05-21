//
//  DiarizationProvider.swift
//  pocket-tts-macos
//
//  Pluggable speaker-diarization interface used by SpeakerIsolator and
//  MultiSpeakerRevoicer. Mirrors `STTProvider`'s shape: implementations
//  pick the backend (SpeakerKit pyannote, future alternatives) and the
//  caller only handles the timestamped segments coming back.
//
//  Contract:
//    * `diarize` returns segments in chronological order (sorted by
//      startSec).
//    * Each segment's `startSec` / `endSec` is measured from t=0 of
//      the input audio file.
//    * Empty input audio → empty array (NOT an error).
//    * `speakerID` strings are stable for the duration of one
//      `diarize(_:)` call — the same speaker keeps the same label
//      across all of their segments — but identifiers are NOT
//      portable across calls (SPEAKER_00 in one run may be a
//      different person from SPEAKER_00 in another).
//    * Implementations MAY require an out-of-band model download
//      before the first call. Callers should invoke
//      `ensureModelsReady(progress:)` first if the implementation
//      exposes it.

import Foundation

protocol DiarizationProvider: Sendable {
    func diarize(_ audio: URL) async throws -> [DiarizedSegment]
}
