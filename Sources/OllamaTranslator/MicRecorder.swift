import Foundation
import AVFoundation

enum MicRecorderError: LocalizedError {
    case permissionDenied
    case formatError
    case engineFailed(String)
    case nothingRecorded

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Нет доступа к микрофону. Выдайте разрешение в Системных настройках → Конфиденциальность → Микрофон."
        case .formatError:
            return "Не удалось настроить аудиоформат микрофона"
        case .engineFailed(let msg):
            return "Ошибка записи с микрофона: \(msg)"
        case .nothingRecorded:
            return "Запись слишком короткая или пустая"
        }
    }
}

/// Records microphone audio cleanly into 16 kHz mono 16-bit PCM WAV for Whisper,
/// publishing live RMS audio levels for UI visualization.
@MainActor
final class MicRecorder: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var audioLevel: Float = 0.0
    @Published var elapsedSeconds: Double = 0.0

    private var engine: AVAudioEngine?
    private var outputFileURL: URL?
    private let lock = NSLock()
    private var recordedSamples: [Int16] = []
    private var startDate: Date?
    private var timer: Timer?

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    func startRecording() async throws {
        guard !isRecording else { return }

        let granted = await requestPermission()
        guard granted else { throw MicRecorderError.permissionDenied }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw MicRecorderError.formatError
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ),
        let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw MicRecorderError.formatError
        }

        lock.withLock {
            recordedSamples.removeAll(keepingCapacity: true)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaking_\(UUID().uuidString).wav")
        self.outputFileURL = tempURL

        let ratio = 16_000.0 / hwFormat.sampleRate
        let bufferLock = self.lock

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Compute live RMS level from input buffer
            if let chData = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                let count = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<count {
                    let v = chData[i]
                    sum += v * v
                }
                let rms = sqrt(sum / Float(count))
                let normalized = min(1.0, max(0.0, rms * 6.5))
                Task { @MainActor [weak self] in
                    self?.audioLevel = normalized
                }
            }

            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
                return
            }

            var provided = false
            var convError: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if provided {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                provided = true
                outStatus.pointee = .haveData
                return buffer
            }

            converter.convert(to: converted, error: &convError, withInputFrom: inputBlock)
            if convError == nil, converted.frameLength > 0, let int16Ptr = converted.int16ChannelData?[0] {
                let count = Int(converted.frameLength)
                let slice = UnsafeBufferPointer(start: int16Ptr, count: count)
                bufferLock.lock()
                self.recordedSamples.append(contentsOf: slice)
                bufferLock.unlock()
            }
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw MicRecorderError.engineFailed(error.localizedDescription)
        }

        self.engine = engine
        self.isRecording = true
        self.audioLevel = 0
        self.startDate = Date()
        self.elapsedSeconds = 0

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let start = self.startDate else { return }
                self.elapsedSeconds = Date().timeIntervalSince(start)
            }
        }
    }

    func stopRecording() throws -> URL {
        timer?.invalidate()
        timer = nil
        if let eng = engine {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
        }
        engine = nil
        isRecording = false
        audioLevel = 0

        lock.lock()
        let samples = recordedSamples
        recordedSamples.removeAll()
        lock.unlock()

        guard samples.count >= 4000, let url = outputFileURL else {
            throw MicRecorderError.nothingRecorded
        }

        let wavData = Self.encodeWAV(samples: samples, sampleRate: 16_000)
        try wavData.write(to: url, options: .atomic)
        return url
    }

    func cancelRecording() {
        timer?.invalidate()
        timer = nil
        if let eng = engine {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
        }
        engine = nil
        isRecording = false
        audioLevel = 0
        lock.lock()
        recordedSamples.removeAll()
        lock.unlock()
    }

    nonisolated static func encodeWAV(samples: [Int16], sampleRate: UInt32) -> Data {
        let dataBytes = UInt32(samples.count * 2)
        let riffSize = 36 + dataBytes
        let byteRate = sampleRate * 2
        var data = Data(capacity: 44 + Int(dataBytes))

        func appendLE<T: FixedWidthInteger>(_ val: T) {
            var le = val.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: "RIFF".utf8)
        appendLE(riffSize)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLE(UInt32(16))
        appendLE(UInt16(1)) // PCM
        appendLE(UInt16(1)) // Mono
        appendLE(sampleRate)
        appendLE(byteRate)
        appendLE(UInt16(2)) // BlockAlign
        appendLE(UInt16(16)) // BitsPerSample
        data.append(contentsOf: "data".utf8)
        appendLE(dataBytes)

        samples.withUnsafeBufferPointer { ptr in
            let raw = UnsafeRawBufferPointer(ptr)
            data.append(contentsOf: raw)
        }
        return data
    }
}
