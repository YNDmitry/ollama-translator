import AppKit
import SwiftUI
import Carbon

enum SettingsTab: Hashable {
    case general
    case glossary
    case hotkeys
    case history
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var selectedTab: SettingsTab = .general

    // General tab state
    @Published var availableModels: [String] = []
    @Published var connectionStatus: String = ""
    @Published var isChecking: Bool = false
    @Published var launchAtLogin: Bool = LaunchAgentManager.isEnabled
    @Published var accessibilityGranted: Bool = TextAutomation.isAccessibilityGranted(prompt: false)
    @Published var kokoroInstalled: Bool = SpeechHelper.isKokoroInstalled

    // Glossary tab state
    @Published var newSource: String = ""
    @Published var newTarget: String = ""
    @Published var newDirection: TranslationDirection = .auto
    @Published var newMode: GlossaryMatchMode = .promptHint

    // History tab state
    @Published var historySearch: String = ""
    @Published var copiedHistoryID: UUID? = nil

    // Hotkey recorder state
    @Published var recordingAction: HotkeyAction? = nil
    private var keyMonitor: Any?

    func refreshSystemStatus() {
        accessibilityGranted = TextAutomation.isAccessibilityGranted(prompt: false)
        launchAtLogin = LaunchAgentManager.isEnabled
        kokoroInstalled = SpeechHelper.isKokoroInstalled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        LaunchAgentManager.setEnabled(enabled)
    }

