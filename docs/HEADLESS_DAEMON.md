# Headless pocket-tts (CLI → streaming daemon)

> **Re-baseline note (2026-06-07):** upstream rebranded `pocket-tts-macos` →
> `mimika-ai-voice-studio` and reorganized the engine. The daemon was re-baselined
> onto it as branch **`headless-daemon-mimika`**. Source layout now: core TTS in
> `mimika-ai-voice-studio/Engine/TTS/`, audio helpers in `Engine/Audio/`, WAV
> encoder in `Audio/`, text processing in `Engine/TextProcessing/` — see
> `Package.swift` for the exact linked set. The daemon ships its own
> `headless/ModelPaths.swift` (env-override) because upstream's Phase 8 ModelPaths
> is coupled to `BundledMLModelManager` (runtime download), which the lean build
> won't link. Build also needs `Package(defaultLocalization: "en")` (the rebrand
> added localized resources under the repo root) and links
> `Engine/Audio/AudioBuffer.swift` (new `WAVEncoder.write(audioBuffer:)` overload).
> Full provenance: [`UPSTREAM.md`](UPSTREAM.md).
>
> **Deferred (2026-06-07):** the re-baseline pulled in
> `TextNormalizer.stripWhisperArtifacts` (strips `[silence]`/`[music]`/`>>` etc.)
> but it is NOT wired into the synth path — dormant. Not needed while the daemon's
> only input is clean VoiceServer persona text. Wire it into `TTSEngine`'s
> normalize step only if the daemon is ever fed transcription/caption text.

Status doc for the `headless-daemon` branch. Goal: run the app's **Core ML**
pocket-tts engine with no GUI, so PAI's VoiceServer can drive low-latency,
**streaming** TTS for cloned persona voices — replacing the slow, buffered
Python `pocket-tts serve` path.

> **MLX is not the fast path.** The latency win is Core ML (the 100M pocket
> model). MLX in this repo is only the 5B Fish S2 Pro backend (~20–45s/segment)
> and the MimiEncoder used at *bake* time. The inference daemon is Core ML only.

## Why

| Path | First-audio | Streaming? | Runtime |
|------|------------:|------------|---------|
| PAI today (`pocket-tts serve`, Python) | ~0.4s **then wait for full WAV** | ❌ buffered | Python/PyTorch |
| This (Core ML, headless) | **~0.26s, frames as produced** | ✅ | native Swift, no Python |

Perceived latency drops from "wait for the whole clip" (scales with text length)
to a flat ~0.26s start, regardless of length.

## Phase status

| Phase | What | State | Commit |
|-------|------|-------|--------|
| **P1** | `pockettts say` — headless Core ML synth → WAV | ✅ done | `a9208e6` |
| **P2** | `pockettts bake` — WAV → KV-state clone (MLX) | ✅ done | `e3ecb4d` |
| **P2.5** | Expose synth knobs + bake/output loudness controls | ✅ done | `8bb9149` |
| **P3** | Persistent HTTP streaming daemon (inference-only, MLX-free) | ✅ done | `b2a4eb0` |
| **P4** | Re-bake all bakeable persona clones (73) | ✅ done | (batch, PAI side) |
| **P4d** | VoiceServer `pocket.ts` → daemon + lifecycle + council leveling | ✅ done | PAI `4f8d40d` `891bb50` `a4b75a9` |

Verified perf (release, M2 Ultra, warm, vs `/Applications` app assets):
**~0.26s first-audio, ~30 fps, 2.4× realtime.** Headless bake is byte-format
identical to the app's Voice Manager bake (12 tensors `kv_k/kv_v_0..5`,
`[1,512,16,64]` F16; verified on matias, `T_voice=188`). P4d end-to-end through
VoiceServer: nova streams from its baked clone at ~0.55s first-audio (full Node
→ daemon → synth stack); buffered council generate normalizes to −20.00 dBFS.

## Architecture

- `Package.swift` (repo root) defines one executable target, `path: "."`, with an
  **explicit `sources:` list** of the app's UI-free `Engine/` + `Audio/` files.
  Coexists with `pocket-tts-macos.xcodeproj` — `swift build` uses the manifest,
  Xcode keeps using the project. Files not listed (Views, Fish, Whisper,
  StreamingPlayer, VoiceEnhancer…) are simply not compiled.
