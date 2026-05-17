# Pocket TTS macOS

A fully native macOS app that replaces the [Electron-based Pocket TTS](https://github.com/slaughters85j/pocket-tts) frontend with a Python-free, on-device text-to-speech application. Runs Kyutai's ~100M-parameter [pocket-tts](https://github.com/kyutai-labs/pocket-tts) model end-to-end via Core ML — no Python server, no PyInstaller bundle, no network dependency for synthesis.

## Why This Exists

The original Pocket TTS ships as an Electron app wrapping a Python backend (FastAPI + PyTorch). That stack works, but it means bundling a full Python runtime via PyInstaller (~200 MB), managing a background server process, and accepting Electron's memory overhead. This project converts the entire TTS pipeline to Core ML and reimplements the frontend in SwiftUI, producing a single native `.app` with ~0.17s first-audio latency on warm cache and ~3x real-time throughput on Apple Silicon.

## What Was Built

The project was built across six phases over two development sessions. Everything below ships today.

### Core ML Engine (Phase 0)

The Python TTS model was converted to three Core ML `.mlpackage` artifacts via a separate [conversion project](https://github.com/slaughters85j/pocket-tts-core-ml-conversion):

| Model | Size | Role |
|-------|-----:|------|
| `prompt_phase.mlpackage` | 140 MB fp16 | Encodes text tokens + voice into KV cache in one shot |
| `calm_stateful.mlpackage` | 162 MB fp16 | Autoregressive decoder — one latent frame per 80ms step |
| `mimi_stateful.mlpackage` | 20 MB fp16 | Streaming neural codec — converts latents to 1920 PCM samples |

All three use `ct.StateType` for in-place KV cache mutation (no copy-in/copy-out). The pipeline runs at ~38 fps on M1 Ultra vs the 12.5 fps needed for real-time playback. End-to-end spectrum correlation against the PyTorch reference is 0.97.

The Swift engine (`TTSEngine.swift`) orchestrates the full loop:

```
User text → SentencePiece tokenizer → TextNormalizer
    → prompt_phase (writes KV cache)
    → autoregressive loop: calm_stateful → mimi_stateful → PCMFrame
    → AsyncStream<PCMFrame> → StreamingPlayer (AVAudioEngine) → speakers
```

Seven predefined voices ship as precomputed KV states (`*.safetensors`, ~12 MB each). Voice switching is instant — just load and write the KV tensors into the model state.

### Streaming Audio

`StreamingPlayer` feeds each 80ms PCM frame to `AVAudioEngine` as it lands, bridging the engine's 24 kHz mono output to the device's native format. Export to WAV and AAC/M4A is supported.

### SwiftUI Shell

Four tabs matching the Electron app's feature set:

- **Single Voice** — text editor, voice picker, synthesize button, inline audio player with progress scrubbing
- **Multi-Talk** — multi-speaker scripts with `{Speaker}` tags and `[Xs]` pause markers, cursor-aware insertion
- **History** — SwiftData-backed log of past syntheses with "Reuse Setup" to repopulate Single Voice or Multi-Talk
- **Chat** — conversational interface with a local LLM (see below)

The UI is a pixel-level port of the Electron app's dark theme, using the same Tailwind-derived color tokens.

### LM Studio Chat

The Chat tab connects to a local [LM Studio](https://lmstudio.ai/) server (OpenAI-compatible API at `http://localhost:1234`). LLM responses stream token-by-token; a sentence detector splits the stream into chunks that are synthesized and played serially, so the user hears the response building in real time.

Includes:
- Connection status polling with auto-reconnect
- Configurable base URL, model, system prompt, and TTS voice (Settings sheet, Cmd+,)
- Mic button for speech-to-text dictation (SFSpeechRecognizer + AVAudioEngine)
- Transcript export to Markdown and one-click "Open in Multi-Talk"

### Metal Orb Visualizer

A port of the Electron app's Gemini fractal-orb shader from WebGL/GLSL to Metal MSL. The orb is a raymarched volumetric plasma core with an ice-blue rim disc. During TTS playback, real-time audio amplitude drives the plasma's internal energy via an `Atomic<Float>` bridge between the `StreamingPlayer` actor and the 60fps Metal render loop. Toggled from the Chat tab's top bar.

### Text Normalizer

A full port of the Python `text_normalizer.py` (~1000 lines) to Swift. Converts raw text into speakable form before SentencePiece tokenization:

- Numbers, decimals, negatives → English words (`$3.5 billion` → "three point five billion dollars")
- 149 unit types with singular/plural (`17.5mm` → "seventeen point five millimeters")
- 45 abbreviations (`Dr.` → "Doctor", `Jan.` → "January")
- Currency with magnitude words, percentages, time notation, ordinals, fractions
- 322 domain-specific terms
- Acronym spelling (`FBI` → "F B I") with pronounceable exceptions (`NASA` stays `NASA`)

## Project Structure

```
pocket-tts-macos/
├── pocket-tts-macos/
│   ├── App/                    AppState, SynthesisStatus
│   ├── Engine/                 TTSEngine, Tokenizer, VoiceLoader, TextNormalizer,
│   │                           NumberToWords, DictationController, ModelPaths
│   ├── Audio/                  StreamingPlayer, WAVEncoder, AACEncoder
│   ├── Views/                  SingleVoice, MultiTalk, History, Chat, Settings, TabBar
│   ├── ViewModels/             Per-tab view models (Observable, MainActor)
│   ├── Components/             18 reusable UI components (OrbView, VoiceSelector,
│   │                           MessageBubble, AudioPlayer, SpeakerCard, etc.)
│   ├── Models/                 Voice, ChatModels, ChatSettings
│   ├── Networking/             LMStudioClient (SSE streaming), SentenceDetector
│   ├── Persistence/            SwiftData models, HistoryStore
│   ├── Metal/                  OrbShader.metal
│   ├── Theme/                  Design tokens (colors, typography, spacing)
│   └── Resources/              Bundled mlpackages, tokenizer, voice KV states
├── pocket-tts-macosTests/      9 XCTest files
└── pocket-tts-macosUITests/    UI test target
```

## Requirements

- macOS 15+ (Core ML stateful models require it)
- Xcode 16+ (Swift 6)
- Apple Silicon recommended (Intel builds but is not optimized)
- ~410 MB disk for bundled models (3 mlpackages + 7 voice KV states + tokenizer)
- [LM Studio](https://lmstudio.ai/) for Chat tab (optional — the rest of the app works without it)

## Building

```bash
# Clean build (use xcode-builder-agent or clean env to avoid miniforge linker contamination)
env -i PATH=/usr/bin:/bin HOME=$HOME xcodebuild \
    -project pocket-tts-macos.xcodeproj \
    -scheme pocket-tts-macos \
    -destination 'platform=macOS' \
    -configuration Debug build

# Run tests
env -i PATH=/usr/bin:/bin HOME=$HOME xcodebuild \
    -project pocket-tts-macos.xcodeproj \
    -scheme pocket-tts-macos \
    -destination 'platform=macOS' test
```

## Architecture Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| TTS runtime | Core ML (ct.StateType) | In-place KV mutation, no Python, ~3x real-time on M1 |
| UI framework | SwiftUI | Native feel, less code than AppKit, matches deployment target |
| Concurrency | Swift Concurrency (async/await, actors) | No GCD, structured cancellation, MainActor isolation |
| Audio | AVAudioEngine | Gap-free streaming at 24kHz, resamples to device format |
| Persistence | SwiftData | Native Swift, CloudKit-ready, replaces the Electron app's JSON files |
| Chat backend | LM Studio (OpenAI-compatible) | Local LLM, no cloud dependency, same API the Electron app uses |
| Visualization | Metal MSL | Direct GPU access, 60fps raymarching, no Three.js overhead |
| Text normalization | Pure Swift regex | No NLP libs, microsecond latency, matches Python normalizer output |

## Remaining Work

| Phase | Status | Description |
|-------|--------|-------------|
| Phase 6 | Pending | Code signing, notarization, Sparkle auto-update, DMG packaging |

### Deferred to v2

- Voice cloning (gated HuggingFace checkpoint, speaker encoder conversion)
- Enhancement Studio (LavaSR integration)
- iOS variant (engine is platform-agnostic; UI needs `#if os(iOS)` guards)
- Fish Audio S2 Pro backend (MLX, Apple Silicon only)

## Related Projects

| Project | Role |
|---------|------|
| [pocket-tts](https://github.com/slaughters85j/pocket-tts) | Original Python/Electron app — reference implementation |
| [pocket-tts-core-ml-conversion](https://github.com/slaughters85j/pocket-tts-core-ml-conversion) | Core ML conversion scripts, validators, Swift CLI harness |
| [kyutai-labs/pocket-tts](https://github.com/kyutai-labs/pocket-tts) | Upstream model by Kyutai |

## Authors

**Upstream (Kyutai):** Manu Orsini, Simon Rouard, Gabriel De Marmiesse, Vaclav Volhejn, Neil Zeghidour, Alexandre Defossez

**This project:** John Saunders — Core ML conversion, native macOS app, Metal orb port, text normalizer, streaming engine
