# CLAUDE.md

Single-shot context for any Claude Code session working in this repo. Read first.

> **Note:** This file is intentionally checked in (no symlink trick) so the project is self-contained for fresh sessions.

> **Headless build:** there's a `swift build` CLI/daemon track (branch `headless-daemon`)
> that links the UI-free `Engine/` + `Audio/` sources to run the Core ML engine without
> the GUI — for PAI's VoiceServer. See [`docs/HEADLESS_DAEMON.md`](docs/HEADLESS_DAEMON.md).

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

Full conversion details in `pocket-tts-core-ml-conversion/NOTES.md`.

---

## Project layout (target — being built out)

```
pocket-tts-macos/
├── CLAUDE.md                          ← this file
├── pocket-tts-macos.xcodeproj/
├── pocket-tts-macos/
│   ├── road-map.md
│   ├── App/
│   │   └── PocketTTSMacOSApp.swift   (@main, rename from default template)
│   ├── Engine/
│   │   ├── TTSEngine.swift           (orchestrator)
│   │   ├── Tokenizer.swift           (SentencePiece wrapper)
│   │   ├── VoiceLoader.swift         (safetensors → MLMultiArray)
│   │   ├── VoiceManager.swift        (saved-voices/ catalog + import + orphan recovery)
│   │   ├── BundledVoice.swift        (Models/) — stock voice catalog entry
│   │   └── ModelPaths.swift          (bundle-resource resolution)
│   ├── Audio/
│   │   ├── StreamingPlayer.swift     (AVAudioEngine source node)
│   │   ├── WAVEncoder.swift
│   │   └── AACMP3Encoder.swift       (AVAssetWriter)
│   ├── Persistence/
│   │   └── DataModels.swift          (SwiftData @Model types — Phase 3)
│   ├── ViewModels/                    (Phase 2+)
│   ├── Views/
│   │   ├── ContentView.swift         (NavigationSplitView)
│   │   ├── SingleVoiceView.swift
│   │   ├── MultiTalkView.swift       (Phase 3)
│   │   ├── HistoryView.swift         (Phase 3)
│   │   └── ChatView.swift            (Phase 4)
│   ├── Components/
│   │   ├── VoiceSelector.swift
│   │   ├── SpeakerCard.swift
│   │   ├── Orb.swift                 (Phase 5)
│   │   ├── StatusIndicator.swift
│   │   ├── PauseModal.swift
│   │   ├── AudioPlayer.swift
│   │   └── SynthesizeButton.swift
│   ├── Networking/
│   │   └── LocalLLMClient.swift      (OpenAI-compatible: LM Studio, Ollama, llama.cpp server, etc.)
│   ├── Resources/                     (bundled assets — synced via scripts/sync-assets.sh)
│   │   ├── mlpackages/
│   │   │   ├── prompt_phase.mlpackage
│   │   │   ├── calm_stateful.mlpackage      (fp32 compute)
│   │   │   ├── mimi_stateful.mlpackage      (fp32 compute, 8192-slot KV cache)
│   │   │   └── voice_prompt_phase.mlpackage (voice-import baker)
│   │   ├── tokenizer.model
│   │   ├── tokenizer_vocab.json
│   │   └── voice_kv_states/*.safetensors    (stock-only; the 7 Kyutai voices)
│   └── Assets.xcassets/
├── pocket-tts-macosTests/
└── pocket-tts-macosUITests/
```

---


## Voice storage — two distinct stores

This trips up every fresh session. Keep them straight:

**Bundled voices (read-only, ship with the app):**
- Location: `pocket-tts-macos/Resources/voice_kv_states/*.safetensors` in source → `.app/Contents/Resources/*.safetensors` in the build
- Type: `BundledVoice` (in `Models/BundledVoice.swift`)
- Catalog: built dynamically by `VoiceLoader.loadAll()` at engine init
- Contents: stock-only — the seven Kyutai voices (`alba`, `azelma`, `cosette`, `fantine`, `javert`, `jean`, `marius`). `sync-assets.sh` is filtered to enforce this.

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

