import AppKit
import SwiftUI

enum HUDState {
    case hidden
    case loading(direction: TranslationDirection, subtitle: String)
    case toast(icon: String, isError: Bool, message: String)
    case popup
}

@MainActor
final class HUDViewModel: ObservableObject {
    @Published var state: HUDState = .hidden
    @Published var showOriginal: Bool = false

    // Popup translation state
    @Published var originalText: String = ""
    @Published var translatedText: String = ""
    @Published var direction: TranslationDirection = .ruToEn
    @Published var tone: TonePreset = .business
    @Published var durationMs: Int? = nil
    @Published var isStreaming: Bool = false

    // Inline Contextual Reply drawer
    @Published var showReplyBox: Bool = false
    @Published var replyInput: String = ""
    @Published var replyOutput: String = ""
    @Published var isGeneratingReply: Bool = false
    @Published var replyError: String? = nil

    // Inline Quick Glossary bar
    @Published var showQuickGlossary: Bool = false
    @Published var quickGlossSource: String = ""
    @Published var quickGlossTarget: String = ""
    @Published var quickGlossMode: GlossaryMatchMode = .promptHint
    @Published var quickGlossSavedNotice: Bool = false

    // Inline AI English Coach ("Разбор фразы") + Phrase Extractor
    @Published var showExplanation: Bool = false
    @Published var explanationText: String = ""
    @Published var isExplaining: Bool = false
    @Published var explanationError: String? = nil
    @Published var isSavedToVocab: Bool = false
    @Published var extractedPhrases: [ExtractedPhrase] = []
    @Published var isExtractingPhrases: Bool = false
    @Published var savedExtractedIDs: Set<UUID> = []

    var onCopy: ((String) -> Void)?
    var onReplace: ((String) -> Void)?
    var onChangeTone: ((TonePreset) -> Void)?
    var onRegenerate: (() -> Void)?
    var onPolishResult: (() -> Void)?
    var onSpeakEnglish: ((String) -> Void)?
    var onExplainPhrase: (() -> Void)?
    var onExtractPhrases: (() -> Void)?
    var onSaveExtractedPhrase: ((ExtractedPhrase) -> Void)?
    var onSaveToVocab: (() -> Void)?
    var onSendReply: ((String) -> Void)?
    var onPasteReply: ((String) -> Void)?
    var onAddQuickGlossary: ((String, String, TranslationDirection, GlossaryMatchMode) -> Void)?
    var onOpenFullGlossary: (() -> Void)?
    var onCancelWork: (() -> Void)?
    var onClose: (() -> Void)?
    var onLayoutChanged: (() -> Void)?

