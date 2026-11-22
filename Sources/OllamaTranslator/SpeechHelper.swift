import Foundation
import AVFoundation

@MainActor
final class SpeechHelper: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = SpeechHelper()

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var lastSpokenText: String?
    private var activeSpeakTask: Task<Void, Never>?
    private var kokoroProcess: Process?

    private let kokoroPort = 18421
    private var kokoroBaseURL: String { "http://127.0.0.1:\(kokoroPort)" }

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool {
        synthesizer.isSpeaking || (audioPlayer?.isPlaying == true)
    }

    static var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OllamaTranslator", isDirectory: true)
    }

    static var kokoroPythonURL: URL {
        appSupportDir.appendingPathComponent("kokoro-venv/bin/python")
    }

    static var kokoroModelDir: URL {
        appSupportDir.appendingPathComponent("kokoro", isDirectory: true)
    }

    static var kokoroServerScriptURL: URL? {
        if let bundled = Bundle.main.url(forResource: "kokoro_tts_server", withExtension: "py") {
            return bundled
        }
        // Fallback for running binary directly from project workspace
        let fallback = URL(fileURLWithPath: "/Users/dmitry/Projects/ollama-translator/scripts/kokoro_tts_server.py")
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    static var isKokoroInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: kokoroPythonURL.path) &&
               fm.fileExists(atPath: kokoroModelDir.appendingPathComponent("kokoro-v1.0.onnx").path) &&
               fm.fileExists(atPath: kokoroModelDir.appendingPathComponent("voices-v1.0.bin").path) &&
               kokoroServerScriptURL != nil
    }

    static func installedEnglishSystemVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("en") }
            .sorted { lhs, rhs in
                if lhs.quality.rawValue != rhs.quality.rawValue {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                return lhs.name < rhs.name
            }
    }

    /// Speaks English text aloud using Kokoro-82M (if enabled & installed) or macOS AVSpeechSynthesizer.
    /// Calling again with the same text while playing stops playback.
    func speakEnglish(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        if isSpeaking && lastSpokenText == cleaned {
            stop()
            return
        }

        stop()
        lastSpokenText = cleaned

        let cfg = ConfigStore.shared.config
        if cfg.ttsEngine == .kokoro && Self.isKokoroInstalled {
            activeSpeakTask = Task { [weak self] in
                guard let self = self else { return }
                let ok = await self.speakWithKokoro(
                    text: cleaned,
                    voice: cfg.kokoroVoice,
                    speed: cfg.ttsSpeed
                )
                if !ok && !Task.isCancelled {
                    self.speakWithSystem(
                        text: cleaned,
                        voiceID: cfg.systemVoiceIdentifier,
                        speed: cfg.ttsSpeed
                    )
                }
            }
        } else {
            speakWithSystem(
                text: cleaned,
                voiceID: cfg.systemVoiceIdentifier,
                speed: cfg.ttsSpeed
            )
        }
    }

    func stop() {
        activeSpeakTask?.cancel()
        activeSpeakTask = nil
        if let player = audioPlayer, player.isPlaying {
            player.stop()
        }
        audioPlayer = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        lastSpokenText = nil
    }

    func shutdownDaemon() {
        stop()
        if let proc = kokoroProcess, proc.isRunning {
            proc.terminate()
        }
        kokoroProcess = nil
    }

    // MARK: - Kokoro Local Neural TTS

    private func speakWithKokoro(text: String, voice: String, speed: Double) async -> Bool {
        guard await ensureKokoroServerRunning() else { return false }
        guard !Task.isCancelled else { return false }

        guard let url = URL(string: "\(kokoroBaseURL)/tts") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "text": text,
            "voice": voice,
            "speed": speed
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return false }
        req.httpBody = bodyData

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard !Task.isCancelled else { return true }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
                return false
            }

            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            self.audioPlayer = player
            player.play()
            return true
        } catch {
            return false
        }
    }

    private func ensureKokoroServerRunning() async -> Bool {
        if await isKokoroServerHealthy() {
            return true
        }

        if kokoroProcess == nil || kokoroProcess?.isRunning == false {
            guard let scriptURL = Self.kokoroServerScriptURL else { return false }
            let proc = Process()
            proc.executableURL = Self.kokoroPythonURL
            proc.arguments = [
                scriptURL.path,
                "--port", String(kokoroPort),
                "--model-dir", Self.kokoroModelDir.path
            ]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                kokoroProcess = proc
            } catch {
                return false
            }
        }

        // Wait up to ~8 seconds on cold start while ONNX model loads into RAM
        for _ in 0..<40 {
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
            if await isKokoroServerHealthy() {
                return true
            }
        }
        return false
    }

    private func isKokoroServerHealthy() async -> Bool {
        guard let url = URL(string: "\(kokoroBaseURL)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 0.8
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - macOS Native AVSpeechSynthesizer Fallback

    private func speakWithSystem(text: String, voiceID: String, speed: Double) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredEnglishSystemVoice(preferredID: voiceID)
        let scaled = Float(Double(AVSpeechUtteranceDefaultSpeechRate) * max(0.75, min(1.25, speed)))
        utterance.rate = scaled
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)
    }

    private func preferredEnglishSystemVoice(preferredID: String) -> AVSpeechSynthesisVoice? {
        if !preferredID.isEmpty, let explicit = AVSpeechSynthesisVoice(identifier: preferredID) {
            return explicit
        }
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let enUS = voices.filter { $0.language.lowercased().hasPrefix("en-us") }
        if let premium = enUS.first(where: { $0.quality == .premium }) {
            return premium
        }
        if let enhanced = enUS.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: "en-US") ?? AVSpeechSynthesisVoice(language: "en-GB")
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.lastSpokenText = nil
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.audioPlayer = nil
            self.lastSpokenText = nil
        }
    }
}