- `headless/main.swift` — the CLI (`say` / `bake`).
- Assets are supplied at runtime via **`POCKET_TTS_RESOURCES`** (a dir with the
  `.mlmodelc` models, tokenizer, voice KV safetensors). `ModelPaths` resolves
  this dir *before* `Bundle.main`; when the env var is unset the app behaves
  exactly as before. Point it at any installed app's `Contents/Resources`.
- Concurrency: `Package.swift` matches the app's build settings
  (`.defaultIsolation(MainActor.self)` + `NonisolatedNonsendingByDefault`,
  swift-tools 6.2) so the shared `Engine/` sources compile **unforked**.

Source edits to shared files (all additive / behavior-preserving for the app):
`ModelPaths.swift` (env override + `resource()`/`tokenizerVocab()`),
`SentencePieceTokenizer.swift` (vocab via ModelPaths), `MimiEncoder.swift` +
`PocketTTSVoiceEncoder.swift` (assets via ModelPaths; phase prediction moved to a
nonisolated sync helper), and `Voice.swift` (extracted `Voice`/`OrphanedVoice`
models out of `VoiceManager.swift` so the engine layer needn't import its
AVFoundation).

## Build & run

```bash
# Build — RELEASE IS MANDATORY (debug is ~4x slower in the AR loop:
# 6.7s first-audio / 9 fps debug  vs  0.26s / 30 fps release).
swift build -c release

# MLX metallib (bake path only): SwiftPM does NOT emit default.metallib.
# Copy it from the installed app once per build dir:
cp -R /Applications/pocket-tts-macos.app/Contents/Resources/mlx-swift_Cmlx.bundle .build/release/

RES=/Applications/pocket-tts-macos.app/Contents/Resources

# Synthesize (built-in or pre-baked voice in $RES)
.build/release/pockettts say --voice marius --resources "$RES" \
  --text "Hello." --out /tmp/out.wav

# Bake a clone from a reference WAV
.build/release/pockettts bake --wav ref.wav --out voice_kv.safetensors --resources "$RES"

# Run the persistent streaming daemon (inference-only — no metallib needed)
.build/release/pockettts serve --port 8891 --resources "$RES"
```