    var englishTextForSpeech: String {
        let raw = (direction == .enToRu) ? originalText : translatedText
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func resetPopupDrawers() {
        showOriginal = false
        showReplyBox = false
        replyInput = ""
        replyOutput = ""
        isGeneratingReply = false
        replyError = nil
        showQuickGlossary = false
        quickGlossSource = ""
        quickGlossTarget = ""
        quickGlossSavedNotice = false
        showExplanation = false
        explanationText = ""
        isExplaining = false
        explanationError = nil
        extractedPhrases = []
        isExtractingPhrases = false
        savedExtractedIDs = []
    }
}

private final class FloatingHUDPanel: NSPanel {
    var allowsKeyFocus: Bool = false
    override var canBecomeKey: Bool { allowsKeyFocus }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HUDController {
    private let panel: FloatingHUDPanel
    let viewModel = HUDViewModel()
    private var dismissTimer: Timer?
    private var clickOutsideMonitor: Any?
    private var globalEscMonitor: Any?
    private var localEscMonitor: Any?
    private var anchorPoint: NSPoint = NSEvent.mouseLocation

    var onCopy: ((String) -> Void)? {
        get { viewModel.onCopy }
        set { viewModel.onCopy = newValue }
    }
    var onReplace: ((String) -> Void)? {
        get { viewModel.onReplace }
        set { viewModel.onReplace = newValue }
    }
    var onChangeTone: ((TonePreset) -> Void)? {
        get { viewModel.onChangeTone }
        set { viewModel.onChangeTone = newValue }
    }
    var onRegenerate: (() -> Void)? {
        get { viewModel.onRegenerate }
        set { viewModel.onRegenerate = newValue }
    }
    var onPolishResult: (() -> Void)? {
        get { viewModel.onPolishResult }
        set { viewModel.onPolishResult = newValue }
    }
    var onSpeakEnglish: ((String) -> Void)? {
        get { viewModel.onSpeakEnglish }
        set { viewModel.onSpeakEnglish = newValue }
    }
    var onExplainPhrase: (() -> Void)? {
        get { viewModel.onExplainPhrase }
        set { viewModel.onExplainPhrase = newValue }
    }
    var onExtractPhrases: (() -> Void)? {
        get { viewModel.onExtractPhrases }
        set { viewModel.onExtractPhrases = newValue }
    }
    var onSaveExtractedPhrase: ((ExtractedPhrase) -> Void)? {
        get { viewModel.onSaveExtractedPhrase }
        set { viewModel.onSaveExtractedPhrase = newValue }
    }
    var onSaveToVocab: (() -> Void)? {
        get { viewModel.onSaveToVocab }
        set { viewModel.onSaveToVocab = newValue }
    }
    var onSendReply: ((String) -> Void)? {
        get { viewModel.onSendReply }
        set { viewModel.onSendReply = newValue }
    }
    var onPasteReply: ((String) -> Void)? {
        get { viewModel.onPasteReply }
        set { viewModel.onPasteReply = newValue }
    }
    var onAddQuickGlossary: ((String, String, TranslationDirection, GlossaryMatchMode) -> Void)? {
        get { viewModel.onAddQuickGlossary }
        set { viewModel.onAddQuickGlossary = newValue }
    }
    var onOpenFullGlossary: (() -> Void)? {
        get { viewModel.onOpenFullGlossary }
        set { viewModel.onOpenFullGlossary = newValue }
    }
    var onCancelWork: (() -> Void)? {
        get { viewModel.onCancelWork }
        set { viewModel.onCancelWork = newValue }
    }

    init() {
        panel = FloatingHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true

        viewModel.onClose = { [weak self] in
            self?.hide()
        }
        viewModel.onLayoutChanged = { [weak self] in
            self?.resizePopupToFit()
        }

        let hosting = NSHostingView(rootView: HUDRootView(vm: viewModel))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
    }

    func showLoading(direction: TranslationDirection, subtitle: String, near point: NSPoint? = nil) {
        cancelAutoDismiss()
        removeMonitors()
        if let pt = point {
            anchorPoint = pt
        } else {
            anchorPoint = NSEvent.mouseLocation
        }
        panel.allowsKeyFocus = false
        viewModel.state = .loading(direction: direction, subtitle: subtitle)
        presentSized(width: 290, height: 54, interactive: false)
        installLoadingEscMonitor()
    }

    func showToast(icon: String, isError: Bool = false, message: String, duration: TimeInterval = 1.6, near point: NSPoint? = nil) {
        cancelAutoDismiss()
        removeMonitors()
        if let pt = point {
            anchorPoint = pt
        } else if !panel.isVisible {
            anchorPoint = NSEvent.mouseLocation
        }
        panel.allowsKeyFocus = false
        viewModel.state = .toast(icon: icon, isError: isError, message: message)
        let width: CGFloat = isError ? 370 : 300
        let height: CGFloat = isError ? 80 : 48
        presentSized(width: width, height: height, interactive: false)

        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hide()
            }
        }
    }

    func startStreamingPopup(
        originalText: String,
        direction: TranslationDirection,
        tone: TonePreset,
        near point: NSPoint? = nil,
        resetDrawers: Bool = true
    ) {
        cancelAutoDismiss()
        if let pt = point {
            anchorPoint = pt
        }
        if resetDrawers {
            viewModel.resetPopupDrawers()
        }
        viewModel.originalText = originalText
        viewModel.translatedText = ""
        viewModel.direction = direction
        viewModel.tone = tone
        viewModel.durationMs = nil
        viewModel.isStreaming = true
        viewModel.state = .popup

        panel.allowsKeyFocus = true
        resizePopupToFit()
        installPopupDismissMonitors()
    }

    func updateStreamingPopup(partialText: String) {
        guard case .popup = viewModel.state else { return }
        viewModel.translatedText = partialText
        resizePopupToFit()
    }

