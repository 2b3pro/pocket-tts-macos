# AGENTS.md

Single-shot context for any Codex session working in this repo. Read first.

> **Note:** This file is intentionally checked in (no symlink trick) so the project is self-contained for fresh sessions.

---

## Project Overview

**pocket-tts-macos** is a native Swift / SwiftUI macOS app that replaces the existing Electron-based pocket-tts frontend with a fully on-device, Python-free TTS application. It runs the Kyutai pocket-tts model end-to-end via Core ML `.mlpackage` artifacts (CaLM + Mimi codec), with no Python server, no PyInstaller bundle, and no network dependency for synthesis.


---

## Architecture (Core ML pipeline)

```
At app launch (once per voice selection):
  voice_kv_states/<voice>.safetensors  →  load fp16 K/V tensors
                                       →  MLState.write_state into all 4 mlpackage states
                                          (prompt_phase + calm_stateful share state contents
                                           by re-using the same KV layout; mimi_stateful has
                                           its own separate per-frame state)

Per synthesis call:
  User text → SentencePiece (Swift) → token IDs (padded to T_TEXT_MAX=128)
                                         ↓
        prompt_phase.mlpackage(text_tokens, voice_offset=T_voice, text_length=N)
                                         ↓
                       state buffers now contain voice KV (pos 0..T_voice)
                       + text KV (pos T_voice..T_voice+N)
                                         ↓
                       returns t_prompt = T_voice + N
                                         ↓
        ┌──────── per-frame autoregressive loop (frame_idx = 0, 1, 2, ...) ────────┐
        │                                                                           │
        │  calm_stateful.mlpackage(prev_latent, offset=t_prompt + frame_idx, noise) │
        │                          ──► one latent frame, EOS flag                   │
        │                          (KV state mutated in-place at the offset slot)   │
        │                                       │                                   │
        │                                       ▼                                   │
        │  mimi_stateful.mlpackage(latent)  ──► 1920 PCM samples (80 ms @ 24 kHz)  │
        │                                       │                                   │
        └───────────────────────────────────────┼───────────────────────────────────┘
                                                ▼
                                       AsyncStream<PCMFrame>
                                                ↓
                                       StreamingPlayer (AVAudioEngine)
                                                ↓
                                  speakers + WAV/AAC/MP3 encoder
```

**State-sharing note:** `prompt_phase` and `calm_stateful` were converted with **identical state-buffer shapes and names** (12 buffers: `kv_k_0..5`, `kv_v_0..5`, each `[1, 512, 16, 64]` fp16). Swift maintains ONE logical KV cache and writes it into both models' state objects. The first call (`prompt_phase`) populates positions `0..t_prompt`; subsequent calls (`calm_stateful`) extend it one slot per frame.

- **Frame rate:** 12.5 Hz (80 ms / frame)
- **Sample rate:** 24 kHz mono
- **Steady-state throughput:** ~38 fps on M1 Ultra (~3× real-time)
- **EOS:** CaLM's EOS head signals end; pipeline runs `frames_after_eos` more then stops
- **Numerical equivalence:** validated end-to-end vs PyTorch reference; e2e spectrum correlation 0.97

Conversion details are intentionally kept out of the app repo. The app consumes
checked-in Core ML resources and should not depend on a separate conversion
workspace at runtime.

---

## Project Layout

