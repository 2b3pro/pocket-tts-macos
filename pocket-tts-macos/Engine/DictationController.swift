//
//  DictationController.swift
//  pocket-tts-macos
//
//  Drives the Chat composer's mic-button dictation via SFSpeechRecognizer
//  + AVAudioEngine.
//
//  History (in this same file's prior commits): an attempt to migrate to
//  macOS 26's SpeechTranscriber / SpeechAnalyzer crashed at runtime even
//  after the obvious entitlement was added. The sandbox-vs-daemon dance
//  for the new framework needs more investigation than this session can
//  do without being able to interactively debug on the target machine.
//  Until that's resolved with verifiable tests, we ship the older
//  SFSpeechRecognizer path — it's slightly worse UX (Apple's system prompt
//  includes "Speech data from this app will be sent to Apple…") but it
//  doesn't crash. The Apple prompt boilerplate can't be suppressed; the
//  system controls it.

import AVFoundation
import Foundation
import Speech

@MainActor
final class DictationController {

    enum AuthState: Equatable {
        case notDetermined
        case authorized
        case denied
        case restricted
        case unavailable(String)
    }

    enum DictationError: Error, CustomStringConvertible {
        case notAuthorized
        case noMicrophone
        case audioEngineFailed(Error)
        case recognizerUnavailable
        case recognitionFailed(Error)

        var description: String {
            switch self {
            case .notAuthorized:        return "Speech recognition not authorized"
            case .noMicrophone:         return "No microphone input available"
            case .audioEngineFailed(let e): return "Audio engine failed: \(e)"
            case .recognizerUnavailable: return "Speech recognizer unavailable for this locale"
            case .recognitionFailed(let e):  return "Recognition failed: \(e)"
            }
        }
    }

    private(set) var authState: AuthState = .notDetermined

    var onTranscript: ((String) -> Void)?
    var onError: ((DictationError) -> Void)?

    /// Audio engine recreated per start() so inputNode is freshly initialized
    /// after permission state changes. Reusing across permission flips can
    /// leave inputFormat reporting zero rate/channels, tripping a CoreAudio
    /// precondition (EXC_BREAKPOINT on the audio thread) inside installTap.
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer: SFSpeechRecognizer?

    init(locale: Locale = .init(identifier: "en-US")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        if recognizer == nil {
            authState = .unavailable("Speech recognizer not available for this locale")
            return
        }

        // Speech recognition permission.
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
        switch speechStatus {
        case .notDetermined: authState = .notDetermined; return
        case .denied:        authState = .denied; return
        case .restricted:    authState = .restricted; return
        case .authorized:    break
        @unknown default:    authState = .unavailable("unknown speech auth state"); return
        }

        // Microphone permission.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized:
            authState = .authorized
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            authState = granted ? .authorized : .denied
        case .denied:
            authState = .denied
        case .restricted:
            authState = .restricted
        @unknown default:
            authState = .unavailable("unknown mic auth state")
        }
    }

    // MARK: - Start / stop

    func start() throws {
        guard case .authorized = authState else { throw DictationError.notAuthorized }
        guard let recognizer, recognizer.isAvailable else {
            throw DictationError.recognizerUnavailable
        }

        teardown()

        // Fresh engine each start. See note on the audioEngine property.
        let engine = AVAudioEngine()
        self.audioEngine = engine

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            self.audioEngine = nil
            throw DictationError.noMicrophone
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Note: NOT setting `requiresOnDeviceRecognition = true` here.
        // Forcing on-device routes through `com.apple.audioanalyticsd`, which
        // the sandbox blocks → audio-thread precondition crash
        // ("'com.apple.security.exception.mach-lookup.global-name' doesn't
        // contain 'com.apple.audioanalyticsd'"). The mach-lookup exception
        // entitlement that ostensibly fixes this didn't take effect under our
        // signing setup. Server-side recognition uses a different IPC path
        // that's permitted out of the box. Trade-off: dictation audio goes
        // to Apple for transcription (covered by NSSpeechRecognitionUsageDescription).
        self.request = req

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.request = nil
            self.audioEngine = nil
            throw DictationError.audioEngineFailed(error)
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in self.onTranscript?(text) }
            }
            if let error {
                let nsErr = error as NSError
                // `kAFAssistantErrorDomain` 203 is what stop() induces; not a real error.
                if !(nsErr.code == 203 && nsErr.domain == "kAFAssistantErrorDomain") {
                    Task { @MainActor in self.onError?(.recognitionFailed(error)) }
                }
            }
        }
    }

    func stop() {
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        request = nil
    }

    func cancel() {
        teardown()
    }

    // MARK: - Private

    private func teardown() {
        task?.cancel()
        task = nil
        request = nil
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
            }
        }
        audioEngine = nil
    }
}
