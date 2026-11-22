import Foundation

@MainActor
final class KokoroDownloader: NSObject, ObservableObject {
    static let shared = KokoroDownloader()

    @Published var isDownloading: Bool = false
    @Published var progress: Double = 0.0
    @Published var statusText: String = ""
    @Published var errorMessage: String? = nil

    private var downloadSession: URLSession?
    private var activeTask: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var currentStepIndex: Int = 0
    private var totalSteps: Int = 2
    private var stepLabel: String = ""
    private var cancelledByUser: Bool = false

    private let files: [(filename: String, url: String, label: String)] = [
        (
            "voices-v1.0.bin",
            "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin",
            "Голоса Kokoro (28 МБ)"
        ),
        (
            "kokoro-v1.0.onnx",
            "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx",
            "Модель Kokoro-82M (310 МБ)"
        )
    ]

    private override init() {
        super.init()
    }

    func startDownload(onComplete: @escaping () -> Void) {
        guard !isDownloading else { return }

        isDownloading = true
        cancelledByUser = false
        progress = 0
        errorMessage = nil
        statusText = "Подготовка к загрузке..."

        let modelDir = SpeechHelper.kokoroModelDir
        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        let pending = files.filter { item in
            !FileManager.default.fileExists(atPath: modelDir.appendingPathComponent(item.filename).path)
        }

        if pending.isEmpty {
            isDownloading = false
            progress = 1.0
            statusText = "✓ Файлы модели уже скачаны"
            onComplete()
            return
        }

        totalSteps = pending.count
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        downloadSession = session

        Task { [weak self] in
            guard let self = self else { return }
            do {
                for (index, item) in pending.enumerated() {
                    if self.cancelledByUser {
                        throw CancellationError()
                    }
                    self.currentStepIndex = index
                    self.stepLabel = item.label
                    self.statusText = "Скачиваю \(item.label)..."

                    guard let url = URL(string: item.url) else { continue }
                    let tempLocation = try await self.downloadFile(url: url, session: session)

                    let destURL = modelDir.appendingPathComponent(item.filename)
                    let stagingURL = modelDir.appendingPathComponent(item.filename + ".tmp")
                    try? FileManager.default.removeItem(at: stagingURL)
                    try FileManager.default.moveItem(at: tempLocation, to: stagingURL)
                    try? FileManager.default.removeItem(at: destURL)
                    try FileManager.default.moveItem(at: stagingURL, to: destURL)
                }

                self.isDownloading = false
                self.progress = 1.0
                self.statusText = "✓ Kokoro-82M успешно скачан и готов к работе!"
                self.cleanupSession()
                onComplete()
            } catch is CancellationError {
                self.isDownloading = false
                self.progress = 0
                self.statusText = "Загрузка отменена"
                self.cleanupSession()
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                self.isDownloading = false
                self.progress = 0
                self.statusText = "Загрузка отменена"
                self.cleanupSession()
            } catch {
                self.isDownloading = false
                self.errorMessage = "Ошибка загрузки: \(error.localizedDescription)"
                self.statusText = ""
                self.cleanupSession()
            }
        }
    }

    func cancel() {
        cancelledByUser = true
        activeTask?.cancel()
        activeTask = nil
    }

    func removeModels(onComplete: @escaping () -> Void) {
        Task {
            await SpeechHelper.shared.unloadKokoro()
            let dir = SpeechHelper.kokoroModelDir
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("kokoro-v1.0.onnx"))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("kokoro-v1.0.int8.onnx"))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("voices-v1.0.bin"))
            self.statusText = "Файлы модели удалены"
            self.progress = 0
            onComplete()
        }
    }

    private func downloadFile(url: URL, session: URLSession) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let task = session.downloadTask(with: url)
            self.activeTask = task
            task.resume()
        }
    }

    private func cleanupSession() {
        downloadSession?.finishTasksAndInvalidate()
        downloadSession = nil
        activeTask = nil
    }
}

extension KokoroDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let stepFrac: Double
            if totalBytesExpectedToWrite > 0 {
                stepFrac = min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
                let writtenMB = Double(totalBytesWritten) / 1_048_576.0
                let totalMB = Double(totalBytesExpectedToWrite) / 1_048_576.0
                self.statusText = String(format: "%@: %.1f / %.0f МБ", self.stepLabel, writtenMB, totalMB)
            } else {
                stepFrac = 0.0
                let writtenMB = Double(totalBytesWritten) / 1_048_576.0
                self.statusText = String(format: "%@: %.1f МБ...", self.stepLabel, writtenMB)
            }
            let overall = (Double(self.currentStepIndex) + stepFrac) / Double(max(1, self.totalSteps))
            self.progress = min(1.0, max(0.0, overall))
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Copy synchronously before URLSession deletes the temporary file on return
        let preserved = FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoro_dl_\(UUID().uuidString).bin")
        do {
            try FileManager.default.moveItem(at: location, to: preserved)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let cont = self.continuation
                self.continuation = nil
                cont?.resume(returning: preserved)
            }
        } catch {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let cont = self.continuation
                self.continuation = nil
                cont?.resume(throwing: error)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let cont = self.continuation
            self.continuation = nil
            cont?.resume(throwing: error)
        }
    }
}
