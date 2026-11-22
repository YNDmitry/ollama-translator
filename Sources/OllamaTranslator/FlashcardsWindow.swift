import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum FlashcardTab: Hashable {
    case practice
    case deck
}

enum PracticeDirection: String, CaseIterable, Identifiable {
    case ruToEn
    case enToRu

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ruToEn: return "RU → EN (Активный)"
        case .enToRu: return "EN → RU (Понимание)"
        }
    }
}

@MainActor
final class FlashcardsViewModel: ObservableObject {
    @Published var selectedTab: FlashcardTab = .practice
    @Published var practiceDirection: PracticeDirection = .ruToEn

    // Practice session state
    @Published var sessionQueue: [UUID] = []
    @Published var practiceAheadMode: Bool = false
    @Published var isAnswerRevealed: Bool = false
    @Published var userAttempt: String = ""
    @Published var aiFeedback: String = ""
    @Published var isCheckingWithAI: Bool = false
    @Published var aiError: String? = nil

    // Deck management state
    @Published var searchQuery: String = ""
    @Published var newEnglish: String = ""
    @Published var newRussian: String = ""
    @Published var newNote: String = ""
    @Published var deckNotice: String = ""

    let vocabStore: VocabStore
    private let ollamaClient: OllamaClient
    private var checkTask: Task<Void, Never>?

    init(vocabStore: VocabStore, ollamaClient: OllamaClient) {
        self.vocabStore = vocabStore
        self.ollamaClient = ollamaClient
        refreshQueue()
    }

    var currentCard: VocabCard? {
        guard let firstID = sessionQueue.first else { return nil }
        return vocabStore.cards.first(where: { $0.id == firstID })
    }

    var dueCount: Int {
        vocabStore.dueCards().count
    }

    var filteredCards: [VocabCard] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return vocabStore.cards }
        return vocabStore.cards.filter {
            $0.english.lowercased().contains(q) ||
            $0.russian.lowercased().contains(q) ||
            $0.note.lowercased().contains(q)
        }
    }

    func refreshQueue(includeAllAhead: Bool = false) {
        practiceAheadMode = includeAllAhead
        let cards = includeAllAhead ? vocabStore.cards : vocabStore.dueCards()
        sessionQueue = cards.map { $0.id }
        resetCurrentCardUI()
    }

    func resetCurrentCardUI() {
        checkTask?.cancel()
        isAnswerRevealed = false
        userAttempt = ""
        aiFeedback = ""
        isCheckingWithAI = false
        aiError = nil
    }

    func revealAnswer() {
        isAnswerRevealed = true
    }

    func rateCurrent(_ rating: ReviewRating) {
        guard let card = currentCard else { return }
        SpeechHelper.shared.stop()
        vocabStore.review(cardID: card.id, rating: rating)

        if !sessionQueue.isEmpty {
            let ratedID = sessionQueue.removeFirst()
            if rating == .again {
                // Re-insert near end of current session so user sees it again soon
                sessionQueue.append(ratedID)
            }
        }
        resetCurrentCardUI()
    }

    func checkAttemptWithAI() {
        guard let card = currentCard else { return }
        let attempt = userAttempt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attempt.isEmpty else { return }

        checkTask?.cancel()
        isCheckingWithAI = true
        aiError = nil
        aiFeedback = ""
        isAnswerRevealed = true

        let cfg = ConfigStore.shared.config
        checkTask = Task {
            do {
                let feedback = try await ollamaClient.evaluatePracticeAttemptStream(
                    russianPrompt: card.russian,
                    referenceEnglish: card.english,
                    userEnglish: attempt,
                    config: cfg
                ) { [weak self] partial in
                    Task { @MainActor in
                        self?.aiFeedback = partial
                    }
                }
                guard !Task.isCancelled else { return }
                self.aiFeedback = feedback
                self.isCheckingWithAI = false
            } catch OllamaError.cancelled {
                self.isCheckingWithAI = false
            } catch {
                guard !Task.isCancelled else { return }
                self.aiError = error.localizedDescription
                self.isCheckingWithAI = false
            }
        }
    }

    func addNewCard() {
        let added = vocabStore.addCard(english: newEnglish, russian: newRussian, note: newNote)
        if added {
            newEnglish = ""
            newRussian = ""
            newNote = ""
            deckNotice = "✓ Фраза добавлена в тренажёр"
            if sessionQueue.isEmpty {
                refreshQueue()
            }
        } else {
            deckNotice = "Такая фраза уже есть в словаре"
        }
    }

    func exportAnki() {
        let tsv = vocabStore.exportAnkiTSV()
        guard !tsv.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "Экспорт словаря для Anki"
        panel.nameFieldStringValue = "ollama-translator-anki.tsv"
        panel.allowedContentTypes = [.tabSeparatedText, .plainText]

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try tsv.write(to: url, atomically: true, encoding: .utf8)
                deckNotice = "✓ Экспортировано \(vocabStore.cards.count) карточек в Anki TSV"
            } catch {
                deckNotice = "Ошибка сохранения: \(error.localizedDescription)"
            }
        }
    }

    func dueBadge(for card: VocabCard) -> String {
        let now = Date()
        if card.nextReviewAt <= now {
            return "Сейчас"
        }
        let hours = card.nextReviewAt.timeIntervalSince(now) / 3600.0
        if hours < 24 {
            return "Через \(max(1, Int(hours.rounded()))) ч"
        }
        let days = max(1, Int((hours / 24.0).rounded()))
        return "Через \(days) дн."
    }
}

