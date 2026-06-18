# Upstream provenance & update watch

How this fork relates to its upstreams, which ones to watch for updates, and
where the blind spots are. The short version: **"pocket-tts" and "Mimi" reach
us through different paths, with John Saunders (`slaughters85j`) as the human
bottleneck between us and Kyutai.** Watch the macOS app repo closely; treat
Kyutai itself as a low-frequency, lagging signal.

> Status snapshot (2026-06-07): **re-baselined onto the Mimika rebrand.** Upstream
> landed 80 commits on top of our old base `134d9f8` — John renamed the whole repo
> `pocket-tts-macos` → **`mimika-ai-voice-studio`** ("Mimika – AI Voice Studio",
> v1.5.x, Mac App Store) and added Phases 7–10 (Speaker Isolation, Voice Changer,
> LavaSR enhancement, Demucs/FluidAudio) + Phase 8 runtime model-download. The
> headless daemon was re-baselined as branch `headless-daemon-mimika` off
> `origin/main` (`bd7b90c`): source paths repointed to `Engine/{TTS,Audio}` +
> `Audio/`; the `MimiEncoder`/`SentencePieceTokenizer` edits were dropped (upstream
> now routes those through `ModelPaths` itself); the encoder loudness knob + `Voice`
> extraction were replayed; and the daemon got its own `headless/ModelPaths.swift`
> (env-override — the app's ModelPaths is now coupled to `BundledMLModelManager`,
> which the lean build won't link). `swift build` green; `say` + `serve /health`
> smoke-tested. Conversion repo still **404 / private**, but the source model +
> public `pocket_tts` package are on disk, so most of John's weight work is
> reproducible (see "Can we reproduce John's weight work?" below).
>
> **Update (2026-06-18):** upstream has since landed **48 more commits** on
> `mimika-ai-voice-studio/main` (through v1.5.4) — but they are **entirely GUI/feature
> work**: Ensemble Mode (multi-speaker, multi-LLM voiced conversations), the native
> Menu Bar + Read-Aloud quick action, and release prep. **None of it is linked by the
> headless daemon.** Exactly one commit in that gap touches a daemon source: `30b648a`
> (misleadingly titled "Ensemble: pin user-typed cast names") adds **year
> normalization** to `TextNormalizer.swift` — "1999" → "nineteen ninety-nine", "2024" →
> "twenty twenty-four", "2000" → "two thousand", "2005" → "twenty oh five". That hunk
> has been **cherry-picked onto `headless-daemon-mimika`** (this commit). No Core ML
> model rebuilds, precision fixes, or `MimiEncoder` changes in the gap. Conversion repo
> still **404 / private** (re-checked 2026-06-18). Recommendation: do **not** merge the
> rest of the gap — it is pure GUI surface area that would only add conflict noise to
> the daemon track.
>
> **Name collision:** upstream's "Mimika" is John Saunders' rebrand of
> pocket-tts-macos — a macOS GUI TTS app. It is **unrelated** to the separate PAI
> **"MimikaStudio"** voice project (Kokoro/MLX telephony clone,
> `VoiceServer/engines/mimika.ts`). Same name, different lineage; don't conflate them.
>
> Status snapshot (2026-05-22, pre-Mimika): this fork was **0 commits behind**
> `slaughters85j/pocket-tts-macos`. The conversion repo is **404 / private** — but
> the source model + public `pocket_tts` package are on disk, so most of John's
> weight work is reproducible (see "Can we reproduce John's weight work?" below).

## Dependency chain

```
Kyutai (research lab)
 ├─ Mimi codec ───────────┐   kyutai-labs/moshi  +  huggingface.co/kyutai
 └─ pocket-tts model ─────┤
                          ▼
slaughters85j (John Saunders) — the conversion + porting layer
 ├─ pocket-tts ...................... original Python/Electron reference   [public]
 ├─ pocket-tts-core-ml-conversion ... PyTorch→CoreML scripts + MimiEncoder weights  [PRIVATE / 404]
 ├─ mlx-audio-swift (fork) .......... Fish S2 Pro codec + refCodes path    [public]
 └─ pocket-tts-macos ................ the native macOS app  ← OUR UPSTREAM  [public]
                          ▼
2b3pro/pocket-tts-macos (this fork)
 └─ headless-daemon branch .......... the streaming Core ML daemon PAI consumes
```

Two distinct artifacts flow down this chain, and they are **not the same upstream**:

- **Mimi** — Kyutai's neural audio codec (part of Moshi). Used here *only at bake
  time*: the `MimiEncoder.swift` (a hand-written MLX port, 18M params) turns a
  reference WAV into the `[1, T_voice, 1024]` voice-conditioning tensor stored in
  each `*_kv.safetensors`. Its weights are `mimi_encoder_weights.safetensors`.
- **pocket-tts model** (~100M) — Kyutai's TTS model, converted to the three Core
  ML `.mlpackage` artifacts (`calm_stateful`, `prompt_phase`, `mimi_stateful`)
  that the inference daemon actually runs.

## Repo accessibility (verified 2026-05-22)

| Repo | Status | Role |
|------|--------|------|
| `slaughters85j/pocket-tts-macos` | **public** | Our direct upstream / merge point |
| `kyutai-labs/moshi` | **public** | True source of the Mimi codec |
| `huggingface.co/kyutai` | public | Kyutai model + codec checkpoints |
| `slaughters85j/pocket-tts` | public | Original Python/Electron reference app |
| `slaughters85j/mlx-audio-swift` | public | Fish S2 Pro codec fork (not pocket-tts) |
| `slaughters85j/pocket-tts-core-ml-conversion` | **404 / private** | Where checkpoints become `.mlpackage` + MimiEncoder weights |

## Watch list (priority order)

### ① `slaughters85j/pocket-tts-macos` — watch closely
Our direct upstream and merge point. **GitHub → Watch → "Releases and commits."**
Everything that matters lands here first: Core ML model rebuilds, MimiEncoder
Swift-port changes, precision fixes (e.g. the fp32 re-conversion that killed the
Mimi K/V buffer overflow + autoregressive drift), and streaming-engine work. If a
Kyutai/Mimi improvement ever becomes consumable for us, it becomes consumable
**here**. This covers ~90% of our real exposure.

### ② Kyutai direct — `kyutai-labs/moshi` + `huggingface.co/kyutai`
The *true* source of Mimi and the pocket-tts model, but the **slowest** to reach
us: a change here does nothing until John re-converts the weights and (if the
architecture moved) re-ports the Swift encoder. Watch for **major releases only**
— a new Mimi version or a new TTS checkpoint — not routine commits.

### ③ Blind spot — `slaughters85j/pocket-tts-core-ml-conversion`
**Private/404, so it cannot be watched.** This is where Kyutai checkpoints are
turned into the `.mlpackage` files and `mimi_encoder_weights.safetensors` we
depend on. Our only signal that re-converted assets exist is when they appear in
the macOS app repo (or its release assets).

## Why Mimi specifically barely moves

Mimi is a *released, stable* neural codec. The `MimiEncoder` here is a frozen
hand-port of one checkpoint, exercised only at bake time to manufacture voice
conditioning. The known issues were already resolved in the fp32 rebuild
(flat drift past 100 steps; 1.4e-4 vs the fp32 PyTorch reference). So **Mimi is
the least likely layer to need updates** — realistic future improvement comes
from the pocket-tts model (quality/speed) or John's conversion precision, far
more than from the codec.

## Can we reproduce John's weight work? (investigated 2026-05-22)

Mostly **yes** — the private conversion repo is far less of a chokepoint than it
first appears, because the *source* model and the public `pocket_tts` package are
both already on disk. Split the work into the three weight artifacts:

| What | Reproducible? | Why |
|------|---------------|-----|
| **Per-voice bake conditioning** | ✅ already own it | `vocalize bake` (Swift MLX MimiEncoder) makes it locally; `scripts/encode_voice_conditioning.py` is a second, independent PyTorch path from the public model. No John dependency. |
| **`mimi_encoder_weights.safetensors`** | ✅ fully unblocked | Public model cached locally + known target key-scheme (`MimiEncoder.load()` renames) + parity validator (`scripts/validate_mimi_encoder.py`). ~half-day script. |
| **3 inference `.mlpackage`** (`calm_stateful`, `prompt_phase`, `mimi_stateful`) | ⚠️ effortful, not blocked | Public PyTorch source + public `coremltools` + documented precision strategy, but we'd re-implement John's stateful-conversion pipeline from scratch (days). Only needed for a *new* Kyutai checkpoint. |

**Evidence (all local / public):**

- **Base model is public + cached:** `kyutai/pocket-tts-without-voice-cloning` →
  `~/.cache/huggingface/hub/models--kyutai--pocket-tts-without-voice-cloning/.../tts_b6369a24.safetensors`
  (463 MB, variant `b6369a24`). (A gated `kyutai/pocket-tts` also exists — line 58
  of `pocket_tts/models/tts_model.py` notes it needs accepting terms — but the
  cached `-without-voice-cloning` variant is what loads.)
- **Public package on disk:** `/Volumes/Xarismata/Projects/pocket-tts`
  (`2b3pro/pocket-tts`). `TTSModel.load_model(variant="b6369a24")` loads the
  cached weights with no private repo.
- **Mimi is just submodules on that model:** `mimi.encoder.model`,
  `mimi.encoder_transformer`, `mimi._to_framerate`, `tts.flow_lm.speaker_proj_weight`.
- **Reference + validator ship locally:** `scripts/encode_voice_conditioning.py`,
  `scripts/validate_mimi_encoder.py` (emit stage-by-stage parity tensors).

> The `pocket-tts-core-ml-conversion` private repo only really gates artifact ③
> (the stateful Core ML conversion *scripts*) — not the weights themselves.

## Supply-chain risk

The real exposure is narrower than "John is a single point of dependency": it's
specifically **the `.mlpackage` stateful-conversion pipeline** (artifact ③). If
John stops maintaining `pocket-tts-macos` *and* Kyutai ships a new checkpoint,
we'd need to re-implement that conversion ourselves (feasible — see table above —
but days of `coremltools` work). Everything else we can already regenerate.

Mitigations worth keeping current:

- Keep the v1.2 release `.app` archived (it carries all model assets — see
  [HEADLESS_DAEMON.md](./HEADLESS_DAEMON.md)). HF `slaughters85j/pocket-tts-coreml`
  mirrors the four mlpackages as backup.
- Keep the cached `kyutai/pocket-tts-without-voice-cloning` snapshot (the PyTorch
  source for any future re-conversion) — don't let it get pruned.
- If the conversion repo ever goes public again, clone it immediately.

## Checking drift

```bash
# How far behind our direct upstream are we?
git fetch upstream --quiet
git rev-list --count HEAD..upstream/main      # 0 = current
git log --oneline HEAD..upstream/main         # what we'd be merging

# Is the conversion repo public yet? (200 = yes, 404 = still private)
curl -s -o /dev/null -w "%{http_code}\n" \
  https://github.com/slaughters85j/pocket-tts-core-ml-conversion
```

> `upstream` remote = `https://github.com/slaughters85j/pocket-tts-macos.git`.
> Add it once with `git remote add upstream <url>` if missing.
