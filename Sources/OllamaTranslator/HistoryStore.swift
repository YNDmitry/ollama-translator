import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []

    private let maxEntries = 50
    let historyFileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("OllamaTranslator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.historyFileURL = dir.appendingPathComponent("history.json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: historyFileURL),
           let decoded = try? decoder.decode([HistoryEntry].self, from: data) {
            self.entries = decoded
        }
    }

    func record(_ result: TranslationResult) {
        let orig = result.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trans = result.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orig.isEmpty, !trans.isEmpty else { return }

        // Avoid duplicate back-to-back entries for the exact same pair
        if let first = entries.first,
           first.originalText == orig && first.translatedText == trans && first.direction == result.direction {
            return
        }

        let entry = HistoryEntry(
            originalText: orig,
            translatedText: trans,
            direction: result.direction,
            tone: result.tone,
            durationMs: result.durationMs
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: historyFileURL, options: .atomic)
        }
    }
}
