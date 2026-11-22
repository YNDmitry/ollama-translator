import Foundation
import Combine

@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: AppConfig {
        didSet {
            guard !isLoading else { return }
            save()
            onConfigChanged?(config)
        }
    }

    var onConfigChanged: ((AppConfig) -> Void)?
    private var isLoading = false

    let configFileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("OllamaTranslator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.configFileURL = dir.appendingPathComponent("config.json")

        self.isLoading = true
        if let data = try? Data(contentsOf: configFileURL),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = AppConfig()
        }
        self.isLoading = false
        save()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: configFileURL, options: .atomic)
        }
    }

    func reloadFromDisk() {
        guard let data = try? Data(contentsOf: configFileURL),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return
        }
        isLoading = true
        config = decoded
        isLoading = false
        onConfigChanged?(config)
    }

    func addGlossaryEntry(source: String, target: String, direction: TranslationDirection, mode: GlossaryMatchMode) {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty, !trimmedTarget.isEmpty else { return }
        config.glossary.append(
            GlossaryEntry(
                source: trimmedSource,
                target: trimmedTarget,
                direction: direction,
                mode: mode,
                enabled: true
            )
        )
    }

    func removeGlossaryEntry(id: UUID) {
        config.glossary.removeAll { $0.id == id }
    }

    func resetHotkeys() {
        config.replaceHotkey = .defaultReplace
        config.popupHotkey = .defaultPopup
        config.quickWindowHotkey = .defaultQuickWindow
        config.polishHotkey = .defaultPolish
        config.flashcardsHotkey = .defaultFlashcards
    }
}