```
pocket-tts-macos/
├── AGENTS.md                          ← this file
├── pocket-tts-macos.xcodeproj/
├── pocket-tts-macos/
│   ├── road-map.md
│   ├── App/
│   │   ├── PocketTTSMacOSApp.swift   (@main)
│   │   ├── AppState.swift            (global app state + engine ownership)
│   │   └── SynthesisStatus.swift
│   ├── Models/
│   │   ├── BundledVoice.swift        (stock voice catalog entry)
│   │   └── ChatModels.swift
│   ├── Engine/
│   │   ├── TTS/
│   │   │   ├── TTSEngine.swift           (Core ML synthesis orchestrator)
│   │   │   ├── TTSEngineProtocol.swift   (testable engine surface)
│   │   │   ├── Tokenizer.swift           (SentencePiece wrapper)
│   │   │   ├── SentencePieceTokenizer.swift
│   │   │   ├── VoiceLoader.swift         (safetensors → MLMultiArray)
│   │   │   ├── VoiceManager.swift        (saved-voices/ catalog + import + orphan recovery)
│   │   │   ├── ModelPaths.swift          (bundle-resource resolution)
│   │   │   ├── BundledMLModel.swift
│   │   │   ├── BundledMLModelManager.swift
│   │   │   ├── BundledMLModelManagerTypes.swift
│   │   │   ├── FishEngine.swift
│   │   │   ├── MimiEncoder.swift
│   │   │   ├── PocketTTSVoiceEncoder.swift
│   │   │   └── SynthesisCancellation.swift
│   │   ├── Demucs/
│   │   │   ├── DemucsSourceSeparator.swift
│   │   │   ├── DemucsChunker.swift
│   │   │   ├── DemucsResampler.swift
│   │   │   ├── DemucsStemMap.swift
│   │   │   ├── DemucsModelManager.swift
│   │   │   ├── DemucsModelManagerTypes.swift
│   │   │   ├── DemucsModelInstaller.swift
│   │   │   ├── DemucsModelVariant.swift
│   │   │   ├── DemucsZipExtractor.swift
│   │   │   ├── SourceSeparator.swift     (separation protocol)
│   │   │   └── SeparatedStems.swift
│   │   ├── STT/
│   │   │   ├── FluidAudioSTT.swift       (Parakeet transcription backend)
│   │   │   ├── SpeechFrameworkSTT.swift
│   │   │   ├── STTProvider.swift
│   │   │   ├── DictationController.swift
│   │   │   ├── TranscribedSegment.swift
│   │   │   ├── DiarizedSegment.swift
│   │   │   ├── DiarizationProvider.swift
│   │   │   └── FluidAudioDiarizationProvider.swift
│   │   ├── Audio/
│   │   │   ├── AudioBuffer.swift
│   │   │   ├── AudioFileLoader.swift     (decode mono/stereo inputs)
│   │   │   ├── AudioPreconditioner.swift
│   │   │   ├── AudioSoftClip.swift
│   │   │   ├── WSOLATimeCompressor.swift
│   │   │   ├── VoiceLevel.swift
│   │   │   ├── VideoMuxer.swift
│   │   │   └── TimelineAlignedRenderer.swift
│   │   ├── TextProcessing/
│   │   │   ├── TextNormalizer.swift
│   │   │   ├── TextNormalizer+Data.swift
│   │   │   ├── TextNormalizer+DomainTerms.swift
│   │   │   ├── TextNormalizer+Units.swift
│   │   │   ├── TextPreprocessor.swift
│   │   │   ├── NumberToWords.swift
│   │   │   ├── MultiTalkScriptParser.swift
│   │   │   └── SilencePreservingScriptBuilder.swift
│   │   ├── SpeakerIsolation/
│   │   │   ├── SpeakerIsolator.swift     (segment-based speaker extraction)
│   │   │   ├── MultiSpeakerRevoicer.swift
│   │   │   ├── VoiceChangerPipeline.swift
│   │   │   └── VoiceEnhancer.swift
│   │   ├── LavaSR/
│   │   │   ├── LavaSRPipeline.swift
│   │   │   ├── LavaSREnhancerBWE.swift
│   │   │   ├── LavaSRFastLRMerge.swift
│   │   │   ├── LavaSRISTFTHead.swift
│   │   │   └── LavaSRDenoiserModules.swift
│   │   └── Utilities/
│   │       └── BackoffPolicy.swift
│   ├── Audio/
│   │   ├── StreamingPlayer.swift     (AVAudioEngine source node)
│   │   ├── WAVEncoder.swift
│   │   └── AACEncoder.swift          (AVAssetWriter)
│   ├── Persistence/
│   │   ├── DataModels.swift          (SwiftData @Model types)
│   │   ├── AppDataStore.swift
│   │   └── HistoryStore.swift
│   ├── ViewModels/
│   │   ├── SingleVoiceViewModel.swift
│   │   ├── MultiTalkViewModel.swift
│   │   ├── ChatViewModel.swift
│   │   ├── HistoryViewModel.swift
│   │   ├── VoiceChangerViewModel.swift
│   │   ├── SpeakerIsolatorViewModel.swift
│   │   ├── SpeakerIsolatorViewModel+Convert.swift
│   │   ├── SpeakerIsolatorViewModel+ChangeVoices.swift
│   │   ├── SpeakerIsolatorViewModel+Exports.swift
│   │   └── SpeakerIsolatorPipeline.swift
│   ├── Views/
│   │   ├── ContentView.swift         (NavigationSplitView)
│   │   ├── SingleVoiceView.swift
│   │   ├── MultiTalkView.swift
│   │   ├── HistoryView.swift
│   │   ├── ChatView.swift
│   │   ├── VoiceChangerSheet.swift
│   │   ├── SpeakerIsolatorSheet.swift
│   │   ├── DemucsModelManagerSheet.swift
│   │   └── SpeakerIsolator/
│   │       ├── AudioPreservationSection.swift
│   │       ├── DiarizationSettingsPanel.swift
│   │       ├── SeparationProgressLabel.swift
│   │       ├── SeparationStatusBanner.swift
│   │       └── SpeakerRow.swift
│   ├── Components/
│   │   ├── VoiceSelector.swift
│   │   ├── SpeakerCard.swift
│   │   ├── OrbView.swift             (Metal orb)
│   │   ├── StatusIndicator.swift
│   │   ├── PauseModal.swift
│   │   ├── AudioPlayer.swift
│   │   ├── MiniAudioPlayer.swift
│   │   └── SynthesizeButton.swift
│   ├── Networking/
│   │   ├── LocalLLMClient.swift      (OpenAI-compatible local endpoint)
│   │   ├── ScriptGenerator.swift
│   │   └── SentenceDetector.swift
│   └── Assets.xcassets/
├── pocket-tts-macosTests/              (XCTest unit tests + fixtures + mocks)
└── pocket-tts-macosUITests/
```

