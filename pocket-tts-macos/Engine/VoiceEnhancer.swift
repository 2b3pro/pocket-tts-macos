//
//  VoiceEnhancer.swift
//  pocket-tts-macos
//
//  LavaSR v2 voice enhancement via MLX. Uses the Vocos BWE (bandwidth
//  extension) model to improve voice recording quality for TTS cloning.
//  Reuses VocosBackbone + ISTFTHead from mlx-audio-swift.
//
//  The ULUNAS denoiser is not ported yet — only the BWE enhancer runs.
//  Most reference recordings are clean enough without denoising.

@preconcurrency import AVFoundation
import Foundation
import HuggingFace
import MLX
import MLXAudioCodecs
import MLXAudioCore
import MLXNN
import Observation

// MARK: - VoiceEnhancer

@MainActor
@Observable
final class VoiceEnhancer {

    static let shared = VoiceEnhancer()

    enum Status: Equatable {
        case idle
        case loading
        case ready
        case enhancing
        case error(String)
    }

    private(set) var status: Status = .idle
    private var model: LavaSREnhancer?

    // MARK: - Bootstrap

    func bootstrapIfNeeded() async {
        guard status == .idle else { return }
        status = .loading

        do {
            let enhancer = try await LavaSREnhancer.load()
            self.model = enhancer
            status = .ready
            print("[VoiceEnhancer] model loaded")
        } catch {
            status = .error(String(describing: error))
            print("[VoiceEnhancer] failed to load: \(error)")
        }
    }

    // MARK: - Enhance

    func enhance(inputURL: URL, outputURL: URL) async throws {
        guard let model else {
            throw EnhancerError.notLoaded
        }

        status = .enhancing

        // Load audio
        let samples = try Self.loadAudio(url: inputURL, targetRate: 48000)
        print("[VoiceEnhancer] loaded \(samples.count) samples @ 48kHz")

        // Run Vocos BWE
        let enhanced = try model.enhance(MLXArray(samples))
        eval(enhanced)

        let output = enhanced.asArray(Float.self)
        print("[VoiceEnhancer] enhanced → \(output.count) samples")

        // RMS normalize to -16 dB
        let normalized = Self.rmsNormalize(output, targetDB: -16.0)

        // Write output WAV
        try Self.writeWAV(samples: normalized, sampleRate: 48000, url: outputURL)

        status = .ready
        print("[VoiceEnhancer] saved to \(outputURL.lastPathComponent)")
    }

    var isReady: Bool { status == .ready }

    // MARK: - Audio I/O

    private static func loadAudio(url: URL, targetRate: Int) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(targetRate), channels: 1, interleaved: false)!
        let frameCount = AVAudioFrameCount(audioFile.length)
        let maxFrames = AVAudioFrameCount(30 * targetRate)
        let readFrames = min(frameCount, maxFrames)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readFrames) else {
            throw EnhancerError.audioReadFailed
        }

        if Int(audioFile.processingFormat.sampleRate) == targetRate && audioFile.processingFormat.channelCount == 1 {
            try audioFile.read(into: buffer, frameCount: readFrames)
        } else {
            let srcBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: readFrames)!
            try audioFile.read(into: srcBuffer, frameCount: readFrames)
            let converter = AVAudioConverter(from: audioFile.processingFormat, to: format)!
            _ = converter.convert(to: buffer, error: nil) { _, outStatus in
                outStatus.pointee = .haveData
                return srcBuffer
            }
        }

        guard let data = buffer.floatChannelData?[0] else { throw EnhancerError.audioReadFailed }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    private static func writeWAV(samples: [Float], sampleRate: Int, url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw EnhancerError.audioWriteFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<samples.count { channel[i] = samples[i] }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func rmsNormalize(_ samples: [Float], targetDB: Float) -> [Float] {
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        let rms = sqrt(sumSq / Float(samples.count))
        guard rms > 1e-8 else { return samples }
        let targetRMS = pow(10, targetDB / 20.0)
        let gain = targetRMS / rms
        return samples.map { min(max($0 * gain, -1.0), 1.0) }
    }

    enum EnhancerError: Error, CustomStringConvertible {
        case notLoaded
        case audioReadFailed
        case audioWriteFailed
        case modelLoadFailed(String)

        var description: String {
            switch self {
            case .notLoaded: return "Voice enhancer not loaded"
            case .audioReadFailed: return "Failed to read audio file"
            case .audioWriteFailed: return "Failed to write audio file"
            case .modelLoadFailed(let msg): return "Model load failed: \(msg)"
            }
        }
    }
}

// MARK: - LavaSR Enhancer Model

/// Vocos-based bandwidth extension model with LavaSR v2 weights.
/// Uses mel spectrogram → ConvNeXt backbone → ISTFT reconstruction.
private class LavaSREnhancer: Module {
    nonisolated(unsafe) let backbone: VocosBackbone
    nonisolated(unsafe) let head: ISTFTHead

    // Mel spectrogram config (from LavaSR enhancer_v2/config.yaml)
    private nonisolated static let nFft = 2048
    private nonisolated static let hopLength = 512
    private nonisolated static let nMels = 80
    private nonisolated static let sampleRate = 48000

    nonisolated override init() {
        self.backbone = VocosBackbone(
            inputChannels: Self.nMels,
            dim: 512,
            intermediateDim: 1536,
            numLayers: 8
        )
        self.head = ISTFTHead(dim: 512, nFft: Self.nFft, hopLength: Self.hopLength)
        super.init()
    }

