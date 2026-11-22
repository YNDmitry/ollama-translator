import Foundation
import AVFoundation

@MainActor
final class SpeechHelper: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = SpeechHelper()

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var lastSpokenKey: String?
    private var activeSpeakTask: Task<Void, Never>?
    private var kokoroProcess: Process?

    // In-memory LRU audio cache (last 20 clips) so repeating a flashcard is 0ms & 0% CPU
    private var audioCache: [(key: String, data: Data)] = []
    private let maxCacheItems = 20

    private let kokoroPort = 18421
    private let kokoroIdleTimeoutSec = 600 // Auto-unload Kokoro after 10 min idle
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

    static var kokoroRustBinaryURL: URL? {
        let fm = FileManager.default
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let bundled = execDir.appendingPathComponent("kokoro-tts-rs")
            if fm.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }
        let devFallback = URL(fileURLWithPath: "/Users/dmitry/Projects/ollama-translator/rust-tts/target/release/kokoro-tts-rs")
        if fm.isExecutableFile(atPath: devFallback.path) {
            return devFallback
        }
        return nil
    }

    static var kokoroServerScriptURL: URL? {
        if let bundled = Bundle.main.url(forResource: "kokoro_tts_server", withExtension: "py") {
            return bundled
        }
        let fallback = URL(fileURLWithPath: "/Users/dmitry/Projects/ollama-translator/scripts/kokoro_tts_server.py")
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    static var hasKokoroModelFiles: Bool {
        let fm = FileManager.default
        let hasModel = fm.fileExists(atPath: kokoroModelDir.appendingPathComponent("kokoro-v1.0.onnx").path) ||
                       fm.fileExists(atPath: kokoroModelDir.appendingPathComponent("kokoro-v1.0.int8.onnx").path)
        let hasVoices = fm.fileExists(atPath: kokoroModelDir.appendingPathComponent("voices-v1.0.bin").path)
        return hasModel && hasVoices
    }

    static var hasPythonKokoroFallback: Bool {
        FileManager.default.fileExists(atPath: kokoroPythonURL.path) && kokoroServerScriptURL != nil
    }

    static var isKokoroInstalled: Bool {
        hasKokoroModelFiles && (kokoroRustBinaryURL != nil || hasPythonKokoroFallback)
    }

    static var isUsingRustBackend: Bool {
        kokoroRustBinaryURL != nil
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
    /// Pass `speedOverride` (e.g. 0.75) for slow listening practice.
    func speakEnglish(_ text: String, speedOverride: Double? = nil) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        let cfg = ConfigStore.shared.config
        let effectiveSpeed = speedOverride ?? cfg.ttsSpeed
        let toggleKey = String(format: "%.2f|%@", effectiveSpeed, cleaned)

        if isSpeaking && lastSpokenKey == toggleKey {
            stop()
            return
        }

        stop()
        lastSpokenKey = toggleKey

        if cfg.ttsEngine == .kokoro && Self.isKokoroInstalled {
            activeSpeakTask = Task { [weak self] in
                guard let self = self else { return }
                let ok = await self.speakWithKokoro(
                    text: cleaned,
                    voice: cfg.kokoroVoice,
                    speed: effectiveSpeed
                )
                if !ok && !Task.isCancelled {
                    self.speakWithSystem(
                        text: cleaned,
                        voiceID: cfg.systemVoiceIdentifier,
                        speed: effectiveSpeed
                    )
                }
            }
        } else {
            speakWithSystem(
                text: cleaned,
                voiceID: cfg.systemVoiceIdentifier,
                speed: effectiveSpeed
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
        lastSpokenKey = nil
    }

    /// Immediately stops Kokoro daemon & clears cached audio to free RAM.
    func unloadKokoro() async {
        stop()
        audioCache.removeAll()

        if let url = URL(string: "\(kokoroBaseURL)/shutdown") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 1.0
            _ = try? await URLSession.shared.data(for: req)
        }

        if let proc = kokoroProcess, proc.isRunning {
            proc.terminate()
        }
        kokoroProcess = nil
    }

    func shutdownDaemon() {
        stop()
        audioCache.removeAll()
        if let proc = kokoroProcess, proc.isRunning {
            proc.terminate()
        }
        kokoroProcess = nil
    }

    // MARK: - LRU Audio Cache

    private func cachedAudio(for key: String) -> Data? {
        guard let idx = audioCache.firstIndex(where: { $0.key == key }) else { return nil }
        let item = audioCache.remove(at: idx)
        audioCache.append(item)
        return item.data
    }

    private func storeCachedAudio(_ data: Data, for key: String) {
        audioCache.removeAll { $0.key == key }
        audioCache.append((key: key, data: data))
        if audioCache.count > maxCacheItems {
            audioCache.removeFirst(audioCache.count - maxCacheItems)
        }
    }

    // MARK: - Kokoro Local Neural TTS

    private func speakWithKokoro(text: String, voice: String, speed: Double) async -> Bool {
        let cacheKey = String(format: "%@|%.2f|%@", voice, speed, text)
        if let cached = cachedAudio(for: cacheKey) {
            return playWAVData(cached)
        }

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

            storeCachedAudio(data, for: cacheKey)
            return playWAVData(data)
        } catch {
            return false
        }
    }

    private func playWAVData(_ data: Data) -> Bool {
        do {
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
            let proc = Process()
            let commonArgs = [
                "--port", String(kokoroPort),
                "--model-dir", Self.kokoroModelDir.path,
                "--idle-timeout", String(kokoroIdleTimeoutSec),
                "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)
            ]

            if let rustBin = Self.kokoroRustBinaryURL {
                // Prefer zero-Python native Rust binary bundled inside the .app
                proc.executableURL = rustBin
                proc.arguments = commonArgs
            } else if let scriptURL = Self.kokoroServerScriptURL,
                      FileManager.default.fileExists(atPath: Self.kokoroPythonURL.path) {
                proc.executableURL = Self.kokoroPythonURL
                proc.arguments = [scriptURL.path] + commonArgs
            } else {
                return false
            }

            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                kokoroProcess = proc
            } catch {
                return false
            }
        }

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
        let scaled = Float(Double(AVSpeechUtteranceDefaultSpeechRate) * max(0.7, min(1.25, speed)))
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
            self.lastSpokenKey = nil
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.audioPlayer = nil
            self.lastSpokenKey = nil
        }
    }
}