---


## Voice storage — two distinct stores

This trips up every fresh session. Keep them straight:

**Bundled (stock) voices (read-only, runtime-downloaded since Phase 8):**
- Location at runtime: `~/Library/Containers/<bundle-id>/Data/Library/Application Support/pocket-tts-macos/coreml-models/installed/stock_assets-v1/voice_kv_states/*.safetensors`
- Source: published on `huggingface.co/slaughters85j/pocket-tts-stock-assets` as `stock_assets.zip`; downloaded + SHA-verified + installed by `BundledMLModelManager` alongside the four heavy mlpackages on first launch
- Type: `BundledVoice` (in `Models/BundledVoice.swift`)
- Catalog: built dynamically by `VoiceLoader.loadAll()` at engine init, via `ModelPaths.allVoiceKVStateFiles()` (manager-installed first, `Bundle.main` fallback)
- Contents: stock-only — the seven Kyutai voices (`alba`, `azelma`, `cosette`, `fantine`, `javert`, `jean`, `marius`). Nothing under `Resources/voice_kv_states/` is tracked in the repo, so custom voices physically cannot enter source.

**Saved voices (user-imported, live in the sandbox container):**
- Location: `~/Library/Containers/<bundle-id>/Data/Library/Application Support/pocket-tts-macos/saved-voices/`
- Type: `Voice` (in `Engine/VoiceManager.swift`)
- Catalog: `voices.json` in the same directory (stores basenames only; paths resolve against the current container at load)
- Files: `<UUID>.wav` + `<UUID>_codes.npy` + `<UUID>_kv.safetensors` + optional `<UUID>_enhanced.wav`
- Managed via the in-app Voice Manager (waveform icon in the header) — never touched by source code

The two stores are surfaced together in pickers but managed separately. **Voices imported via the app NEVER enter `Resources/`** — they're user data, not source. Future agents: don't try to copy custom voices into source; the architecture rejects this by design.

`VoiceManager` runs three on-boot hygiene tasks:
1. **Directory migration** from legacy `fish-voices/` → `saved-voices/` (in-place, idempotent).
2. **Reconcile with disk** — clears stale catalog rows whose files vanished.
3. **Orphan recovery** — surfaces adoptable file triplets (KV + WAV, with parseable KV header) that have no catalog row, in the Voice Manager UI.

---

## Phase 7 — Speaker Isolation Audio Preservation

Phase 7 adds optional HTDemucs source separation to Speaker Isolator so
music / SFX / ambient audio can survive underneath revoiced speech.

**Locked implementation shape:**
- Main app stays Swift / Core ML only. Do not add Python, PyInstaller, shell
  subprocess model tooling, or runtime service dependencies to the app.
- HTDemucs is downloaded as a user-managed `.mlpackage`; do not vendor the
  hundreds-of-MB model weights into the app bundle or test target.