## Conventions

### Swift code style (from `~/.claude/CLAUDE.md`)

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

Strict 10-step pattern from `~/.claude/CLAUDE.md`:

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

- **Refactor over add.** Reuse existing types; check `pocket-tts-core-ml-conversion/swift_harness/` and `macos-service/PocketTTSMenuBar/` before writing new code from scratch
- No mocking in dev/prod code. Mocks live in `pocket-tts-macosTests/` only
- Don't introduce a new pattern or library to "fix" something — first exhaust the existing pattern, then propose replacement
- Don't make changes unrelated to the task at hand
- Keep an eye on impact across `Engine/`, `Audio/`, and `Views/` whenever the public API of `TTSEngine` shifts

---

## Hard rules — do NOT

- ❌ Modify anything under `/Users/system-backup/dev_local/pocket-tts/` (read-only reference)
- ❌ Modify anything under `/Users/system-backup/dev_local/pocket-tts-core-ml-conversion/` except for generating new `.mlpackage`s and validators
- ❌ Re-download model weights — they're already in `~/.cache/huggingface/hub/`
- ❌ Add a Python runtime / PyInstaller / `subprocess` to this app — the whole point is to escape Python
- ❌ Bundle `calm_step.mlpackage` or `mimi_decoder.mlpackage` (dev artifacts only)
- ❌ Hardcode bundle paths — use `Bundle.main.url(forResource:withExtension:)` via `ModelPaths.swift`
- ❌ Add CoreData (we use SwiftData)
- ❌ Touch `Item.swift` from the Xcode default template — delete it once `DataModels.swift` lands

---

## Decisions locked

| Question | Answer |
|----------|--------|
| Fresh project vs extend menu bar | **Fresh** (this repo). Menu bar (`macos-service/`) stays separate. |
| Python backend fallback | **No.** Core ML only. |
| Voice cloning in v1 | **Yes** (shipped in v1.0). Via the in-app Voice Manager → saved-voices/ container. |
| ChatLLM backend | **Local LLM Endpoint** — generic OpenAI-compatible HTTP (LM Studio, Ollama, llama.cpp server, vLLM, LocalAI). Base URL persisted in SwiftData; default `http://localhost:1234/v1`. |
| iOS in v1 | **No.** Possibly v2 after macOS stabilizes. |
| Default voice | TBD — caller's choice. Plan to default to `cosette` until UI persists last-used. |
| Audio export formats | **WAV + AAC + MP3** |

---

## Phase tracking

See `pocket-tts-macos/road-map.md` for the canonical phased plan with hour estimates.

Quick status:

- [x] Phase −1: project bootstrap (Xcode project, git, GitHub remote, road-map, CLAUDE.md)
- [x] Phase 0a — voice KV state precompute: 7 voices exported to `/Users/system-backup/dev_local/pocket-tts-core-ml-conversion/voice_kv_states/*.safetensors` (T_voice 125–161 per voice)
- [x] Phase 0b — `prompt_phase.mlpackage` converted, 140 MB, validated against PyTorch at 1.84% worst K rel-err (passing 5% threshold). Notable: ANE compile rejects multi-position SDPA; runs CPU+GPU
- [x] Phase 0c — Swift engine: Tokenizer, VoiceLoader, TTSEngine + Xcode project scaffolding
- [x] Phase 0d — end-to-end Swift unit test (text → wav, no Python)
- [x] Phase 1: streaming audio (StreamingPlayer, WAVEncoder, AAC/MP3 encoder)
- [x] Phase 2: MVP SwiftUI shell (single-voice mode → v0.1 shippable)
- [x] Phase 3: MultiTalk + History (SwiftData)
- [x] Phase 4: LM Studio chat
- [x] Phase 5: Orb (Metal shader port)
- [ ] Phase 6: polish, signing, notarization, Sparkle, DMG
- [ ] Deferred v2: voice cloning, EnhancementStudio, AudioCompare, iOS variant
