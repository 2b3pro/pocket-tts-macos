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
  pockettts say  --voice <id|imported:UUID> --text "<text>" --out <file.wav> [--resources <dir>]
                 [--temperature <f>] [--chunk-budget <int 15-50>] [--noise-clamp <f>] [--max-frames <int>]
                 [--rms-db <target>]   # normalize output loudness to this dBFS RMS
  pockettts bake --wav <ref.wav> --out <voice_kv.safetensors> [--resources <dir>]
                 [--rms-db <target>]   # conditioning RMS baked into the clone (default -16)
  pockettts serve [--port <int>] [--resources <dir>]   # persistent streaming HTTP daemon (default :8891)
  pockettts --version                                  # print build provenance (git SHA / branch / build time)
"""

let sub = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""

// --version / version: print build provenance and exit before any engine work.
if sub == "--version" || sub == "version" || CommandLine.arguments.contains("--version") {
    print(BuildInfo.summary)
    exit(0)
}

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

    // Synth-time knobs (all live fields on SynthesisOptions).
    var options = SynthesisOptions()
    if let v = argValue("--temperature"),  let f = Float(v) { options.temperature = f }
    if let v = argValue("--chunk-budget"), let i = Int(v)   { options.chunkTokenBudget = i }
    if let v = argValue("--noise-clamp"),  let f = Float(v) { options.noiseClamp = f }
    if let v = argValue("--max-frames"),   let i = Int(v)   { options.maxFrames = i }
    // Output loudness: normalize the finished audio to this RMS dBFS target.
    // Omitted → passthrough (the bake's baked-in level). This is the lever for
    // matching loudness across voices (e.g. council consistency).
    let outputRmsDB: Float? = argValue("--rms-db").flatMap(Float.init)

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

        if let target = outputRmsDB {
            let before = rmsDB(samples)
            samples = normalizeRMS(samples, targetDB: target)
            note(String(format: "[pockettts] output RMS: %.1f dB → %.1f dB", before, target))
        }

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

    // Conditioning RMS target baked into the clone. Default -16 dB matches the
    // app / Python reference; lower (e.g. -20) bakes a quieter-conditioned voice.
    let condRmsDB = argValue("--rms-db").flatMap(Float.init) ?? -16.0

    let enc = PocketTTSVoiceEncoder()
    let tBoot = Date()
    await enc.bootstrap()
    let status = await enc.status
    guard status == .ready else { fail("bake: encoder bootstrap failed (status: \(status))", code: 1) }
    note(String(format: "[pockettts] encoder bootstrap: %.0f ms", Date().timeIntervalSince(tBoot) * 1000))

    do {
        let tEnc = Date()
        try await enc.encodeVoice(wavURL: URL(fileURLWithPath: wav), outputURL: URL(fileURLWithPath: outPath), conditioningRmsDB: condRmsDB)
        note(String(format: "[pockettts] bake: %.0f ms (cond RMS %.0f dB)", Date().timeIntervalSince(tEnc) * 1000, condRmsDB))
        note("[pockettts] wrote \(outPath)")
    } catch {
        fail("bake failed: \(error)", code: 1)
    }
}

// MARK: - RMS helpers (output loudness normalization)

nonisolated func rmsDB(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return -.infinity }
    var sumSq: Double = 0
    for s in samples { sumSq += Double(s) * Double(s) }
    let rms = (sumSq / Double(samples.count)).squareRoot()
    return rms > 0 ? 20 * Float(log10(rms)) : -.infinity
}

/// Scale `samples` so their RMS hits `targetDB` dBFS, then peak-limit to avoid
/// clipping (scales the whole buffer down if the gain would push peaks > 1.0).
nonisolated func normalizeRMS(_ samples: [Float], targetDB: Float) -> [Float] {
    let current = rmsDB(samples)
    guard current.isFinite else { return samples }
    var gain = pow(10, (targetDB - current) / 20)
    let peak = samples.reduce(0) { max($0, abs($1)) }
    if peak * gain > 1.0 { gain = 1.0 / peak }   // peak guard
    return samples.map { $0 * gain }
}

// MARK: - serve (persistent streaming daemon)

func runServe() async {
    let port = UInt16(argValue("--port") ?? "") ?? 8891
    do {
        note("[pockettts] \(BuildInfo.summary)")
        let tInit = Date()
        let engine = try await TTSEngine()
        note(String(format: "[pockettts] engine init: %.0f ms", Date().timeIntervalSince(tInit) * 1000))

        let daemon = try PocketDaemon(engine: engine, port: port)
        daemon.start()
        note("[pockettts] serving on http://127.0.0.1:\(port)  (GET /health · POST /generate · POST /shutdown)")

        // Park the main task; the NWListener runs on its own dispatch queue.
        // /shutdown (or SIGTERM) calls exit(0).
        signal(SIGTERM, { _ in exit(0) })
        while true { try await Task.sleep(nanoseconds: 60 * 1_000_000_000) }
    } catch {
        fail("serve failed: \(error)", code: 1)
    }
}

// MARK: - Dispatch

switch sub {
case "say":   await runSay()
case "bake":  await runBake()
case "serve": await runServe()
default:      fail(usage)
}