    func finishStreamingPopup(result: TranslationResult) {
        viewModel.originalText = result.originalText
        viewModel.translatedText = result.translatedText
        viewModel.direction = result.direction
        viewModel.tone = result.tone
        viewModel.durationMs = result.durationMs
        viewModel.isStreaming = false
        viewModel.state = .popup

        panel.allowsKeyFocus = true
        resizePopupToFit()
        installPopupDismissMonitors()
    }

    func hide() {
        cancelAutoDismiss()
        removeMonitors()
        viewModel.state = .hidden
        viewModel.isStreaming = false
        viewModel.isGeneratingReply = false
        panel.allowsKeyFocus = false
        panel.orderOut(nil)
    }

    private func resizePopupToFit() {
        let textLen = max(viewModel.translatedText.count, 40)
        let lineBreaks = viewModel.translatedText.components(separatedBy: "\n").count
        let estimatedLines = max(2, min(11, textLen / 54 + lineBreaks))

        var height: CGFloat = CGFloat(170 + estimatedLines * 20)
        if viewModel.showOriginal { height += 90 }
        if viewModel.showExplanation {
            height += viewModel.extractedPhrases.isEmpty ? 205 : 300
        }
        if viewModel.showQuickGlossary { height += 72 }
        if viewModel.showReplyBox {
            height += viewModel.replyOutput.isEmpty ? 84 : 195
        }

        let clampedHeight = min(max(height, 220), 720)
        presentSized(width: 510, height: clampedHeight, interactive: true)
    }

    private func presentSized(width: CGFloat, height: CGFloat, interactive: Bool) {
        panel.ignoresMouseEvents = !interactive

        let screen = NSScreen.screens.first(where: { NSMouseInRect(anchorPoint, $0.frame, false) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = anchorPoint.x - width / 2
        var y = anchorPoint.y - height - 18

        if y < visible.minY + 12 {
            y = anchorPoint.y + 18
        }
        x = max(visible.minX + 12, min(x, visible.maxX - width - 12))
        y = max(visible.minY + 12, min(y, visible.maxY - height - 12))

        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    private func cancelAutoDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    private func installLoadingEscMonitor() {
        removeMonitors()
        globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    self?.viewModel.onCancelWork?()
                }
            }
        }
        localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    self?.viewModel.onCancelWork?()
                }
                return nil
            }
            return event
        }
    }

    private func installPopupDismissMonitors() {
        removeMonitors()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            let loc = NSEvent.mouseLocation
            if !self.panel.frame.contains(loc) {
                Task { @MainActor in
                    if self.viewModel.isStreaming || self.viewModel.isGeneratingReply {
                        self.viewModel.onCancelWork?()
                    }
                    self.hide()
                }
            }
        }

        globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    self?.handlePopupEsc()
                }
            }
        }

        localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    self?.handlePopupEsc()
                }
                return nil
            }
            return event
        }
    }

    private func handlePopupEsc() {
        if viewModel.isStreaming || viewModel.isGeneratingReply || viewModel.isExplaining {
            viewModel.onCancelWork?()
        } else {
            hide()
        }
    }

    private func removeMonitors() {
        if let m = clickOutsideMonitor {
            NSEvent.removeMonitor(m)
            clickOutsideMonitor = nil
        }
        if let m = globalEscMonitor {
            NSEvent.removeMonitor(m)
            globalEscMonitor = nil
        }
        if let m = localEscMonitor {
            NSEvent.removeMonitor(m)
            localEscMonitor = nil
        }
    }
}

private struct HUDRootView: View {
    @ObservedObject var vm: HUDViewModel