- `DemucsSourceSeparator` runs CPU-only. GPU / ANE dispatch is known to trip
  the macOS GPU watchdog on the ISTFT graph.
- The Speaker Isolator flow is diarize-first: load 24 kHz mono, diarize,
  publish initial speakers, then optionally run source separation and replace
  the speaker rows with cleaner vocals + a separated Background row.
- Missing separator model is a soft fallback. If the user has Audio
  Preservation enabled but HTDemucs is not installed, run the v1 path and show
  a persistent warning; do not auto-download the 287 MB model during isolation.
- Background audio is represented as a synthetic `SpeakerTrack` with
  `.useOriginal` and `isolatedSamples` equal to the music / ambient stem. Do
  not add a separate `musicStem` parameter to `MultiSpeakerRevoicer`.

**Review guardrails that future agents should re-check:**
- Model readiness must validate a non-empty installed mlpackage, not just that
  the expected folder exists. Empty / partial manual placement should fall back
  or redownload instead of reaching Core ML load failure.
- Separation progress must reflect real chunk progress and ETA if the UI says
  "chunk N of M". A static `chunk 1 of 1` placeholder is not acceptable for
  multi-minute separations.
- "Manage Separation Models..." must remain reachable after the model is
  installed so users can delete it, reveal the folder, or manually place an
  mlpackage from another machine.

---

## Conventions

### Swift code style (from `~/.Codex/AGENTS.md`)

- Use `// MARK:` for every class, struct, extension, and meaningful function group
- Don't delete comments; you may update them
- Modern UI elements only — sane defaults from SwiftUI, no AppKit hacks unless required
- Files over **300 lines** → refactor (move helpers into extensions or sibling files)
- **macOS + iOS portable** when possible; `#if os(iOS)` for UI deltas. Engine layer must stay pure (no UI imports).
- Use Swift Concurrency (`async/await`, `AsyncStream`) — not GCD — except where AVAudioEngine taps require callbacks

### Testing

- **XCTest for both unit and UI tests.** Do *not* adopt Swift Testing (the new `@Test`/`#expect` macro framework) — even though Xcode 16 scaffolds it by default, we standardize on XCTest for consistency with the existing `macos-service/PocketTTSMenuBar` codebase and to keep one mental model across the project.
- Unit tests live in `pocket-tts-macosTests/`, UI tests in `pocket-tts-macosUITests/`
- If Xcode generated `pocket_tts_macosTests.swift` using Swift Testing (`import Testing`, `@Test` funcs), **rewrite it to XCTest** (`import XCTest`, `final class … : XCTestCase`, `func testFoo()`) on first touch
- Engine-layer tests (`TTSEngine`, `Tokenizer`, `VoiceLoader`) belong in unit tests; visible-flow tests (text → audio plays) belong in UI tests

### SwiftData persistence

Strict 10-step pattern from `~/.Codex/AGENTS.md`:

1. Separate `@Model` types (persistence) from view models (`ObservableObject` with `@Published`)
2. View models expose computed `get`/`set` properties as UI bindings
3. **Debounced saves** — 1-second `scheduleSave()` timer, not save-per-keystroke
4. View model takes `ModelContext` via `setModelContext(_:)` on view `.onAppear`
5. Centralized `DataModels.swift` for all `@Model` types
6. Load via `ModelContext` query in view model init; create defaults if missing
7. `didSet` on `@Published` props → `scheduleSave()`
8. `saveChanges()` copies view-model state back to `@Model` then `try modelContext.save()`
9. Views own `@StateObject` parent VM; pass to children as `@ObservedObject`
10. Views never touch `ModelContext` or `@Model` types directly — only via the view model

### Brand tokens

This is **not** a Ubiquitous Analytics project. The UA brand-token rule does not apply. Design language is open — pull cues from the existing Electron app's aesthetic, then formalize once we have v1 shape.

### Coding workflow

- **Refactor over add.** Reuse existing types in this repo before writing new code from scratch
- No mocking in dev/prod code. Mocks live in `pocket-tts-macosTests/` only
- Don't introduce a new pattern or library to "fix" something — first exhaust the existing pattern, then propose replacement
- Don't make changes unrelated to the task at hand
- Keep an eye on impact across `Engine/`, `Audio/`, and `Views/` whenever the public API of `TTSEngine` shifts
