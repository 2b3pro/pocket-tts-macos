# Headless pocket-tts (CLI → streaming daemon)

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
| **P3** | Persistent HTTP streaming daemon (inference-only, MLX-free) | ✅ done | `headless-daemon` |
| **P4** | VoiceServer `pocket.ts` `generateStream()` + re-bake personas | ⬜ todo | — |

Verified perf (release, M2 Ultra, warm, vs `/Applications` app assets):
**~0.26s first-audio, ~30 fps, 2.4× realtime.** Headless bake is byte-format
identical to the app's Voice Manager bake (12 tensors `kv_k/kv_v_0..5`,
`[1,512,16,64]` F16; verified on matias, `T_voice=188`).

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

## Loudness model

Two levers. **Bake-time** `--rms-db` sets the conditioning level baked into the
clone (default −16 dB = app/Python parity). **Output-time** `say --rms-db` is the
council-consistency lever — normalizes finished audio so every advisor sits at
the same level regardless of how its clone was made. Council standard:
`tts.targetRmsDb: -20` in AdvisoriumPAI `advisorium.yaml` (consumed by the P4
daemon path; the `say --rms-db` mechanism is already proven).

Internal constants not yet exposed: bake 15s reference cap, EOS smoothing
(`eosLogitThreshold -4.0`, 3 consecutive frames).

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

- **P4 — VoiceServer:** `Infrastructure/VoiceServer/engines/pocket.ts` gets
  `generateStream()` talking to the daemon (POST `/generate`, read `resp.body` as
  a PCM stream, `X-Sample-Rate` header — same shape as `mlx.ts`
  `generateStreamViaServer`); re-bake the 6 persona clones from
  `AdvisoriumPAI/voices/*.wav` into the daemon's resources dir at conditioning
  −20; council turns POST `stream:false` + `targetRmsDb` from `advisorium.yaml`;
  Python `pocket-tts serve` stays as fallback.
- **Verify app still builds in Xcode** after the shared-file edits (additive, but
  not yet re-confirmed via `xcodebuild`).
- Decide how to ship the metallib for distribution (vs copy-from-app).
- **Daemon lifecycle** for P4: a start/stop/health-restart wrapper (mirror
  `mlx.ts`'s `startMlxServer`/`ensureServerOrRestart` PID-file pattern) so
  VoiceServer can bring the daemon up on demand and survive crashes.

## Related (PAI side)

PAI memory: `project_pocket_coreml_daemon`, `bug_pocket_v1v2_truncation`.
