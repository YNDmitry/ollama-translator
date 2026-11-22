import Foundation

enum WordMatchStatus: Equatable {
    case matched
    case missed
    case substituted(heard: String)
}

struct WordMatch: Identifiable, Equatable {
    let id = UUID()
    let expected: String
    let status: WordMatchStatus
}

struct PronunciationComparison: Equatable {
    let words: [WordMatch]
    let accuracyPercent: Int
    let heardClean: String
}

/// Pure word-by-word pronunciation diff using Longest Common Subsequence (LCS).
enum PronunciationDiff {
    static func compare(expected: String, heard: String) -> PronunciationComparison {
        let expDisplay = splitDisplayWords(expected)
        let heardDisplay = splitDisplayWords(heard)

        let expNorm = expDisplay.map { normalizeWord($0) }
        let heardNorm = heardDisplay.map { normalizeWord($0) }

        let m = expNorm.count
        let n = heardNorm.count
        guard m > 0 else {
            return PronunciationComparison(words: [], accuracyPercent: 100, heardClean: heard.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // LCS dynamic programming table
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if expNorm[i - 1] == heardNorm[j - 1] && !expNorm[i - 1].isEmpty {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack matched indices
        var matchedExpIndices = Set<Int>()
        var matchedPairs: [(exp: Int, heard: Int)] = []
        var i = m
        var j = n
        while i > 0 && j > 0 {
            if expNorm[i - 1] == heardNorm[j - 1] && !expNorm[i - 1].isEmpty {
                matchedExpIndices.insert(i - 1)
                matchedPairs.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        matchedPairs.reverse()

        // Pair unmatched expected words with nearby unmatched heard words as substitutions
        var usedHeard = Set(matchedPairs.map { $0.heard })
        var results: [WordMatch] = []
        var heardCursor = 0

        for idx in 0..<m {
            if matchedExpIndices.contains(idx) {
                if let pair = matchedPairs.first(where: { $0.exp == idx }) {
                    heardCursor = pair.heard + 1
                }
                results.append(WordMatch(expected: expDisplay[idx], status: .matched))
            } else {
                // Find next unmatched heard word before the next matched anchor
                let nextAnchorHeard = matchedPairs.first(where: { $0.exp > idx })?.heard ?? n
                var foundSub: String? = nil
                while heardCursor < nextAnchorHeard {
                    if !usedHeard.contains(heardCursor) {
                        foundSub = heardDisplay[heardCursor]
                        usedHeard.insert(heardCursor)
                        heardCursor += 1
                        break
                    }
                    heardCursor += 1
                }
                if let sub = foundSub {
                    results.append(WordMatch(expected: expDisplay[idx], status: .substituted(heard: sub)))
                } else {
                    results.append(WordMatch(expected: expDisplay[idx], status: .missed))
                }
            }
        }

        let accuracy = Int((Double(matchedExpIndices.count) / Double(m) * 100.0).rounded())
        return PronunciationComparison(
            words: results,
            accuracyPercent: min(100, max(0, accuracy)),
            heardClean: heard.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func splitDisplayWords(_ text: String) -> [String] {
        var sep = CharacterSet.whitespacesAndNewlines
        sep.insert(charactersIn: "-—–")
        return text.components(separatedBy: sep)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'"))) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeWord(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .punctuationCharacters)
    }
}

enum WhisperError: LocalizedError {
    case cliNotFound
    case modelNotFound
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Не найден whisper-cli. Установите его командой: brew install whisper-cpp"
        case .modelNotFound:
            return "Модель Whisper не скачана. Скачайте её в Настройках → Основные → Распознавание речи."
        case .transcriptionFailed(let msg):
            return "Ошибка распознавания Whisper: \(msg)"
        }
    }
}

enum WhisperService {
    static let defaultModelFilename = "ggml-large-v3-turbo-q5_0.bin"
    static let defaultModelURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"

    /// Shared model folder used by both OllamaTranslator and VoiceCopilot so weights are never duplicated!
    static var sharedModelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WhisperModels", isDirectory: true)
    }

    static var defaultModelPath: URL {
        sharedModelsDir.appendingPathComponent(defaultModelFilename)
    }

    static var whisperCLIURL: URL? {
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static var resolvedModelURL: URL? {
        let preferred = defaultModelPath
        if FileManager.default.fileExists(atPath: preferred.path) {
            return preferred
        }
        // Check if any other .bin whisper model exists in sharedModelsDir
        if let files = try? FileManager.default.contentsOfDirectory(at: sharedModelsDir, includingPropertiesForKeys: nil),
           let anyModel = files.first(where: { $0.pathExtension == "bin" && !$0.lastPathComponent.hasSuffix(".tmp") }) {
            return anyModel
        }
        return nil
    }

    static var isReady: Bool {
        whisperCLIURL != nil && resolvedModelURL != nil
    }

    static func transcribe(wavURL: URL, language: String = "en") async throws -> String {
        guard let cli = whisperCLIURL else { throw WhisperError.cliNotFound }
        guard let model = resolvedModelURL else { throw WhisperError.modelNotFound }

        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = cli
                proc.arguments = [
                    "-m", model.path,
                    "-f", wavURL.path,
                    "-l", language,
                    "-t", "6",
                    "-np",
                    "-nt"
                ]

                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                do {
                    try proc.run()
                    proc.waitUntilExit()

                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

                    if proc.terminationStatus != 0 {
                        let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(proc.terminationStatus)"
                        cont.resume(throwing: WhisperError.transcriptionFailed(errStr))
                        return
                    }

                    let raw = String(data: outData, encoding: .utf8) ?? ""
                    let cleaned = raw
                        .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
                        .replacingOccurrences(of: "\n", with: " ")
                        .components(separatedBy: .whitespaces)
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    cont.resume(returning: cleaned)
                } catch {
                    cont.resume(throwing: WhisperError.transcriptionFailed(error.localizedDescription))
                }
            }
        }
    }
}

@MainActor
final class WhisperModelDownloader: NSObject, ObservableObject {
    static let shared = WhisperModelDownloader()

    @Published var isDownloading: Bool = false
    @Published var progress: Double = 0.0
    @Published var statusText: String = ""
    @Published var errorMessage: String? = nil

    private var session: URLSession?
    private var activeTask: URLSessionDownloadTask?
    private var completionHandler: (() -> Void)?

    private override init() {
        super.init()
    }

    func startDownload(onComplete: @escaping () -> Void) {
        guard !isDownloading else { return }
        guard let url = URL(string: WhisperService.defaultModelURL) else { return }

        try? FileManager.default.createDirectory(at: WhisperService.sharedModelsDir, withIntermediateDirectories: true)
        isDownloading = true
        progress = 0
        errorMessage = nil
        statusText = "Подключение к Hugging Face..."
        completionHandler = onComplete

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 3600
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        let task = s.downloadTask(with: url)
        activeTask = task
        task.resume()
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        session?.invalidateAndCancel()
        session = nil
        isDownloading = false
        progress = 0
        statusText = "Загрузка отменена"
    }
}

extension WhisperModelDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let writtenMB = Double(totalBytesWritten) / 1_048_576.0
            if totalBytesExpectedToWrite > 0 {
                let totalMB = Double(totalBytesExpectedToWrite) / 1_048_576.0
                self.progress = min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
                self.statusText = String(format: "Whisper large-v3-turbo: %.1f / %.0f МБ", writtenMB, totalMB)
            } else {
                self.statusText = String(format: "Whisper large-v3-turbo: %.1f МБ...", writtenMB)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let dest = WhisperService.defaultModelPath
        let staging = WhisperService.sharedModelsDir.appendingPathComponent(WhisperService.defaultModelFilename + ".tmp")
        do {
            try FileManager.default.createDirectory(at: WhisperService.sharedModelsDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.moveItem(at: location, to: staging)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: staging, to: dest)

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isDownloading = false
                self.progress = 1.0
                self.statusText = "✓ Whisper large-v3-turbo скачан и готов!"
                self.session?.finishTasksAndInvalidate()
                self.session = nil
                self.activeTask = nil
                self.completionHandler?()
            }
        } catch {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isDownloading = false
                self.errorMessage = "Ошибка сохранения модели: \(error.localizedDescription)"
                self.session?.finishTasksAndInvalidate()
                self.session = nil
                self.activeTask = nil
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.isDownloading = false
            if (error as? URLError)?.code != .cancelled {
                self.errorMessage = "Ошибка загрузки: \(error.localizedDescription)"
                self.statusText = ""
            }
            self.session?.finishTasksAndInvalidate()
            self.session = nil
            self.activeTask = nil
        }
    }
}
