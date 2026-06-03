# Changelog

All notable changes to Mimika (formerly Pocket TTS).

## 1.5.2

- **Rebrand to Mimika** — the app surface was renamed from "Pocket TTS" for
  App Store Guideline 5.2.5 compliance (dropping the "macOS" term and the
  upstream project name). The on-device TTS engine name is unchanged.
- **Audio follows the system default output** — fixed playback being silent
  through AirPods / headphones that became the default output after launch.
  The engine now binds to the current default output device and re-routes
  live when you switch outputs.
- **Fixed an audio-engine priority inversion** around playback teardown — all
  blocking AVAudioEngine lifecycle calls now run on a dedicated serial queue
  at matched QoS, clearing the Thread Performance Checker "Hang Risk".

## 1.5.1

- Fix sidebar layout clipping on short windows.