struct FlashcardsRootView: View {
    @ObservedObject var vm: FlashcardsViewModel
    @ObservedObject var vocabStore: VocabStore

    var body: some View {
        VStack(spacing: 12) {
            // Top header bar with stats & tab picker
            HStack(spacing: 12) {
                Picker("", selection: $vm.selectedTab) {
                    Text("Тренировка (\(vm.dueCount))").tag(FlashcardTab.practice)
                    Text("Мой словарь (\(vocabStore.cards.count))").tag(FlashcardTab.deck)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                Spacer()

                HStack(spacing: 10) {
                    Label("\(vocabStore.stats.streakDays) дн.", systemImage: "flame.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(vocabStore.stats.streakDays > 0 ? .orange : .secondary)
                        .help("Ежедневная серия тренировок")

                    Label("\(vocabStore.stats.totalReviews)", systemImage: "checkmark.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .help("Всего повторений")
                }
            }

            Divider()

            if vm.selectedTab == .practice {
                practiceView()
            } else {
                deckView()
            }
        }
        .padding(16)
        .frame(minWidth: 580, minHeight: 480)
    }

    @ViewBuilder
    private func practiceView() -> some View {
        if vocabStore.cards.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "graduationcap")
                    .font(.system(size: 38))
                    .foregroundColor(.accentColor.opacity(0.8))
                Text("Словарь для изучения пока пуст")
                    .font(.title3.weight(.semibold))
                Text("Сохраняйте полезные фразы кнопкой ★ прямо из всплывающего окна (⌃⌥P), истории переводов или добавьте стартовый набор фраз для общения с клиентами.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack(spacing: 10) {
                    Button("Добавить 5 полезных фраз для клиентов") {
                        vocabStore.addStarterClientCards()
                        vm.refreshQueue()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Добавить свою фразу") {
                        vm.selectedTab = .deck
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let card = vm.currentCard {
            VStack(spacing: 14) {
                HStack {
                    Picker("Режим:", selection: $vm.practiceDirection) {
                        ForEach(PracticeDirection.allCases) { dir in
                            Text(dir.label).tag(dir)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 310)

                    Spacer()

                    Text("Осталось: \(vm.sessionQueue.count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }

                // Flashcard front
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(vm.practiceDirection == .ruToEn ? "Переведите на английский:" : "Что означает эта фраза?")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        if vm.practiceDirection == .enToRu {
                            Button {
                                SpeechHelper.shared.speakEnglish(card.english)
                            } label: {
                                Label("Озвучить", systemImage: "speaker.wave.2")
                                    .font(.system(size: 11.5))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Text(vm.practiceDirection == .ruToEn ? card.russian : card.english)
                        .font(.system(size: 18, weight: .semibold))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )

                // Active typing + AI evaluation (in RU -> EN mode)
                if vm.practiceDirection == .ruToEn {
                    HStack(spacing: 8) {
                        TextField("Попробуйте написать свой вариант по-английски...", text: $vm.userAttempt)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13.5))
                            .onSubmit {
                                vm.checkAttemptWithAI()
                            }

                        Button {
                            vm.checkAttemptWithAI()
                        } label: {
                            HStack(spacing: 5) {
                                if vm.isCheckingWithAI {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text("Проверить с ИИ")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isCheckingWithAI || vm.userAttempt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                // AI evaluation feedback box
                if let err = vm.aiError {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if vm.isCheckingWithAI || !vm.aiFeedback.isEmpty {
                    ScrollView {
                        Text(vm.aiFeedback.isEmpty ? "Проверяю ваш вариант..." : vm.aiFeedback)
                            .font(.system(size: 12.5))
                            .foregroundColor(vm.aiFeedback.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 95)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                // Answer reveal box
                if vm.isAnswerRevealed {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Эталонный ответ:")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button {
                                SpeechHelper.shared.speakEnglish(card.english)
                            } label: {
                                Label("Озвучить EN", systemImage: "speaker.wave.2.fill")
                                    .font(.system(size: 11.5))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Text(vm.practiceDirection == .ruToEn ? card.english : card.russian)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.accentColor)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !card.note.isEmpty {
                            Text("Заметка: \(card.note)")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(14)
                    .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
                    )

                    Spacer(minLength: 0)

                    // SRS Rating buttons
                    HStack(spacing: 12) {
                        Button {
                            vm.rateCurrent(.again)
                        } label: {
                            VStack(spacing: 2) {
                                Text("Снова").font(.system(size: 13, weight: .semibold))
                                Text("10 мин").font(.system(size: 10.5)).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .keyboardShortcut("1", modifiers: [])

                        Button {
                            vm.rateCurrent(.good)
                        } label: {
                            VStack(spacing: 2) {
                                Text("Хорошо").font(.system(size: 13, weight: .semibold))
                                Text(card.repetitions == 0 ? "1 день" : "дальше").font(.system(size: 10.5)).foregroundColor(.white.opacity(0.85))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("2", modifiers: [])

                        Button {
                            vm.rateCurrent(.easy)
                        } label: {
                            VStack(spacing: 2) {
                                Text("Легко").font(.system(size: 13, weight: .semibold))
                                Text(card.repetitions == 0 ? "2 дня" : "быстрее").font(.system(size: 10.5)).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)
                        .keyboardShortcut("3", modifiers: [])
                    }
                } else {
                    Spacer(minLength: 0)

                    Button {
                        vm.revealAnswer()
                    } label: {
                        Text("Показать ответ")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: 260)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.space, modifiers: [])
                }
            }
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 42))
                    .foregroundColor(.green)
                Text("Все карточки на сегодня повторены!")
                    .font(.title3.weight(.semibold))
                Text("Серия: \(vocabStore.stats.streakDays) дн. • Всего фраз в словаре: \(vocabStore.cards.count)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Button("Потренировать все карточки ещё раз") {
                    vm.refreshQueue(includeAllAhead: true)
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func deckView() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Add form
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Английская фраза / слово", text: $vm.newEnglish)
                        .textFieldStyle(.roundedBorder)
                    TextField("Перевод на русском", text: $vm.newRussian)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 8) {
                    TextField("Заметка / контекст (опционально)", text: $vm.newNote)
                        .textFieldStyle(.roundedBorder)
                    Button("Добавить") {
                        vm.addNewCard()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.newEnglish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              vm.newRussian.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            // Search & actions
            HStack(spacing: 8) {
                TextField("Поиск по словарю...", text: $vm.searchQuery)
                    .textFieldStyle(.roundedBorder)

                Button {
                    vm.exportAnki()
                } label: {
                    Label("Экспорт в Anki", systemImage: "square.and.arrow.up")
                }
                .disabled(vocabStore.cards.isEmpty)
            }

            if !vm.deckNotice.isEmpty {
                Text(vm.deckNotice)
                    .font(.system(size: 11.5))
                    .foregroundColor(vm.deckNotice.hasPrefix("✓") ? .green : .secondary)
            }

            if vm.filteredCards.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text(vocabStore.cards.isEmpty ? "Карточек пока нет" : "Ничего не найдено")
                        .foregroundColor(.secondary)
                    if vocabStore.cards.isEmpty {
                        Button("Добавить 5 фраз для общения с клиентами") {
                            vocabStore.addStarterClientCards()
                            vm.refreshQueue()
                        }
                        .controlSize(.small)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } else {
                List {
                    ForEach(vm.filteredCards) { card in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(card.english)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .textSelection(.enabled)
                                Text(card.russian)
                                    .font(.system(size: 12.5))
                                    .foregroundColor(.secondary)
                                if !card.note.isEmpty {
                                    Text(card.note)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary.opacity(0.85))
                                }
                            }
                            Spacer()

                            Text(vm.dueBadge(for: card))
                                .font(.system(size: 10.5, weight: .medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    (card.nextReviewAt <= Date() ? Color.orange : Color.secondary).opacity(0.16),
                                    in: Capsule()
                                )
                                .foregroundColor(card.nextReviewAt <= Date() ? .orange : .secondary)

                            Button {
                                SpeechHelper.shared.speakEnglish(card.english)
                            } label: {
                                Image(systemName: "speaker.wave.2")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)

                            Button {
                                vocabStore.remove(id: card.id)
                                vm.refreshQueue(includeAllAhead: vm.practiceAheadMode)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundColor(.red.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