To synthesize with a freshly baked clone, drop it into a resources dir
(symlink the app's models + your `<name>.safetensors`) and `say --voice <name>`.
The daemon loads voices into memory once at startup, so a newly-added clone
needs a daemon restart to become available.

## Daemon (P3) — HTTP contract

`pockettts serve` keeps the engine resident (init ~2.2s cold, then warm) and
serves a contract that mirrors PAI's `mlx-server.py` so VoiceServer's engine
client treats it identically. Default port **8891** (8888 voice / 8889 mlx /
8890 Python pocket / **8891 Core ML pocket daemon**). Loopback-bound,
unauthenticated, one request at a time (a `GenerationGate` serializes synthesis
— Core ML AR state is per-call, but we don't risk concurrent prediction).

| Route | Method | Returns |
|-------|--------|---------|
| `/health` | GET | JSON `{status, engine, pid, uptime_ms, generations_served, sample_rate}` |
| `/generate` | POST | 16-bit LE mono PCM (see below) |
| `/shutdown` | POST | `{ok:true}`, then `exit(0)` |

`/generate` request body (JSON):

```jsonc
{ "text": "…",                    // required
  "voice": "matias",              // built-in | clone basename | imported:UUID | <path>.safetensors
  "stream": true,                 // false → buffer + normalize
  "targetRmsDb": -20,             // output RMS target — buffered mode only
  "temperature": 0.7, "chunkTokenBudget": 50,
  "noiseClamp": 1.5, "maxFrames": 256, "framesAfterEos": 8,
  "request_id": "…" }
```

Response headers (both modes): `Content-Type: audio/l16; rate=24000; channels=1`,
`X-Sample-Rate`, `X-Channels`, `X-Bits-Per-Sample`, `X-Estimated-Duration-Ms`,
`X-RMS-Mode`, plus `X-Request-Id` / `X-Voice-Fallback` when applicable. Unknown
non-built-in voices fall back to `marius` with `X-Voice-Fallback: default`.

**Two response modes (the streaming/RMS resolution):**

- `stream:true` (default) — `Transfer-Encoding: chunked`; each 80 ms PCM frame is
  flushed to the socket as the AR loop produces it. `X-RMS-Mode:
  stream-passthrough` — `targetRmsDb` is ignored (RMS over a partial signal is
  meaningless). This is the **solo** path (`advisorium.yaml streamSolo:true`):
  single voice, lowest first-audio latency, no cross-leveling needed.
- `stream:false` — buffers the whole utterance, optionally normalizes to
  `targetRmsDb`, sends with `Content-Length`. `X-RMS-Mode: full-normalized` (or
  `buffered`). This is the **council** path (`streamCouncil:false`) where
  cross-voice loudness leveling matters more than first-audio latency.

Normalization is peak-guarded: a buffer whose crest factor would clip at the
target lands a little under it (e.g. target −20 → −21.8 dBFS at 0 dBFS peak)
rather than clipping. Verified live: marius streaming −32.8 dBFS passthrough vs
buffered −21.8 dBFS at target −20.

## CLI reference

`say` — `--voice`, `--text`, `--out`, `--resources`
- `--temperature <f>` (default 0.7) — expressiveness vs stability
- `--chunk-budget <15-50>` (default 50) — smaller = less AR drift on long text
- `--noise-clamp <f>` — truncate sampling noise (rein in instability)
- `--max-frames <int>` (default 256)
- `--rms-db <target>` — normalize **output** loudness to this dBFS RMS (peak-guarded)

`bake` — `--wav`, `--out`, `--resources`
- `--rms-db <target>` (default −16) — **conditioning** RMS baked into the clone

`serve` — `--port <int>` (default 8891), `--resources <dir>`
- Persistent streaming daemon. See "Daemon (P3) — HTTP contract" above. The full
  synth knob set + `targetRmsDb` are per-request JSON fields, not CLI flags.

`--version` — print build provenance and exit: `pockettts <tag> (<sha>[-dirty] · <branch> · built <iso8601>)`.
- A bare `swift build` reports `dev (unknown-dirty · unknown · built dev)`. Only a
  build through `scripts/deploy-daemon.sh` carries a real git SHA (see Versioning below).

## Loudness model

Two levers. **Bake-time** `--rms-db` sets the conditioning level baked into the
clone (default −16 dB = app/Python parity). All 73 PAI clones were baked at this
**−16 default** (the matias-validated level), *not* −20 — conditioning is a
per-clone character setting, and conflating it with loudness leveling would be an
unvalidated change to every voice. **Output-time** is the council-consistency
lever: the daemon's `stream:false` mode normalizes finished audio to
`targetRmsDb` so every advisor sits at the same level regardless of how its clone
was made. Council standard: `tts.targetRmsDb: -20` in AdvisoriumPAI
`advisorium.yaml`, sent per-request via the VoiceServer `/notify` `target_rms_db`
field → daemon. Verified end-to-end at −20.00 dBFS.

Internal constants not yet exposed: bake 15s reference cap, EOS smoothing
(`eosLogitThreshold -4.0`, 3 consecutive frames).

## Versioning & deploy

The binary stamps its own provenance so we can answer "is the latest running?"
without guessing from file mtimes.

- **`headless/BuildInfo.swift`** — committed with placeholder defaults (a bare
  `swift build` ⇒ `dev / unknown`). `scripts/deploy-daemon.sh` rewrites it with the
  real git SHA / branch / dirty flag / ISO timestamp just before a **release**
  build, then restores it from a backup copy (so the working tree stays clean).
- **`pockettts --version`** prints the one-line stamp; **`GET /health`** returns
  `version`, `git_sha`, `branch`, `dirty`, `built_at` alongside the runtime fields.
- **`scripts/deploy-daemon.sh [tag] [--restart]`** — stamp → `swift build -c release`
  (into `/tmp` scratch to dodge the dual-mount ModuleCache collision) → atomic
  install (`temp + mv`, so replacing a *running* binary never hits "Text file busy")
  into `~/Library/Application Support/pai/pocket-coreml-bin/`. Without `--restart`
  the live process keeps running on its old inode until restarted; `--restart`
  posts `/shutdown` and relies on the supervisor (VoiceServer/`start.sh`) to respawn.
  Override the target with `POCKETTTS_BIN_DIR=` (used for dry runs).
- **`scripts/check-daemon-version.sh [port]`** — curls `/health`, compares `git_sha`
  to `git rev-parse --short HEAD`; prints `✓ current` (exit 0) / `✗ STALE` (exit 1) /
  not reachable (exit 2). This supersedes the old mtime-based "refresh when newer"
  heuristic — `start.sh` can keep copying, but provenance is now verifiable.

> A daemon built before this landed reports no version fields on `/health`; treat a
> missing `git_sha` as "stale, pre-versioning — redeploy."

## PAI integration (P4 / P4d)

How the daemon is actually deployed in PAI (lives in the `pai` repo, not here):

- **Stable binary install** — the release binary is self-contained (MLX is
  statically linked; `otool -L` shows only system frameworks, no `@rpath`/`.build`
  deps), so it relocates cleanly off the build volume. It's installed to
  `~/Library/Application Support/pai/pocket-coreml-bin/pockettts` (+ the
  `mlx-swift_Cmlx.bundle` metallib alongside, so `bake` works there too — `serve`
  doesn't need it). `start.sh` refreshes it from this build dir when newer.
- **Daemon resources dir** — `~/Library/Application Support/pai/pocket-coreml-res/`:
  symlinks to the app's `.mlmodelc` models + tokenizer + stock voices, plus **73
  baked clone KV safetensors** (every persona with a `*sample*` source WAV;
  conditioning −16). The daemon runs `serve --resources <that dir>`; it loads all
  voices at startup (~4–5s cold with the full set), so a newly-baked clone needs a
  daemon restart.
- **VoiceServer routing** (`Infrastructure/VoiceServer/engines/pocket.ts`) — the
  `pocket` engine prefers the daemon and keeps the Python `pocket-tts` path as
  fallback. `generateStream()` streams from the daemon for baked voices (else
  throws → queue falls back); `generate()` collects daemon PCM→WAV (buffered,
  `stream:false`, honors `targetRmsDb`); `ensureRunning()` lazy-starts the daemon
  (PID file + crash-window cap + health poll). `start.sh` also eager-starts it.
  Voices resolve **by basename** — a config value of `nova.safetensors` (or any
  path) → token `nova` → the daemon's baked Core ML clone. `X-Voice-Fallback` is
  treated as a miss so the Python path (which still has the original
  `export-voice` clone) is used. **Result: no clone files were replaced in place —
  the old Python `.safetensors` stay as fallback; the daemon serves its own Core
  ML copies under matching basenames.**
- **Persona creation** — `AdvisoriumPAI/workflows/persona-creator-flow.md` now
  bakes a Core ML KV clone (`pockettts bake` → daemon resources dir, basename
  matching the config) so new advisors are daemon-visible; the Python
  `export-voice` clone is kept as an optional fallback.

## Gotchas / lessons

1. **Release-only.** Debug cripples the allocation-heavy AR loop ~4×.
2. **MLX metallib** must sit next to the binary for `bake`; copy `mlx-swift_Cmlx.bundle`
   from the app. The **daemon (P3) is inference-only Core ML → needs no metallib.**
3. **Concurrency settings must match the app** or shared sources won't compile
   under Swift 6 strict concurrency.
4. **v1/v2 model mismatch:** the existing PAI Python clones are v1-era; the
   production `pocket-tts serve` defaults to `english_2026-04` which *truncates*
   them. Core ML re-bakes sidestep this (separate latent bug — see PAI memory
   `bug_pocket_v1v2_truncation`).
5. Existing Python `export-voice` `.safetensors` are **not** loadable by Core ML
   (different format: `transformer.layers.*` vs `kv_k/kv_v_*`). Clones must be
   re-baked from source WAVs.

## Remaining work

- **Council leveling — caller side:** AdvisoriumPAI council turns must actually
  *send* `target_rms_db` (from `advisorium.yaml tts.targetRmsDb`) in their
  VoiceServer `/notify` payload. The VoiceServer is wired to honor it end-to-end,
  but the council caller doesn't pass it yet.
- **Re-bake the rest:** 4 recoverable clones (sources exist but aren't named
  `*sample*` — `ian.wav`, `monologue.wav`/rousseau, `dalio-voice.wav`, and the
  misspelled `jordanpederson-sample.wav`) and 6 with no source audio yet
  (ingo-swann, anne-applebaum, elias-aguilar, giordano-bruno, isaac-luria,
  edgar-cayce). Bake into the daemon resources dir once sources are ready.
- **Verify app still builds in Xcode** after the shared-file edits (additive, but
  not yet re-confirmed via `xcodebuild`).
- Decide how to ship the metallib for distribution (vs copy-from-app / the
  install-alongside approach PAI uses).

## Related (PAI side)

PAI memory: `project_pocket_coreml_daemon`, `bug_pocket_v1v2_truncation`.