    func copyHistoryItem(_ entry: HistoryEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.translatedText, forType: .string)
        copiedHistoryID = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            if self?.copiedHistoryID == entry.id {
                self?.copiedHistoryID = nil
            }
        }
    }

    func checkConnection(ollamaClient: OllamaClient, config: AppConfig) {
        isChecking = true
        connectionStatus = ""
        let baseURL = config.ollamaBaseURL
        let currentModel = config.modelName

        Task {
            do {
                let models = try await ollamaClient.fetchModels(baseURL: baseURL)
                await MainActor.run {
                    self.availableModels = models
                    if models.contains(currentModel) {
                        self.connectionStatus = "✓ Подключено! Модель найдена (\(models.count) шт.)"
                    } else {
                        self.connectionStatus = "✓ Ollama доступна (\(models.count) мод.), но выбранная модель не в списке"
                    }
                    self.isChecking = false
                }
            } catch {
                await MainActor.run {
                    self.connectionStatus = "Ошибка: \(error.localizedDescription)"
                    self.isChecking = false
                }
            }
        }
    }

    func toggleRecording(for action: HotkeyAction, store: ConfigStore, onHotkeysUpdated: @escaping () -> Void) {
        if recordingAction == action {
            stopRecording()
            return
        }
        stopRecording()
        recordingAction = action
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 { // Escape cancels
                Task { @MainActor in self.stopRecording() }
                return nil
            }

            var carbonMods: UInt32 = 0
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if flags.contains(.option) { carbonMods |= UInt32(optionKey) }
            if flags.contains(.control) { carbonMods |= UInt32(controlKey) }
            if flags.contains(.shift) { carbonMods |= UInt32(shiftKey) }

            guard carbonMods != 0 else {
                NSSound.beep()
                return nil
            }

            let newBinding = HotkeyBinding(keyCode: UInt32(event.keyCode), modifiers: carbonMods)
            Task { @MainActor in
                switch action {
                case .translateAndReplace:
                    store.config.replaceHotkey = newBinding
                case .translatePopup:
                    store.config.popupHotkey = newBinding
                case .openQuickWindow:
                    store.config.quickWindowHotkey = newBinding
                case .polishEnglish:
                    store.config.polishHotkey = newBinding
                case .openFlashcards:
                    store.config.flashcardsHotkey = newBinding
                }
                self.stopRecording()
                onHotkeysUpdated()
            }
            return nil
        }
    }

    func stopRecording() {
        recordingAction = nil
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var historyStore: HistoryStore
    @ObservedObject var vm: SettingsViewModel
    let ollamaClient: OllamaClient
    let onHotkeysUpdated: () -> Void

    var body: some View {
        TabView(selection: $vm.selectedTab) {
            GeneralSettingsTab(store: store, vm: vm, ollamaClient: ollamaClient)
                .tabItem {
                    Label("Основные", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            GlossarySettingsTab(store: store, vm: vm)
                .tabItem {
                    Label("Словарь замен", systemImage: "book.closed")
                }
                .tag(SettingsTab.glossary)

            HotkeysSettingsTab(store: store, vm: vm, onHotkeysUpdated: onHotkeysUpdated)
                .tabItem {
                    Label("Горячие клавиши", systemImage: "command")
                }
                .tag(SettingsTab.hotkeys)

            HistorySettingsTab(historyStore: historyStore, vm: vm)
                .tabItem {
                    Label("История", systemImage: "clock.arrow.circlepath")
                }
                .tag(SettingsTab.history)
        }
        .padding(16)
        .frame(width: 700, height: 600)
        .onDisappear {
            vm.stopRecording()
        }
    }
}

private struct GeneralSettingsTab: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var vm: SettingsViewModel
    @ObservedObject var downloader = KokoroDownloader.shared
    let ollamaClient: OllamaClient

    var body: some View {
        Form {
            Section("Ollama и модель") {
                TextField("URL сервера Ollama", text: $store.config.ollamaBaseURL)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    TextField("Имя модели", text: $store.config.modelName)
                        .textFieldStyle(.roundedBorder)

                    if !vm.availableModels.isEmpty {
                        Menu("Выбрать") {
                            ForEach(vm.availableModels, id: \.self) { model in
                                Button(model) {
                                    store.config.modelName = model
                                }
                            }
                        }
                        .frame(width: 90)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        vm.checkConnection(ollamaClient: ollamaClient, config: store.config)
                    } label: {
                        HStack(spacing: 5) {
                            if vm.isChecking { ProgressView().controlSize(.small) }
                            Text("Проверить связь и модели")
                        }
                    }
                    .disabled(vm.isChecking)

                    if !vm.connectionStatus.isEmpty {
                        Text(vm.connectionStatus)
                            .font(.system(size: 11.5))
                            .foregroundColor(vm.connectionStatus.hasPrefix("✓") ? .green : .red)
                            .lineLimit(2)
                    }
                }

                Picker("Удерживать модель в памяти (keep_alive)", selection: $store.config.keepAlive) {
                    Text("5 минут").tag("5m")
                    Text("30 минут (рекомендуется)").tag("30m")
                    Text("1 час").tag("1h")
                    Text("Всегда (-1)").tag("-1")
                }

                Toggle("Отключать режим рассуждений (think: false — ускоряет Qwen3.5)", isOn: $store.config.disableThinking)
            }

            Section("Поведение перевода") {
                Picker("Стиль по умолчанию", selection: $store.config.defaultTone) {
                    ForEach(TonePreset.allCases) { tone in
                        Text("\(tone.title) — \(tone.subtitle)").tag(tone)
                    }
                }

                Toggle("Если текст не выделен — переводить всё поле ввода (авто ⌘A при замене)", isOn: $store.config.autoSelectAllWhenEmpty)

                Toggle("Восстанавливать буфер обмена после замены текста", isOn: $store.config.restoreClipboardAfterReplace)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Дополнительные инструкции для модели (опционально):")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    TextField("Например: Обращайся на «вы», не переводи названия брендов...", text: $store.config.customSystemNotes)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section("Озвучка произношения (TTS)") {
                Picker("Движок озвучки", selection: $store.config.ttsEngine) {
                    ForEach(TTSEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }

                if store.config.ttsEngine == .kokoro {
                    Picker("Голос Kokoro-82M", selection: $store.config.kokoroVoice) {
                        ForEach(KokoroVoiceOption.presets) { option in
                            Text(option.label).tag(option.id)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: vm.kokoroInstalled ? "checkmark.seal.fill" : "arrow.down.circle")
                                .foregroundColor(vm.kokoroInstalled ? .green : .orange)
                            Text(vm.kokoroInstalled
                                 ? (SpeechHelper.isUsingRustBackend
                                    ? "Kokoro-82M готов (нативный Rust-движок — без Python, автовыгрузка 10 мин)"
                                    : "Kokoro-82M установлен и работает локально офлайн")
                                 : "Файлы модели Kokoro (~338 МБ) не скачаны — используется системный голос")
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                            Spacer()

                            if downloader.isDownloading {
                                Button("Отмена") {
                                    downloader.cancel()
                                }
                                .controlSize(.small)
                            } else if !vm.kokoroInstalled {
                                Button("Скачать модель (~338 МБ)") {
                                    downloader.startDownload {
                                        vm.refreshSystemStatus()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            } else {
                                Button("Удалить веса") {
                                    downloader.removeModels {
                                        vm.refreshSystemStatus()
                                    }
                                }
                                .controlSize(.small)
                            }
                        }

                        if downloader.isDownloading {
                            ProgressView(value: downloader.progress)
                                .progressViewStyle(.linear)
                            Text(downloader.statusText)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        } else if let err = downloader.errorMessage {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                        } else if !downloader.statusText.isEmpty {
                            Text(downloader.statusText)
                                .font(.system(size: 11))
                                .foregroundColor(.green)
                        }
                    }
                } else {
                    Picker("Системный голос EN", selection: $store.config.systemVoiceIdentifier) {
                        Text("Авто (лучший доступный en-US)").tag("")
                        ForEach(SpeechHelper.installedEnglishSystemVoices(), id: \.identifier) { voice in
                            Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                        }
                    }
                }

                HStack {
                    Text(String(format: "Скорость речи: %.2fx", store.config.ttsSpeed))
                        .font(.system(size: 12.5))
                    Slider(value: $store.config.ttsSpeed, in: 0.75...1.25, step: 0.05)
                    Button {
                        SpeechHelper.shared.speakEnglish("Just a quick heads-up regarding the timeline. Everything looks great on my end!")
                    } label: {
                        Label("Тест голоса", systemImage: "speaker.wave.2.fill")
                    }
                    .controlSize(.small)
                }
            }

            Section("Система и разрешения") {
                Toggle("Запускать автоматически при входе в macOS", isOn: Binding(
                    get: { vm.launchAtLogin },
                    set: { vm.setLaunchAtLogin($0) }
                ))

                HStack {
                    Image(systemName: vm.accessibilityGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(vm.accessibilityGranted ? .green : .orange)
                    Text(vm.accessibilityGranted
                         ? "Универсальный доступ (Accessibility) выдан"
                         : "Нужен Универсальный доступ для захвата и замены текста")
                        .font(.system(size: 12.5))
                    Spacer()
                    Button("Обновить") {
                        vm.refreshSystemStatus()
                    }
                    Button("Открыть настройки") {
                        TextAutomation.openAccessibilitySettings()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            vm.refreshSystemStatus()
        }
    }
}

private struct GlossarySettingsTab: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Словарь замен и терминов")
                        .font(.headline)
                    Text("Укажите слова, которые нужно всегда переводить или заменять определённым образом.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Открыть JSON") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.configFileURL])
                }
                .controlSize(.small)
            }

            // Quick add row
            HStack(spacing: 8) {
                TextField("Слово / фраза (напр. созвон)", text: $vm.newSource)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                TextField("Заменить на (напр. quick call)", text: $vm.newTarget)
                    .textFieldStyle(.roundedBorder)

                Picker("", selection: $vm.newDirection) {
                    ForEach(TranslationDirection.glossaryDirections) { dir in
                        Text(dir.shortBadge).tag(dir)
                    }
                }
                .labelsHidden()
                .frame(width: 84)

                Picker("", selection: $vm.newMode) {
                    ForEach(GlossaryMatchMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 124)

                Button("Добавить") {
                    store.addGlossaryEntry(
                        source: vm.newSource,
                        target: vm.newTarget,
                        direction: vm.newDirection,
                        mode: vm.newMode
                    )
                    vm.newSource = ""
                    vm.newTarget = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.newSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          vm.newTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 14) {
                Label("Подсказка ИИ: модель учтёт термин и естественно просклоняет в тексте", systemImage: "sparkles")
                Label("Точная замена: жёстко подставит слово после перевода", systemImage: "textformat.abc")
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)

            if store.config.glossary.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "book.closed")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("Словарь пока пуст")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("Например: «созвон» → «quick call», «ТЗ» → «project specs», «деплой» → «deployment»")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Button("Добавить 3 примера для общения с клиентами") {
                        store.addGlossaryEntry(source: "созвон", target: "quick call", direction: .ruToEn, mode: .promptHint)
                        store.addGlossaryEntry(source: "ТЗ", target: "project specs", direction: .ruToEn, mode: .promptHint)
                        store.addGlossaryEntry(source: "дедлайн", target: "deadline", direction: .ruToEn, mode: .exactReplace)
                    }
                    .controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } else {
                List {
                    ForEach($store.config.glossary) { $entry in
                        HStack(spacing: 8) {
                            Toggle("", isOn: $entry.enabled)
                                .labelsHidden()

                            TextField("Исходное", text: $entry.source)
                                .textFieldStyle(.roundedBorder)

                            Image(systemName: "arrow.right")
                                .foregroundColor(.secondary)

                            TextField("Замена", text: $entry.target)
                                .textFieldStyle(.roundedBorder)

                            Picker("", selection: $entry.direction) {
                                ForEach(TranslationDirection.glossaryDirections) { dir in
                                    Text(dir.shortBadge).tag(dir)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 80)

                            Picker("", selection: $entry.mode) {
                                ForEach(GlossaryMatchMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 120)

                            Button {
                                store.removeGlossaryEntry(id: entry.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct HotkeysSettingsTab: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var vm: SettingsViewModel
    let onHotkeysUpdated: () -> Void

    var body: some View {
        Form {
            Section("Глобальные сочетания клавиш (работают в любой раскладке RU/EN)") {
                hotkeyRow(
                    title: "Перевести и заменить выделенный текст",
                    subtitle: "Заменяет текст прямо в поле ввода (или всё поле, если ничего не выделено)",
                    action: .translateAndReplace,
                    binding: store.config.replaceHotkey
                )

                hotkeyRow(
                    title: "Показать перевод во всплывающем окне",
                    subtitle: "Стриминг в реальном времени, смена стиля, другой вариант и быстрый ответ клиенту",
                    action: .translatePopup,
                    binding: store.config.popupHotkey
                )

                hotkeyRow(
                    title: "Улучшить мой английский (Polish EN ✨ EN)",
                    subtitle: "Исправляет ошибки и делает английский естественным, заменяя текст на месте",
                    action: .polishEnglish,
                    binding: store.config.polishHotkey
                )

                hotkeyRow(
                    title: "Открыть окно быстрого переводчика",
                    subtitle: "Отдельное окно, где удобно набрать ответ клиенту и подобрать тон",
                    action: .openQuickWindow,
                    binding: store.config.quickWindowHotkey
                )

                hotkeyRow(
                    title: "Открыть тренажёр английского (Карточки SRS)",
                    subtitle: "Интервальное повторение сохранённых фраз, озвучка и проверка с ИИ",
                    action: .openFlashcards,
                    binding: store.config.flashcardsHotkey
                )
            }

            Section {
                HStack {
                    Text("Нажмите на кнопку сочетания клавиш, затем нажмите нужную комбинацию с ⌘, ⌥, ⌃ или ⇧.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Сбросить по умолчанию") {
                        vm.stopRecording()
                        store.resetHotkeys()
                        onHotkeysUpdated()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func hotkeyRow(title: String, subtitle: String, action: HotkeyAction, binding: HotkeyBinding) -> some View {
        let isRecording = (vm.recordingAction == action)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                vm.toggleRecording(for: action, store: store, onHotkeysUpdated: onHotkeysUpdated)
            } label: {
                Text(isRecording ? "Нажмите клавиши..." : binding.displayString)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 118)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)
        }
    }
}

private struct HistorySettingsTab: View {
    @ObservedObject var historyStore: HistoryStore
    @ObservedObject var vm: SettingsViewModel

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private var filteredEntries: [HistoryEntry] {
        let q = vm.historySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return historyStore.entries }
        return historyStore.entries.filter {
            $0.originalText.lowercased().contains(q) || $0.translatedText.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Поиск по истории переводов...", text: $vm.historySearch)
                    .textFieldStyle(.roundedBorder)

                Button("Очистить всё") {
                    historyStore.clear()
                }
                .disabled(historyStore.entries.isEmpty)
            }

            if filteredEntries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text(historyStore.entries.isEmpty ? "История пока пуста" : "Ничего не найдено")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } else {
                List {
                    ForEach(filteredEntries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(entry.direction.shortBadge)
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                                    .foregroundColor(.accentColor)

                                Text(entry.tone.title)
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary)

                                Text("• \(Self.timeFormatter.string(from: entry.timestamp))")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary)

                                Spacer()

                                Button {
                                    let en = (entry.direction == .enToRu) ? entry.originalText : entry.translatedText
                                    let ru = (entry.direction == .enToRu) ? entry.translatedText : entry.originalText
                                    VocabStore.shared.addCard(english: en, russian: ru)
                                } label: {
                                    Image(systemName: VocabStore.shared.contains(english: (entry.direction == .enToRu) ? entry.originalText : entry.translatedText) ? "bookmark.fill" : "bookmark")
                                        .font(.system(size: 11))
                                        .foregroundColor(.orange)
                                }
                                .buttonStyle(.plain)
                                .help("Сохранить фразу в тренажёр английского")

                                Button {
                                    vm.copyHistoryItem(entry)
                                } label: {
                                    Label(
                                        vm.copiedHistoryID == entry.id ? "Скопировано" : "Копировать",
                                        systemImage: vm.copiedHistoryID == entry.id ? "checkmark" : "doc.on.doc"
                                    )
                                    .font(.system(size: 11))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)

                                Button {
                                    historyStore.remove(id: entry.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }

                            Text(entry.translatedText)
                                .font(.system(size: 13))
                                .textSelection(.enabled)

                            Text(entry.originalText)
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