    static func load() async throws -> LavaSREnhancer {
        let model = LavaSREnhancer()

        // Try loading from bundled resources first, then HuggingFace cache
        let weightsURL: URL
        if let bundled = Bundle.main.url(forResource: "lavasr_enhancer_v2", withExtension: "safetensors") {
            weightsURL = bundled
        } else {
            // Download from HuggingFace
            let modelDir = try await ModelUtils.resolveOrDownloadModel(
                repoID: "YatharthS/LavaSR",
                requiredExtension: "bin"
            )
            let safetensorsPath = modelDir.appendingPathComponent("enhancer_v2_converted.safetensors")
            if FileManager.default.fileExists(atPath: safetensorsPath.path) {
                weightsURL = safetensorsPath
            } else {
                throw VoiceEnhancer.EnhancerError.modelLoadFailed(
                    "Run scripts/export_lavasr_weights.py to convert weights to safetensors"
                )
            }
        }

        var weights = try MLX.loadArrays(url: weightsURL)

        // Filter out precomputed constants that aren't learnable parameters
        let nonModuleKeys = weights.keys.filter {
            $0.hasPrefix("feature_extractor.") || $0.contains("istft.")
        }
        for key in nonModuleKeys { weights.removeValue(forKey: key) }

        // PyTorch Conv1d weights are (C_out, C_in, K); MLX expects (C_out, K, C_in).
        // Transpose all 3D weight tensors (Conv1d kernels).
        for (key, value) in weights {
            if key.hasSuffix(".weight") && value.ndim == 3 {
                weights[key] = value.transposed(0, 2, 1)
            }
        }

        try model.update(parameters: ModuleParameters.unflattened(weights), verify: .noUnusedKeys)
        eval(model)
        return model
    }

    func enhance(_ audio: MLXArray) throws -> MLXArray {
        // Compute mel spectrogram
        let mel = computeMelSpectrogram(audio)

        // Run Vocos backbone + head
        let features = backbone(mel)
        let reconstructed = head(features)

        return reconstructed
    }

    // MARK: - Mel spectrogram

    private func computeMelSpectrogram(_ audio: MLXArray) -> MLXArray {
        let nFft = Self.nFft
        let hopLength = Self.hopLength
        let nMels = Self.nMels

        // Pad audio for STFT
        let padAmount = nFft / 2
        let padded = MLX.padded(audio, widths: [IntOrPair((padAmount, padAmount))])

        // Window
        let window = hannWindow(length: nFft)

        // Frame the signal
        let numSamples = padded.shape[0]
        let numFrames = 1 + (numSamples - nFft) / hopLength

        var frames: [MLXArray] = []
        for i in 0..<numFrames {
            let start = i * hopLength
            let frame = padded[start..<(start + nFft)] * window
            frames.append(frame)
        }
        let framed = MLX.stacked(frames, axis: 0)

        // FFT
        let spec = MLXFFT.rfft(framed, axis: 1)
        let magnitude = abs(spec)

        // Mel filterbank (simplified — linear spacing approximation)
        let melFB = melFilterbank(nMels: nMels, nFft: nFft, sampleRate: Self.sampleRate)
        let melSpec = MLX.matmul(magnitude, melFB.T)

        // Log scale
        let logMel = MLX.log10(melSpec + 1e-7)

        // Shape: (T, nMels) → (1, T, nMels) for backbone
        return logMel.expandedDimensions(axis: 0)
    }

    private func hannWindow(length: Int) -> MLXArray {
        let n = (0..<length).map { Float($0) }
        let factor = Float.pi / Float(length - 1)
        let window = n.map { 0.5 - 0.5 * cos(2.0 * factor * $0) }
        return MLXArray(window)
    }

    private func melFilterbank(nMels: Int, nFft: Int, sampleRate: Int) -> MLXArray {
        let nFreqs = nFft / 2 + 1
        let fMax = Float(sampleRate) / 2.0

        // Mel scale conversion (HTK formula)
        func hzToMel(_ hz: Float) -> Float { 2595.0 * log10(1.0 + hz / 700.0) }
        func melToHz(_ mel: Float) -> Float { 700.0 * (pow(10.0, mel / 2595.0) - 1.0) }

        let melMin = hzToMel(0)
        let melMax = hzToMel(fMax)

        // nMels+2 equally spaced points in mel space
        var melPoints = [Float]()
        for i in 0...(nMels + 1) {
            melPoints.append(melMin + Float(i) * (melMax - melMin) / Float(nMels + 1))
        }
        let hzPoints = melPoints.map { melToHz($0) }
        let binPoints = hzPoints.map { Int(($0 / fMax) * Float(nFreqs - 1)) }

        // Build filterbank matrix [nMels, nFreqs]
        var fb = [[Float]](repeating: [Float](repeating: 0, count: nFreqs), count: nMels)
        for m in 0..<nMels {
            let left = binPoints[m]
            let center = binPoints[m + 1]
            let right = binPoints[m + 2]

            for k in left..<center {
                if center > left {
                    fb[m][k] = Float(k - left) / Float(center - left)
                }
            }
            for k in center..<right {
                if right > center {
                    fb[m][k] = Float(right - k) / Float(right - center)
                }
            }
        }

        return MLXArray(fb.flatMap { $0 }).reshaped([nMels, nFreqs])
    }
}