    var body: some View {
        Group {
            switch vm.state {
            case .hidden:
                EmptyView()

            case .loading(let direction, let subtitle):
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(direction.shortBadge)  •  Esc — отмена")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                )

            case .toast(let icon, let isError, let message):
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isError ? .red : .green)
                    Text(message)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder((isError ? Color.red : Color.primary).opacity(0.22), lineWidth: 1)
                )

            case .popup:
                popupView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func popupView() -> some View {
        VStack(alignment: .leading, spacing: 9) {
            // Header
            HStack(spacing: 7) {
                Text(vm.direction.shortBadge)
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .foregroundColor(.accentColor)

                if vm.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Печатает...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else if let ms = vm.durationMs {
                    Text(String(format: "%.1f сек", Double(ms) / 1000.0))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    vm.onSpeakEnglish?(vm.englishTextForSpeech)
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(vm.englishTextForSpeech.isEmpty)
                .help("Озвучить английскую фразу")

                Button {
                    vm.showExplanation.toggle()
                    vm.onLayoutChanged?()
                    if vm.showExplanation && vm.explanationText.isEmpty && !vm.isExplaining {
                        vm.onExplainPhrase?()
                    }
                } label: {
                    Image(systemName: vm.showExplanation ? "graduationcap.fill" : "graduationcap")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(vm.showExplanation ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(vm.isStreaming || vm.translatedText.isEmpty)
                .help("Разбор фразы и полезной лексики (English Coach)")

                Button {
                    vm.onSaveToVocab?()
                } label: {
                    Image(systemName: vm.isSavedToVocab ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(vm.isSavedToVocab ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(vm.isStreaming || vm.translatedText.isEmpty)
                .help(vm.isSavedToVocab ? "Уже в тренажёре английского" : "Сохранить фразу в тренажёр английского")

                Button {
                    vm.onRegenerate?()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(vm.isStreaming)
                .help("Другой вариант формулировки")

                if vm.direction != .polishEn {
                    Button {
                        vm.onPolishResult?()
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isStreaming)
                    .help("Улучшить английский (Polish EN ✨ EN)")
                }

                Button {
                    if vm.isStreaming {
                        vm.onCancelWork?()
                    }
                    vm.onClose?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Tone switcher pills
            HStack(spacing: 6) {
                ForEach(TonePreset.allCases) { tone in
                    let isSelected = (tone == vm.tone)
                    Button {
                        if !isSelected && !vm.isStreaming {
                            vm.onChangeTone?(tone)
                        }
                    } label: {
                        Text(tone.title)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                in: Capsule()
                            )
                            .foregroundColor(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            // Translated text (live streaming)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if vm.translatedText.isEmpty && vm.isStreaming {
                        Text("Перевожу...")
                            .font(.system(size: 13.5))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(vm.translatedText.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if vm.showOriginal {
                        Divider()
                        Text("Оригинал:")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(vm.originalText.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            // Inline AI English Coach breakdown
            if vm.showExplanation {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Label("Разбор английского", systemImage: "graduationcap.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.accentColor)
                        if vm.isExplaining {
                            ProgressView().controlSize(.mini)
                        }
                        Spacer()
                        Button {
                            vm.onExtractPhrases?()
                        } label: {
                            HStack(spacing: 3) {
                                if vm.isExtractingPhrases {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "text.badge.plus")
                                }
                                Text("Вытащить в карточки")
                            }
                            .font(.system(size: 10.5))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(vm.isExtractingPhrases || vm.englishTextForSpeech.isEmpty)

                        Button {
                            vm.explanationText = ""
                            vm.onExplainPhrase?()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.isExplaining)
                    }

                    if let err = vm.explanationError {
                        Text(err)
                            .font(.system(size: 11.5))
                            .foregroundColor(.red)
                    } else {
                        ScrollView {
                            Text(vm.explanationText.isEmpty ? "Разбираю лексику и стиль..." : vm.explanationText)
                                .font(.system(size: 12.5))
                                .lineSpacing(2.5)
                                .foregroundColor(vm.explanationText.isEmpty ? .secondary : .primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(minHeight: 80, maxHeight: 170)
                        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if !vm.extractedPhrases.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(vm.extractedPhrases) { phrase in
                                let saved = vm.savedExtractedIDs.contains(phrase.id)
                                HStack(spacing: 6) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(phrase.english)
                                            .font(.system(size: 11.5, weight: .semibold))
                                        Text(phrase.russian)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Button {
                                        vm.onSpeakEnglish?(phrase.english)
                                    } label: {
                                        Image(systemName: "speaker.wave.2")
                                            .font(.system(size: 10.5))
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        vm.onSaveExtractedPhrase?(phrase)
                                    } label: {
                                        Label(saved ? "Сохранено" : "Учить", systemImage: saved ? "checkmark" : "plus")
                                            .font(.system(size: 10.5))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .disabled(saved)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                    }
                }
            }

            // Inline Quick Glossary bar
            if vm.showQuickGlossary {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        TextField("Слово", text: $vm.quickGlossSource)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        TextField("Замена", text: $vm.quickGlossTarget)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        Picker("", selection: $vm.quickGlossMode) {
                            Text("ИИ").tag(GlossaryMatchMode.promptHint)
                            Text("Точно").tag(GlossaryMatchMode.exactReplace)
                        }
                        .labelsHidden()
                        .frame(width: 68)
                        .controlSize(.small)

                        Button("ОК") {
                            let src = vm.quickGlossSource.trimmingCharacters(in: .whitespacesAndNewlines)
                            let tgt = vm.quickGlossTarget.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !src.isEmpty, !tgt.isEmpty else { return }
                            let dir: TranslationDirection = (vm.direction == .enToRu) ? .enToRu : .ruToEn
                            vm.onAddQuickGlossary?(src, tgt, dir, vm.quickGlossMode)
                            vm.quickGlossSource = ""
                            vm.quickGlossTarget = ""
                            vm.quickGlossSavedNotice = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(vm.quickGlossSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  vm.quickGlossTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    HStack {
                        if vm.quickGlossSavedNotice {
                            Text("✓ Добавлено в словарь! Нажмите ↻ чтобы переперевести.")
                                .font(.system(size: 10.5))
                                .foregroundColor(.green)
                        }
                        Spacer()
                        Button("Открыть весь словарь...") {
                            vm.onOpenFullGlossary?()
                        }
                        .font(.system(size: 10.5))
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                }
            }

            // Inline Context Reply drawer
            if vm.showReplyBox {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        TextField("Ответить клиенту на русском (учитывает контекст)...", text: $vm.replyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5))
                            .onSubmit {
                                triggerReply()
                            }

                        Button {
                            triggerReply()
                        } label: {
                            if vm.isGeneratingReply {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 11.5))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(vm.isGeneratingReply || vm.replyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if let err = vm.replyError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    } else if !vm.replyOutput.isEmpty {
                        ScrollView {
                            Text(vm.replyOutput)
                                .font(.system(size: 13.5))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(minHeight: 54, maxHeight: 130)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                        HStack(spacing: 8) {
                            Button {
                                vm.onCopy?(vm.replyOutput)
                            } label: {
                                Label("Копировать ответ", systemImage: "doc.on.doc")
                                    .font(.system(size: 11.5))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button {
                                vm.onPasteReply?(vm.replyOutput)
                            } label: {
                                Label("Вставить в чат", systemImage: "arrow.down.doc")
                                    .font(.system(size: 11.5))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Spacer()
                        }
                    }
                }
            }

            Divider()

            // Action bar
            HStack(spacing: 7) {
                Button {
                    vm.onCopy?(vm.translatedText.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    Label("Копировать", systemImage: "doc.on.doc")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(vm.translatedText.isEmpty)

                Button {
                    vm.onReplace?(vm.translatedText)
                } label: {
                    Label("Заменить", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.translatedText.isEmpty || vm.isStreaming)

                Button {
                    vm.showReplyBox.toggle()
                    vm.onLayoutChanged?()
                } label: {
                    Label("Ответить", systemImage: "arrowshape.turn.up.left")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(vm.showReplyBox ? .accentColor : nil)
                .controlSize(.small)

                Spacer()

                Button {
                    vm.showOriginal.toggle()
                    vm.onLayoutChanged?()
                } label: {
                    Text(vm.showOriginal ? "Скрыть" : "Оригинал")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    vm.showQuickGlossary.toggle()
                    vm.quickGlossSavedNotice = false
                    vm.onLayoutChanged?()
                } label: {
                    Image(systemName: vm.showQuickGlossary ? "book.fill" : "book.closed")
                        .font(.system(size: 12))
                        .foregroundColor(vm.showQuickGlossary ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Быстро добавить слово в словарь")
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
        )
    }

    private func triggerReply() {
        let trimmed = vm.replyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !vm.isGeneratingReply else { return }
        vm.onSendReply?(trimmed)
    }
}
