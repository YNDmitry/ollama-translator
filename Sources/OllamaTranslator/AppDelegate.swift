import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let configStore = ConfigStore.shared
    private let historyStore = HistoryStore.shared
    private let ollamaClient = OllamaClient()
    private let hud = HUDController()
    private var hotkeyManager: HotkeyManager?

    private var settingsWindow: NSWindow?
    private let settingsViewModel = SettingsViewModel()
    private var quickWindow: NSWindow?
    private var quickViewModel: QuickTranslatorViewModel?

    private var currentTask: Task<Void, Never>?
    private var replyTask: Task<Void, Never>?
    private var explainTask: Task<Void, Never>?
    private var lastPopupResult: TranslationResult?
    private var lastTargetApp: NSRunningApplication?
    private var pendingClipboardSnapshot: PasteboardSnapshot?

    private var ollamaOnline: Bool? = nil
    private var ollamaModelFound: Bool = true
    private var lastHealthCheck: Date = .distantPast

    private var isTranslating = false {
        didSet { updateStatusIcon() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupHUDCallbacks()
        setupHotkeys()

        configStore.onConfigChanged = { [weak self] cfg in
            self?.hotkeyManager?.registerAll(from: cfg)
        }

        // Check Ollama health & warm up model in background
        Task {
            await refreshOllamaHealth(force: true)
            if ollamaOnline == true {
                try? await ollamaClient.warmup(config: configStore.config)
            }
        }

        if !TextAutomation.isAccessibilityGranted(prompt: false) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showFirstRunAccessibilityAlert()
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let symbolName: String
        if isTranslating {
            symbolName = "ellipsis.bubble.fill"
        } else if ollamaOnline == false {
            symbolName = "exclamationmark.bubble"
        } else {
            symbolName = "character.bubble"
        }
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Ollama Translator")
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "Ollama Translator")
        img?.isTemplate = true
        button.image = img
        button.toolTip = ollamaOnline == false
            ? "Ollama Translator (Ollama не запущена)"
            : "Ollama Translator (RU ↔ EN)"
    }

    private func refreshOllamaHealth(force: Bool = false) async {
        if !force && Date().timeIntervalSince(lastHealthCheck) < 6 {
            return
        }
        lastHealthCheck = Date()
        let cfg = configStore.config
        let health = await ollamaClient.checkHealth(baseURL: cfg.ollamaBaseURL, modelName: cfg.modelName)
        ollamaOnline = health.online
        ollamaModelFound = health.modelAvailable
        updateStatusIcon()
    }

    private func setupHotkeys() {
        hotkeyManager = HotkeyManager { [weak self] action in
            Task { @MainActor in
                self?.handleHotkey(action)
            }
        }
        hotkeyManager?.registerAll(from: configStore.config)
    }

    private func setupHUDCallbacks() {
        hud.onCopy = { [weak self] text in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            self?.hud.showToast(icon: "checkmark.circle.fill", message: "Скопировано в буфер обмена", duration: 1.1)
        }

        hud.onReplace = { [weak self] text in
            guard let self = self else { return }
            let targetApp = self.lastTargetApp
            self.hud.hide()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                await TextAutomation.replaceSelectedText(
                    with: text,
                    restoreClipboard: self.configStore.config.restoreClipboardAfterReplace,
                    targetApp: targetApp
                )
                self.hud.showToast(icon: "checkmark.circle.fill", message: "Текст заменён", duration: 1.1)
            }
        }

        hud.onPasteReply = { [weak self] replyText in
            guard let self = self else { return }
            let targetApp = self.lastTargetApp
            self.hud.hide()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                await TextAutomation.replaceSelectedText(
                    with: replyText,
                    restoreClipboard: self.configStore.config.restoreClipboardAfterReplace,
                    targetApp: targetApp
                )
                self.hud.showToast(icon: "checkmark.circle.fill", message: "Ответ вставлен", duration: 1.1)
            }
        }

        hud.onChangeTone = { [weak self] newTone in
            guard let self = self, let prev = self.lastPopupResult else { return }
            self.rerunPopupTranslation(
                originalText: prev.originalText,
                direction: prev.direction,
                tone: newTone,
                alternativeTo: nil
            )
        }

        hud.onRegenerate = { [weak self] in
            guard let self = self, let prev = self.lastPopupResult else { return }
            self.rerunPopupTranslation(
                originalText: prev.originalText,
                direction: prev.direction,
                tone: prev.tone,
                alternativeTo: prev.translatedText
            )
        }

        hud.onPolishResult = { [weak self] in
            guard let self = self, let prev = self.lastPopupResult else { return }
            let sourceEnglish = (prev.direction == .enToRu) ? prev.originalText : prev.translatedText
            self.rerunPopupTranslation(
                originalText: sourceEnglish,
                direction: .polishEn,
                tone: prev.tone,
                alternativeTo: nil
            )
        }

        hud.onSpeakEnglish = { text in
            SpeechHelper.shared.speakEnglish(text)
        }

        hud.onExplainPhrase = { [weak self] in
            guard let self = self else { return }
            let orig = self.hud.viewModel.originalText
            let trans = self.hud.viewModel.translatedText
            let dir = self.hud.viewModel.direction
            let cfg = self.configStore.config

            self.explainTask?.cancel()
            self.hud.viewModel.explanationError = nil
            self.hud.viewModel.explanationText = ""
            self.hud.viewModel.isExplaining = true
            self.isTranslating = true

            self.explainTask = Task { @MainActor in
                do {
                    let explanation = try await self.ollamaClient.explainPhraseStream(
                        originalText: orig,
                        translatedText: trans,
                        direction: dir,
                        config: cfg
                    ) { [weak self] partial in
                        Task { @MainActor in
                            self?.hud.viewModel.explanationText = partial
                        }
                    }
                    guard !Task.isCancelled else { return }
                    self.hud.viewModel.explanationText = explanation
                    self.hud.viewModel.isExplaining = false
                    self.isTranslating = false
                } catch OllamaError.cancelled {
                    self.hud.viewModel.isExplaining = false
                    self.isTranslating = false
                } catch {
                    guard !Task.isCancelled else { return }
                    self.hud.viewModel.explanationError = error.localizedDescription
                    self.hud.viewModel.isExplaining = false
                    self.isTranslating = false
                }
            }
        }

        hud.onSendReply = { [weak self] russianReply in
            guard let self = self else { return }
            let clientMessage = self.hud.viewModel.originalText
            let activeTone = self.hud.viewModel.tone
            let cfg = self.configStore.config

            self.replyTask?.cancel()
            self.hud.viewModel.replyError = nil
            self.hud.viewModel.replyOutput = ""
            self.hud.viewModel.isGeneratingReply = true
            self.isTranslating = true

            self.replyTask = Task { @MainActor in
                do {
                    let res = try await self.ollamaClient.translateContextReplyStream(
                        clientMessage: clientMessage,
                        userReply: russianReply,
                        config: cfg,
                        tone: activeTone
                    ) { [weak self] partial in
                        Task { @MainActor in
                            self?.hud.viewModel.replyOutput = partial
                            self?.hud.viewModel.onLayoutChanged?()
                        }
                    }
                    guard !Task.isCancelled else { return }
                    self.hud.viewModel.replyOutput = res.translatedText
                    self.hud.viewModel.isGeneratingReply = false
                    self.hud.viewModel.onLayoutChanged?()
                    self.isTranslating = false
                    self.historyStore.record(res)
                } catch OllamaError.cancelled {
                    self.hud.viewModel.isGeneratingReply = false
                    self.isTranslating = false
                } catch {
                    guard !Task.isCancelled else { return }
                    self.hud.viewModel.replyError = error.localizedDescription
                    self.hud.viewModel.isGeneratingReply = false
                    self.isTranslating = false
                }
            }
        }

        hud.onAddQuickGlossary = { [weak self] source, target, direction, mode in
            self?.configStore.addGlossaryEntry(
                source: source,
                target: target,
                direction: direction,
                mode: mode
            )
        }

        hud.onOpenFullGlossary = { [weak self] in
            self?.hud.hide()
            self?.openSettings(tab: .glossary)
        }

        hud.onCancelWork = { [weak self] in
            guard let self = self else { return }
            self.currentTask?.cancel()
            self.replyTask?.cancel()
            self.explainTask?.cancel()
            SpeechHelper.shared.stop()
            self.isTranslating = false
            self.hud.viewModel.isStreaming = false
            self.hud.viewModel.isGeneratingReply = false
            self.hud.viewModel.isExplaining = false
            if let saved = self.pendingClipboardSnapshot {
                TextAutomation.restorePasteboard(saved)
                self.pendingClipboardSnapshot = nil
            }
            if case .loading = self.hud.viewModel.state {
                self.hud.showToast(icon: "xmark.circle", message: "Перевод отменён", duration: 1.0)
            }
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cfg = configStore.config

        // Trigger background refresh for next open
        Task { await refreshOllamaHealth(force: false) }

        // Status header
        let statusText: String
        if ollamaOnline == true {
            statusText = ollamaModelFound ? "● Ollama подключена" : "● Ollama онлайн (модель не найдена)"
        } else if ollamaOnline == false {
            statusText = "○ Ollama не запущена"
        } else {
            statusText = "◌ Проверка Ollama..."
        }
        let statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        let modelShort = cfg.modelName.components(separatedBy: "/").last ?? cfg.modelName
        let modelItem = NSMenuItem(title: "Модель: \(modelShort)", action: nil, keyEquivalent: "")
        modelItem.isEnabled = false
        menu.addItem(modelItem)

        if ollamaOnline == false {
            let startOllamaItem = NSMenuItem(title: "▶ Запустить Ollama", action: #selector(menuStartOllama), keyEquivalent: "")
            startOllamaItem.target = self
            menu.addItem(startOllamaItem)
        }

        menu.addItem(.separator())

        let replaceItem = NSMenuItem(
            title: "Перевести и заменить (\(cfg.replaceHotkey.displayString))",
            action: #selector(menuTriggerReplace),
            keyEquivalent: ""
        )
        replaceItem.target = self
        menu.addItem(replaceItem)

        let popupItem = NSMenuItem(
            title: "Показать перевод в окне (\(cfg.popupHotkey.displayString))",
            action: #selector(menuTriggerPopup),
            keyEquivalent: ""
        )
        popupItem.target = self
        menu.addItem(popupItem)

        let polishItem = NSMenuItem(
            title: "Улучшить английский (\(cfg.polishHotkey.displayString))",
            action: #selector(menuTriggerPolish),
            keyEquivalent: ""
        )
        polishItem.target = self
        menu.addItem(polishItem)

        let quickItem = NSMenuItem(
            title: "Быстрый переводчик (\(cfg.quickWindowHotkey.displayString))",
            action: #selector(menuOpenQuickWindow),
            keyEquivalent: ""
        )
        quickItem.target = self
        menu.addItem(quickItem)

        menu.addItem(.separator())

        // Tone selector submenu
        let toneMenuItem = NSMenuItem(title: "Стиль: \(cfg.defaultTone.title)", action: nil, keyEquivalent: "")
        let toneSubmenu = NSMenu()
        for tone in TonePreset.allCases {
            let item = NSMenuItem(title: "\(tone.title) — \(tone.subtitle)", action: #selector(selectTone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tone.rawValue
            item.state = (tone == cfg.defaultTone) ? .on : .off
            toneSubmenu.addItem(item)
        }
        toneMenuItem.submenu = toneSubmenu
        menu.addItem(toneMenuItem)

        // Glossary quick access
        let activeGlossaryCount = cfg.glossary.filter { $0.enabled }.count
        let glossaryItem = NSMenuItem(
            title: "Словарь замен (\(activeGlossaryCount))...",
            action: #selector(menuOpenGlossary),
            keyEquivalent: ""
        )
        glossaryItem.target = self
        menu.addItem(glossaryItem)

        // History submenu
        let historyCount = historyStore.entries.count
        let historyMenuItem = NSMenuItem(title: "История переводов (\(historyCount))", action: nil, keyEquivalent: "")
        let historySubmenu = NSMenu()
        if historyStore.entries.isEmpty {
            let emptyItem = NSMenuItem(title: "Пока пусто", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            historySubmenu.addItem(emptyItem)
        } else {
            for entry in historyStore.entries.prefix(10) {
                let preview = entry.translatedText
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(46)
                let ellipsis = entry.translatedText.count > 46 ? "…" : ""
                let item = NSMenuItem(
                    title: "[\(entry.direction.shortBadge)] \(preview)\(ellipsis)",
                    action: #selector(copyFromHistoryMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = entry.translatedText
                historySubmenu.addItem(item)
            }
            historySubmenu.addItem(.separator())
            let allHistoryItem = NSMenuItem(title: "Открыть всю историю...", action: #selector(menuOpenHistory), keyEquivalent: "")
            allHistoryItem.target = self
            historySubmenu.addItem(allHistoryItem)
        }
        historyMenuItem.submenu = historySubmenu
        menu.addItem(historyMenuItem)

        // Warmup model
        let warmupItem = NSMenuItem(title: "Прогреть модель в памяти", action: #selector(menuWarmupModel), keyEquivalent: "")
        warmupItem.target = self
        menu.addItem(warmupItem)

        menu.addItem(.separator())

        if !TextAutomation.isAccessibilityGranted(prompt: false) {
            let axItem = NSMenuItem(title: "⚠️ Выдать Универсальный доступ...", action: #selector(menuOpenAccessibility), keyEquivalent: "")
            axItem.target = self
            menu.addItem(axItem)
            menu.addItem(.separator())
        }

        let settingsItem = NSMenuItem(title: "Настройки...", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    // MARK: - Menu Actions

    @objc private func menuTriggerReplace() {
        handleHotkey(.translateAndReplace)
    }

    @objc private func menuTriggerPopup() {
        handleHotkey(.translatePopup)
    }

    @objc private func menuTriggerPolish() {
        handleHotkey(.polishEnglish)
    }

    @objc private func menuOpenQuickWindow() {
        openQuickTranslator()
    }

    @objc private func menuOpenGlossary() {
        openSettings(tab: .glossary)
    }

    @objc private func menuOpenHistory() {
        openSettings(tab: .history)
    }

    @objc private func menuOpenSettings() {
        openSettings(tab: .general)
    }

    @objc private func menuOpenAccessibility() {
        TextAutomation.openAccessibilitySettings()
    }

    @objc private func copyFromHistoryMenu(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        hud.showToast(icon: "checkmark.circle.fill", message: "Скопировано из истории", duration: 1.1)
    }

    @objc private func menuStartOllama() {
        let appURL = URL(fileURLWithPath: "/Applications/Ollama.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/local/bin/ollama")
            proc.arguments = ["serve"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
        }
        hud.showToast(icon: "bolt.fill", message: "Запускаю Ollama...", duration: 1.8)
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refreshOllamaHealth(force: true)
        }
    }

    @objc private func selectTone(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let tone = TonePreset(rawValue: raw) else { return }
        configStore.config.defaultTone = tone
    }

    @objc private func menuWarmupModel() {
        hud.showLoading(direction: .auto, subtitle: "Загружаю модель в память...")
        isTranslating = true
        currentTask = Task {
            do {
                try await ollamaClient.warmup(config: configStore.config)
                guard !Task.isCancelled else { return }
                ollamaOnline = true
                ollamaModelFound = true
                isTranslating = false
                hud.showToast(icon: "bolt.fill", message: "Модель готова к быстрому переводу", duration: 1.6)
            } catch {
                guard !Task.isCancelled else { return }
                isTranslating = false
                hud.showToast(icon: "exclamationmark.triangle.fill", isError: true, message: error.localizedDescription, duration: 3.0)
            }
        }
    }

    // MARK: - Core Workflows

    private func handleHotkey(_ action: HotkeyAction) {
        switch action {
        case .translateAndReplace:
            runSelectedTextTranslation(replaceInPlace: true, forcePolish: false)
        case .translatePopup:
            runSelectedTextTranslation(replaceInPlace: false, forcePolish: false)
        case .polishEnglish:
            runSelectedTextTranslation(replaceInPlace: true, forcePolish: true)
        case .openQuickWindow:
            openQuickTranslator()
        }
    }

    private func runSelectedTextTranslation(replaceInPlace: Bool, forcePolish: Bool) {
        guard TextAutomation.isAccessibilityGranted(prompt: false) else {
            _ = TextAutomation.isAccessibilityGranted(prompt: true)
            hud.showToast(
                icon: "lock.shield",
                isError: true,
                message: "Разрешите Универсальный доступ для OllamaTranslator в Системных настройках",
                duration: 3.5
            )
            return
        }

        let triggerPoint = NSEvent.mouseLocation
        let frontApp = NSWorkspace.shared.frontmostApplication
        if frontApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastTargetApp = frontApp
        }

        currentTask?.cancel()
        replyTask?.cancel()
        pendingClipboardSnapshot = nil
        isTranslating = true

        let cfg = configStore.config
        let allowAutoSelect = replaceInPlace && cfg.autoSelectAllWhenEmpty

        currentTask = Task { @MainActor in
            let capture = await TextAutomation.captureSelectedText(allowAutoSelectAll: allowAutoSelect)

            if capture.autoSelectTooLong {
                if capture.usedClipboard, let saved = capture.savedClipboard {
                    TextAutomation.restorePasteboard(saved)
                }
                self.isTranslating = false
                self.hud.showToast(
                    icon: "text.badge.xmark",
                    isError: true,
                    message: "Текст слишком длинный для автовыбора — выделите нужный фрагмент вручную",
                    duration: 2.4,
                    near: triggerPoint
                )
                return
            }

            guard let selectedText = capture.text,
                  !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if capture.usedClipboard, let saved = capture.savedClipboard {
                    TextAutomation.restorePasteboard(saved)
                }
                self.isTranslating = false
                self.hud.showToast(icon: "text.cursor", isError: true, message: "Сначала выделите текст", duration: 1.5, near: triggerPoint)
                return
            }

            if !replaceInPlace, capture.usedClipboard, let saved = capture.savedClipboard {
                TextAutomation.restorePasteboard(saved)
            } else if replaceInPlace, capture.usedClipboard {
                self.pendingClipboardSnapshot = capture.savedClipboard
            }

            let direction: TranslationDirection = forcePolish
                ? .polishEn
                : LanguageDetector.detectDirection(for: selectedText)

            if replaceInPlace {
                let label = forcePolish ? "Улучшаю английский..." : "Перевожу и заменяю..."
                self.hud.showLoading(direction: direction, subtitle: label, near: triggerPoint)

                do {
                    let result = try await self.ollamaClient.translate(
                        text: selectedText,
                        config: cfg,
                        directionOverride: forcePolish ? .polishEn : nil
                    )
                    guard !Task.isCancelled else { return }
                    self.ollamaOnline = true
                    self.isTranslating = false
                    self.pendingClipboardSnapshot = nil

                    await TextAutomation.replaceSelectedText(
                        with: result.translatedText,
                        restoreClipboard: cfg.restoreClipboardAfterReplace,
                        existingSnapshot: capture.savedClipboard
                    )
                    self.historyStore.record(result)

                    let sec = String(format: "%.1f", Double(result.durationMs) / 1000.0)
                    let doneMsg = forcePolish
                        ? "Английский улучшен • \(sec) сек"
                        : "Переведено (\(result.direction.shortBadge)) • \(sec) сек"
                    self.hud.showToast(icon: "checkmark.circle.fill", message: doneMsg, duration: 1.4, near: triggerPoint)
                } catch OllamaError.cancelled {
                    self.isTranslating = false
                } catch {
                    guard !Task.isCancelled else { return }
                    if let saved = self.pendingClipboardSnapshot {
                        TextAutomation.restorePasteboard(saved)
                        self.pendingClipboardSnapshot = nil
                    }
                    self.isTranslating = false
                    self.hud.showToast(icon: "exclamationmark.triangle.fill", isError: true, message: error.localizedDescription, duration: 3.2, near: triggerPoint)
                }
            } else {
                // Popup mode with instant live streaming!
                self.hud.startStreamingPopup(
                    originalText: selectedText,
                    direction: direction,
                    tone: cfg.defaultTone,
                    near: triggerPoint,
                    resetDrawers: true
                )

                do {
                    let result = try await self.ollamaClient.translateStream(
                        text: selectedText,
                        config: cfg,
                        directionOverride: direction
                    ) { [weak self] partial in
                        Task { @MainActor in
                            self?.hud.updateStreamingPopup(partialText: partial)
                        }
                    }
                    guard !Task.isCancelled else { return }
                    self.ollamaOnline = true
                    self.lastPopupResult = result
                    self.isTranslating = false
                    self.hud.finishStreamingPopup(result: result)
                    self.historyStore.record(result)
                } catch OllamaError.cancelled {
                    self.isTranslating = false
                    self.hud.viewModel.isStreaming = false
                } catch {
                    guard !Task.isCancelled else { return }
                    self.isTranslating = false
                    self.hud.showToast(icon: "exclamationmark.triangle.fill", isError: true, message: error.localizedDescription, duration: 3.2, near: triggerPoint)
                }
            }
        }
    }

    private func rerunPopupTranslation(
        originalText: String,
        direction: TranslationDirection,
        tone: TonePreset,
        alternativeTo: String?
    ) {
        currentTask?.cancel()
        isTranslating = true

        hud.startStreamingPopup(
            originalText: originalText,
            direction: direction,
            tone: tone,
            near: nil,
            resetDrawers: false
        )

        let cfg = configStore.config
        currentTask = Task { @MainActor in
            do {
                let result = try await self.ollamaClient.translateStream(
                    text: originalText,
                    config: cfg,
                    toneOverride: tone,
                    directionOverride: direction,
                    alternativeTo: alternativeTo
                ) { [weak self] partial in
                    Task { @MainActor in
                        self?.hud.updateStreamingPopup(partialText: partial)
                    }
                }
                guard !Task.isCancelled else { return }
                self.lastPopupResult = result
                self.isTranslating = false
                self.hud.finishStreamingPopup(result: result)
                self.historyStore.record(result)
            } catch OllamaError.cancelled {
                self.isTranslating = false
                self.hud.viewModel.isStreaming = false
            } catch {
                guard !Task.isCancelled else { return }
                self.isTranslating = false
                self.hud.showToast(icon: "exclamationmark.triangle.fill", isError: true, message: error.localizedDescription, duration: 3.0)
            }
        }
    }

    // MARK: - Windows

    private func openSettings(tab: SettingsTab) {
        settingsViewModel.selectedTab = tab
        settingsViewModel.refreshSystemStatus()

        if let win = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = SettingsRootView(
            store: configStore,
            historyStore: historyStore,
            vm: settingsViewModel,
            ollamaClient: ollamaClient,
            onHotkeysUpdated: { [weak self] in
                guard let self = self else { return }
                self.hotkeyManager?.registerAll(from: self.configStore.config)
            }
        )

        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Настройки Ollama Translator"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()

        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func openQuickTranslator() {
        if let win = quickWindow {
            quickViewModel?.tone = configStore.config.defaultTone
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }

        let vm = QuickTranslatorViewModel(client: ollamaClient)
        quickViewModel = vm

        let view = QuickTranslatorView(vm: vm) { [weak self] in
            self?.openSettings(tab: .glossary)
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Быстрый переводчик (RU ↔ EN)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()

        quickWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showFirstRunAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Нужен доступ к «Универсальному доступу»"
        alert.informativeText = """
        Чтобы OllamaTranslator мог считывать выделенный текст и заменять его переводом в Telegram, Slack, браузере и других приложениях, добавьте его в:

        Системные настройки → Конфиденциальность и безопасность → Универсальный доступ (Accessibility).
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Позже")

        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            _ = TextAutomation.isAccessibilityGranted(prompt: true)
            TextAutomation.openAccessibilitySettings()
        }
    }
}
