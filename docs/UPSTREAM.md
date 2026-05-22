# Upstream provenance & update watch

How this fork relates to its upstreams, which ones to watch for updates, and
where the blind spots are. The short version: **"pocket-tts" and "Mimi" reach
us through different paths, with John Saunders (`slaughters85j`) as the human
bottleneck between us and Kyutai.** Watch the macOS app repo closely; treat
Kyutai itself as a low-frequency, lagging signal.

> Status snapshot (2026-05-22): this fork is **0 commits behind**
> `slaughters85j/pocket-tts-macos`. The conversion repo is **404 / private**.

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

## Supply-chain risk

The conversion repo being private makes **John Saunders the single point of
dependency**. If he stops maintaining `pocket-tts-macos`, we have no public path
to re-convert a new Kyutai checkpoint ourselves — we'd be frozen on the current
`.mlpackage` set. Mitigations worth keeping current:

- Keep the v1.2 release `.app` archived (it carries all model assets — see
  [HEADLESS_DAEMON.md](./HEADLESS_DAEMON.md)). HF `slaughters85j/pocket-tts-coreml`
  mirrors the four mlpackages as backup.
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
