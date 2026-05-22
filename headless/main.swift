//
//  main.swift — pockettts headless CLI
//
//  P1 vertical slice: prove the Core ML engine runs outside Xcode/GUI.
//  Loads the engine, synthesizes one utterance to a WAV, and reports
//  first-audio latency + throughput so we can compare against the Python path.
//
//  Usage:
//    pockettts say --voice <id|imported:UUID> --text "<text>" --out <file.wav>
//                  [--resources <dir>] [--temperature <float>]
//
//  --resources sets POCKET_TTS_RESOURCES (where the .mlmodelc / tokenizer /
//  voice KV safetensors live), e.g. an installed app's Contents/Resources.
//

import Foundation

// MARK: - Tiny arg parsing

func argValue(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

func fail(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
}

let note: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

let usage = """
pockettts — headless Core ML pocket-tts
usage:
  pockettts say  --voice <id|imported:UUID> --text "<text>" --out <file.wav> [--resources <dir>] [--temperature <float>]
  pockettts bake --wav <ref.wav> --out <voice_kv.safetensors> [--resources <dir>]
"""

let sub = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""

// --resources must be applied BEFORE the engine reads ModelPaths.overrideResourcesDir
// (a lazy `let` captured on first access).
if let res = argValue("--resources") {
    setenv("POCKET_TTS_RESOURCES", res, 1)
}

// MARK: - say

func runSay() async {
    guard let voice = argValue("--voice"),
          let text = argValue("--text"),
          let outPath = argValue("--out")
    else { fail("say: missing required --voice / --text / --out") }

    var options = SynthesisOptions()
    if let t = argValue("--temperature"), let tv = Float(t) { options.temperature = tv }

    do {
        let tInit = Date()
        let engine = try await TTSEngine()
        note(String(format: "[pockettts] engine init: %.0f ms", Date().timeIntervalSince(tInit) * 1000))

        var samples: [Float] = []
        var firstAudioMs: Double?
        let tSynth = Date()
        for await frame in engine.synthesize(text: text, voiceID: voice, options: options) {
            if firstAudioMs == nil { firstAudioMs = Date().timeIntervalSince(tSynth) * 1000 }
            samples.append(contentsOf: frame.samples)
        }
        let totalMs = Date().timeIntervalSince(tSynth) * 1000
        guard !samples.isEmpty else { fail("synthesis produced no audio (voice '\(voice)' not found, or no frames)", code: 1) }

        try WAVEncoder.write(samples: samples, to: URL(fileURLWithPath: outPath))
        let audioSec = Double(samples.count) / 24_000.0
        let rtf = totalMs > 0 ? audioSec / (totalMs / 1000) : 0
        note(String(format: "[pockettts] first-audio: %.0f ms | total: %.0f ms | audio: %.2fs | %.1fx realtime",
                   firstAudioMs ?? -1, totalMs, audioSec, rtf))
        note("[pockettts] wrote \(outPath)")
    } catch {
        fail("synthesis failed: \(error)", code: 1)
    }
}

// MARK: - bake (WAV → MimiEncoder → voice_prompt_phase → KV-state safetensors)

func runBake() async {
    guard let wav = argValue("--wav"), let outPath = argValue("--out")
    else { fail("bake: missing required --wav / --out") }

    guard FileManager.default.fileExists(atPath: wav) else { fail("bake: input WAV not found: \(wav)", code: 1) }

    let enc = PocketTTSVoiceEncoder()
    let tBoot = Date()
    await enc.bootstrap()
    let status = await enc.status
    guard status == .ready else { fail("bake: encoder bootstrap failed (status: \(status))", code: 1) }
    note(String(format: "[pockettts] encoder bootstrap: %.0f ms", Date().timeIntervalSince(tBoot) * 1000))

    do {
        let tEnc = Date()
        try await enc.encodeVoice(wavURL: URL(fileURLWithPath: wav), outputURL: URL(fileURLWithPath: outPath))
        note(String(format: "[pockettts] bake: %.0f ms", Date().timeIntervalSince(tEnc) * 1000))
        note("[pockettts] wrote \(outPath)")
    } catch {
        fail("bake failed: \(error)", code: 1)
    }
}

// MARK: - Dispatch

switch sub {
case "say":  await runSay()
case "bake": await runBake()
default:     fail(usage)
}
