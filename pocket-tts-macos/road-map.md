# Pocket TTS macOS — Roadmap

## Project bootstrapping (Phase -1, ~30 min)

- Create Xcode project: macOS app target, SwiftUI lifecycle, Swift 6, min deployment macOS 15 (Core ML stateful requirement)
- Add `pocket-tts-macosTests` target
- SPM deps:
  - `apple/swift-tokenizers` (has SentencePiece)
  - `sparkle-project/Sparkle` (later, for updates)
- **Asset bundling:** drop `mimi_stateful.mlpackage`, `calm_stateful.mlpackage`, `prompt_phase.mlpackage` (Phase 0 output), `tokenizer.model`, and the `embeddings/*.safetensors` into the bundle. ~250 MB final app size, acceptable.
- **Files to port** from `macos-service/PocketTTSMenuBar/Sources/PocketTTSMenuBar/Models/`:
  - `Voice.swift`, `Config.swift` (adapt namespaces; share config dir at `~/Library/Application Support/pocket-tts-electron/` so history migrates)
- **Files NOT to port:** `ServerManager.swift` (no Python), `ConfigManager.swift` (rewrite around SwiftData)

## Phase 5 — Orb (~4–8 hrs, scope-dependent)

- Read `electron/src/renderer/components/Orb.tsx` first — it's a Gemini fractal-orb shader (recent commits)
- Port WebGL/GLSL → Metal MSL, wrap in `MTKView`-backed SwiftUI representable
- Audio-amplitude tap from `AVAudioEngine.mainMixerNode.installTap`
- **Risk:** shader complexity is the unknown — could finish in an afternoon or eat a full day

---

## Phase 6 — Polish & ship (~6–8 hrs)

- Settings pane (voice defaults, LM Studio config, output dir)
- Sparkle auto-update + DMG packaging
- Optional: subsume `macos-service` menu bar (or leave standalone)

---

## Deferred to v2 (~1 full session each)

| Item | Notes |
|------|--------|
| **Voice cloning** | Convert speaker encoder, port `ReferenceAudio` + `SaveVoiceModal`, integrate gated checkpoint. The conversion work is the long pole, ~6–10 hrs |
| **Enhancement Studio + AudioCompare** | Depends on what `voice-enhancer.ts` actually does; need to read it first |
| **iOS variant** | Only after macOS is stable; mostly UI adjustments + `#if os(iOS)` guards since the engine layer is platform-agnostic |
