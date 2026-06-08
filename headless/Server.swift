//
//  Server.swift — pockettts streaming daemon (P3)
//
//  A persistent, inference-only HTTP server around the Core ML TTSEngine.
//  Models are resident (engine init ~0.25s once at startup); each request
//  streams 16-bit LE mono PCM as the model produces frames — no per-call
//  process spawn, no MLX, no metallib.
//
//  Contract mirrors PAI's mlx-server.py so VoiceServer's engine client can
//  treat it identically:
//    GET  /health    → {status, pid, uptime_ms, generations_served, ...}
//    POST /generate  → chunked audio/l16 PCM + X-Sample-Rate / X-Channels / ...
//    POST /shutdown  → graceful exit
//
//  /generate body (JSON):
//    { "text": "...", "voice": "matias"|"marius"|"imported:UUID"|"<path>.safetensors",
//      "stream": true,                  // false → buffer + normalize (council leveling)
//      "targetRmsDb": -20,              // output RMS target (buffered mode only)
//      "temperature": 0.7, "chunkTokenBudget": 50,
//      "noiseClamp": 1.5, "maxFrames": 256, "framesAfterEos": 8,
//      "request_id": "..." }
//
//  Loudness model: streaming mode emits raw frames (RMS over a partial signal
//  is meaningless), so targetRmsDb is honored only when stream=false. That maps
//  cleanly onto advisorium.yaml — solo streams (streamSolo:true, single voice,
//  no cross-leveling), council buffers (streamCouncil:false) and gets leveled.
//

import Foundation
import Network

// MARK: - Constants

private nonisolated let kSampleRate = 24_000
private nonisolated let kBuiltInVoices: Set<String> = [
    "alba", "marius", "javert", "jean", "fantine", "cosette", "eponine", "azelma",
]
/// Cloned voices feel rushed at chunk boundaries; pad post-EOS frames
/// (1 frame = 80 ms). Mirrors VoiceServer pocket.ts's cloned-voice default.
private nonisolated let kClonedFramesAfterEOS = 8

// MARK: - Generation gate

/// Serializes synthesis to one request at a time. Core ML AR state is per-call,
/// but we mirror mlx-server.py's `model_lock` rather than risk concurrent
/// prediction on shared MLModels. Also the home of the served counter.
actor GenerationGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var served = 0

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    func recordServed() { served += 1 }
}

// MARK: - NWConnection async bridges

extension NWConnection {
    nonisolated func sendAsync(_ data: Data, isComplete: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.send(content: data, isComplete: isComplete, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    nonisolated func receiveChunk(max: Int = 65_536) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, Bool), Error>) in
            self.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, err in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: (data ?? Data(), isComplete))
            }
        }
    }
}

// MARK: - PocketDaemon

