import AppKit
import SwiftUI

@MainActor
final class QuickTranslatorViewModel: ObservableObject {
    @Published var inputText: String = ""
    @Published var outputText: String = ""
    @Published var direction: TranslationDirection = .auto
    @Published var tone: TonePreset = ConfigStore.shared.config.defaultTone
    @Published var isTranslating: Bool = false
    @Published var statusText: String = ""
    @Published var errorMessage: String?

    private let client: OllamaClient
    private var activeTask: Task<Void, Never>?

    init(client: OllamaClient) {
        self.client = client
    }

    func translate(alternative: Bool = false) {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let previousOutput = alternative ? outputText : nil
        activeTask?.cancel()
        isTranslating = true
        errorMessage = nil
        outputText = ""
        statusText = alternative ? "Подбираю другой вариант..." : "Перевожу..."

        let cfg = ConfigStore.shared.config
        let selectedTone = tone
        let selectedDirection = direction

        activeTask = Task {
            do {
                let res = try await client.translateStream(
                    text: inputText,
                    config: cfg,
                    toneOverride: selectedTone,
                    directionOverride: selectedDirection,
                    alternativeTo: previousOutput
                ) { [weak self] partial in
                    Task { @MainActor in
                        self?.outputText = partial
                    }
                }
                guard !Task.isCancelled else { return }
                self.outputText = res.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                self.statusText = "\(res.direction.shortBadge) • \(String(format: "%.1f", Double(res.durationMs) / 1000.0)) сек"
                self.isTranslating = false
                HistoryStore.shared.record(res)
            } catch OllamaError.cancelled {
                self.statusText = "Отменено"
                self.isTranslating = false
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.statusText = ""
                self.isTranslating = false
            }
        }
    }

    func cancel() {
        activeTask?.cancel()
        isTranslating = false
        statusText = "Отменено"
    }

    func copyOutput() {
        guard !outputText.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(outputText, forType: .string)
        statusText = "Скопировано в буфер обмена"
    }

    func swapTexts() {
        guard !outputText.isEmpty else { return }
        let prevOutput = outputText
        outputText = ""
        inputText = prevOutput
        if direction == .ruToEn {
            direction = .enToRu
        } else if direction == .enToRu {
            direction = .ruToEn
        }
    }
}

struct QuickTranslatorView: View {
    @ObservedObject var vm: QuickTranslatorViewModel
    let onOpenGlossary: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Controls row
            HStack(spacing: 10) {
                Picker("", selection: $vm.direction) {
                    ForEach(TranslationDirection.allCases) { dir in
                        Text(dir.label).tag(dir)
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                Picker("", selection: $vm.tone) {
                    ForEach(TonePreset.allCases) { tone in
                        Text(tone.title).tag(tone)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    onOpenGlossary()
                } label: {
                    Image(systemName: "book")
                }
                .help("Открыть словарь замен")
            }

            // Input editor
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Исходный текст")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    if !vm.inputText.isEmpty {
                        Button("Очистить") {
                            vm.inputText = ""
                            vm.outputText = ""
                            vm.errorMessage = nil
                            vm.statusText = ""
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                }

                TextEditor(text: $vm.inputText)
                    .font(.system(size: 13.5))
                    .frame(minHeight: 110)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                    )
            }

            // Translate action bar
            HStack(spacing: 8) {
                if vm.isTranslating {
                    Button {
                        vm.cancel()
                    } label: {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Отменить")
                        }
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                } else {
                    Button {
                        vm.translate(alternative: false)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: vm.direction == .polishEn ? "sparkles" : "arrow.left.arrow.right")
                            Text(vm.direction == .polishEn ? "Улучшить" : "Перевести")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Button {
                    vm.translate(alternative: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(vm.isTranslating || vm.outputText.isEmpty)
                .help("Другой вариант формулировки")

                Button {
                    vm.swapTexts()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .disabled(vm.outputText.isEmpty || vm.isTranslating)
                .help("Перенести результат в поле ввода")

                Spacer()

                if let err = vm.errorMessage {
                    Text(err)
                        .font(.system(size: 11.5))
                        .foregroundColor(.red)
                        .lineLimit(2)
                } else if !vm.statusText.isEmpty {
                    Text(vm.statusText)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                }
            }

            // Output area
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Результат")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        vm.copyOutput()
                    } label: {
                        Label("Копировать", systemImage: "doc.on.doc")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.outputText.isEmpty)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                }

                ScrollView {
                    Text(vm.outputText.isEmpty ? "Здесь появится перевод в реальном времени (⌘↩ — перевести)" : vm.outputText)
                        .font(.system(size: 14))
                        .foregroundColor(vm.outputText.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 115)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
            }
        }
        .padding(16)
        .frame(minWidth: 540, minHeight: 420)
    }
}