nonisolated final class PocketDaemon: Sendable {
    private let engine: TTSEngine
    private let gate = GenerationGate()
    private let listener: NWListener
    private let port: UInt16
    private let startMs = Date()
    private let queue = DispatchQueue(label: "pockettts.daemon", attributes: .concurrent)

    init(engine: TTSEngine, port: UInt16) throws {
        self.engine = engine
        self.port = port
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind to loopback only — this is an internal, unauthenticated daemon.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        self.listener = try NWListener(using: params)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            conn.start(queue: self.queue)
            Task { await self.handle(conn) }
        }
        listener.start(queue: queue)
    }

    // MARK: Request lifecycle

    private func handle(_ conn: NWConnection) async {
        defer { conn.cancel() }
        do {
            guard let req = try await readRequest(conn) else {
                try? await writeError(conn, 400, "bad request"); return
            }
            switch (req.method, req.path) {
            case ("GET", "/health"):
                try await handleHealth(conn)
            case ("POST", "/generate"):
                try await handleGenerate(conn, body: req.body)
            case ("POST", "/shutdown"):
                try await writeJSON(conn, ["ok": true])
                note("[pockettts] /shutdown received — exiting")
                // Give the response a beat to flush, then exit.
                try? await Task.sleep(nanoseconds: 100_000_000)
                exit(0)
            default:
                try await writeError(conn, 404, "no route for \(req.method) \(req.path)")
            }
        } catch {
            // Client likely disconnected mid-stream; nothing to do but close.
        }
    }

    // MARK: Routes

    private func handleHealth(_ conn: NWConnection) async throws {
        let body: [String: Any] = [
            "status": "ready",
            "engine": "coreml-pocket",
            "pid": ProcessInfo.processInfo.processIdentifier,
            "uptime_ms": Int(Date().timeIntervalSince(startMs) * 1000),
            "generations_served": await gate.served,
            "sample_rate": kSampleRate,
        ]
        try await writeJSON(conn, body)
    }

    private func handleGenerate(_ conn: NWConnection, body: Data) async throws {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let rawText = json["text"] as? String,
              case let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { try await writeError(conn, 400, "text is required"); return }

        // Voice resolution + fallback (mirrors mlx-server.py's X-Voice-Fallback).
        var voice = (json["voice"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "marius"
        var voiceFallback = false
        if !voice.hasPrefix("imported:"), !kBuiltInVoices.contains(voice) {
            let available = Set(engine.availableVoiceIDs())
            if !available.contains(voice) {
                // Accept a .safetensors path by basename.
                let base = (voice as NSString).lastPathComponent
                    .replacingOccurrences(of: ".safetensors", with: "")
                if available.contains(base) {
                    voice = base
                } else {
                    voiceFallback = true
                    voice = "marius"
                }
            }
        }

        let stream = (json["stream"] as? Bool) ?? true
        let targetRmsDb = numField(json, "targetRmsDb") ?? numField(json, "target_rms_db")
        let requestId = (json["request_id"] as? String) ?? ""
        let options = buildOptions(from: json, voice: voice)
        let estimatedMs = Int((Double(text.split(separator: " ").count) / 2.5) * 1000)

        await gate.acquire()
        do {
            if stream {
                try await streamGenerate(conn, text: text, voice: voice, options: options,
                                         estimatedMs: estimatedMs, requestId: requestId,
                                         voiceFallback: voiceFallback)
            } else {
                try await bufferedGenerate(conn, text: text, voice: voice, options: options,
                                           targetRmsDb: targetRmsDb, estimatedMs: estimatedMs,
                                           requestId: requestId, voiceFallback: voiceFallback)
            }
            await gate.recordServed()
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()
    }

    /// Chunked transfer — frames flushed to the socket as the model emits them.
    private func streamGenerate(
        _ conn: NWConnection, text: String, voice: String, options: SynthesisOptions,
        estimatedMs: Int, requestId: String, voiceFallback: Bool
    ) async throws {
        var headers = pcmHeaders(estimatedMs: estimatedMs, requestId: requestId,
                                 voiceFallback: voiceFallback, chunked: true)
        headers["X-RMS-Mode"] = "stream-passthrough"
        try await sendString(conn, responseHead(200, "OK", headers))

        for await frame in engine.synthesize(text: text, voiceID: voice, options: options) {
            let pcm = pcm16LE(frame.samples)
            guard !pcm.isEmpty else { continue }
            try await sendChunk(conn, pcm)   // throws if the client hung up → ends synthesis
        }
        try await sendString(conn, "0\r\n\r\n")   // terminating chunk
    }

    /// Buffer the whole utterance, optionally RMS-normalize, send with
    /// Content-Length. Used by the council path (streamCouncil:false) where
    /// cross-voice loudness leveling matters more than first-audio latency.
    private func bufferedGenerate(
        _ conn: NWConnection, text: String, voice: String, options: SynthesisOptions,
        targetRmsDb: Float?, estimatedMs: Int, requestId: String, voiceFallback: Bool
    ) async throws {
        var samples: [Float] = []
        for await frame in engine.synthesize(text: text, voiceID: voice, options: options) {
            samples.append(contentsOf: frame.samples)
        }
        var rmsMode = "buffered"
        if let target = targetRmsDb, !samples.isEmpty {
            samples = normalizeRMS(samples, targetDB: target)   // from main.swift (same module)
            rmsMode = "full-normalized"
        }
        let pcm = pcm16LE(samples)
        var headers = pcmHeaders(estimatedMs: estimatedMs, requestId: requestId,
                                 voiceFallback: voiceFallback, chunked: false)
        headers["Content-Length"] = String(pcm.count)
        headers["X-RMS-Mode"] = rmsMode
        try await sendString(conn, responseHead(200, "OK", headers))
        if !pcm.isEmpty { try await conn.sendAsync(pcm) }
    }

    // MARK: Option mapping

    private func buildOptions(from json: [String: Any], voice: String) -> SynthesisOptions {
        var o = SynthesisOptions()
        if let v = numField(json, "temperature") { o.temperature = v }
        if let v = intField(json, "chunkTokenBudget") ?? intField(json, "chunk_budget") { o.chunkTokenBudget = v }
        if let v = numField(json, "noiseClamp") ?? numField(json, "noise_clamp") { o.noiseClamp = v }
        if let v = intField(json, "maxFrames") ?? intField(json, "max_frames") { o.maxFrames = v }
        if let v = intField(json, "framesAfterEos") ?? intField(json, "frames_after_eos") {
            o.framesAfterEOS = v
        } else if !voice.hasPrefix("imported:"), !kBuiltInVoices.contains(voice) {
            o.framesAfterEOS = kClonedFramesAfterEOS   // cloned-voice default
        }
        return o
    }

    // MARK: HTTP response helpers

    private func pcmHeaders(estimatedMs: Int, requestId: String, voiceFallback: Bool, chunked: Bool) -> [String: String] {
        var h: [String: String] = [
            "Content-Type": "audio/l16; rate=\(kSampleRate); channels=1",
            "X-Sample-Rate": String(kSampleRate),
            "X-Channels": "1",
            "X-Bits-Per-Sample": "16",
            "X-Estimated-Duration-Ms": String(estimatedMs),
            "Connection": "close",
        ]
        if chunked { h["Transfer-Encoding"] = "chunked" }
        if !requestId.isEmpty { h["X-Request-Id"] = requestId }
        if voiceFallback { h["X-Voice-Fallback"] = "default" }
        return h
    }

    private func responseHead(_ code: Int, _ reason: String, _ headers: [String: String]) -> String {
        var s = "HTTP/1.1 \(code) \(reason)\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        return s
    }

    private func sendString(_ conn: NWConnection, _ s: String) async throws {
        try await conn.sendAsync(Data(s.utf8))
    }

    private func sendChunk(_ conn: NWConnection, _ payload: Data) async throws {
        var chunk = Data(String(format: "%x\r\n", payload.count).utf8)
        chunk.append(payload)
        chunk.append(Data("\r\n".utf8))
        try await conn.sendAsync(chunk)
    }

    private func writeJSON(_ conn: NWConnection, _ obj: [String: Any]) async throws {
        let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        let head = responseHead(200, "OK", [
            "Content-Type": "application/json",
            "Content-Length": String(body.count),
            "Connection": "close",
        ])
        try await sendString(conn, head)
        try await conn.sendAsync(body)
    }

    private func writeError(_ conn: NWConnection, _ code: Int, _ detail: String) async throws {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": detail])) ?? Data("{}".utf8)
        let reason = code == 404 ? "Not Found" : (code == 400 ? "Bad Request" : "Error")
        let head = responseHead(code, reason, [
            "Content-Type": "application/json",
            "Content-Length": String(body.count),
            "Connection": "close",
        ])
        try await sendString(conn, head)
        try await conn.sendAsync(body)
    }

    // MARK: Request parsing (single request/connection; Connection: close)

    private struct Request { let method: String; let path: String; let body: Data }

    private func readRequest(_ conn: NWConnection) async throws -> Request? {
        var buffer = Data()
        let headerSep = Data("\r\n\r\n".utf8)

        // 1. Read until end of headers.
        while buffer.range(of: headerSep) == nil {
            let (chunk, done) = try await conn.receiveChunk()
            if chunk.isEmpty && done { return nil }
            buffer.append(chunk)
            if buffer.count > 1_000_000 { return nil }   // header bomb guard
        }
        guard let sepRange = buffer.range(of: headerSep) else { return nil }
        let headerData = buffer.subdata(in: 0..<sepRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased().trimmingCharacters(in: .whitespaces) == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        // 2. Read the remaining body up to Content-Length.
        var body = buffer.subdata(in: sepRange.upperBound..<buffer.count)
        while body.count < contentLength {
            let (chunk, done) = try await conn.receiveChunk()
            body.append(chunk)
            if chunk.isEmpty && done { break }
        }
        return Request(method: method, path: path, body: body)
    }
}

// MARK: - Free helpers

/// Float [-1,1] → 16-bit little-endian PCM.
private nonisolated func pcm16LE(_ samples: [Float]) -> Data {
    var d = Data(capacity: samples.count * 2)
    for s in samples {
        let clamped = max(-1.0, min(1.0, s))
        let v = Int16((clamped * 32767).rounded())
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
    return d
}

/// JSONSerialization numbers arrive as NSNumber; read uniformly.
private nonisolated func numField(_ j: [String: Any], _ key: String) -> Float? {
    (j[key] as? NSNumber)?.floatValue
}
private nonisolated func intField(_ j: [String: Any], _ key: String) -> Int? {
    (j[key] as? NSNumber)?.intValue
}
