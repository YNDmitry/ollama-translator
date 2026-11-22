import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum FlashcardTab: Hashable {
    case practice
    case roleplay
    case deck
}

enum PracticeDirection: String, CaseIterable, Identifiable {
    case ruToEn
    case enToRu
    case listening
    case speaking

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ruToEn: return "RU → EN"
        case .enToRu: return "EN → RU"
        case .listening: return "🎧 Аудирование"
        case .speaking: return "🗣️ Говорение"
        }
    }
}

@MainActor
final class FlashcardsViewModel: ObservableObject {
    @Published var selectedTab: FlashcardTab = .practice
    @Published var practiceDirection: PracticeDirection = .ruToEn {
        didSet {
            if practiceDirection == .listening, let card = currentCard, selectedTab == .practice {
                SpeechHelper.shared.speakEnglish(card.english)
            }
        }
    }

    // Practice session state
    @Published var sessionQueue: [UUID] = []
    @Published var practiceAheadMode: Bool = false
    @Published var isAnswerRevealed: Bool = false
    @Published var userAttempt: String = ""
    @Published var aiFeedback: String = ""
    @Published var isCheckingWithAI: Bool = false
    @Published var aiError: String? = nil

    // Speaking & Shadowing state
    let micRecorder = MicRecorder()
    @Published var isTranscribingSpeech: Bool = false
    @Published var speakingComparison: PronunciationComparison? = nil
    @Published var speakingError: String? = nil
    @Published var whisperReady: Bool = WhisperService.isReady

    // Roleplay simulator state
    @Published var selectedScenario: RoleplayScenario = .deadlineShift
    @Published var roleplayMessages: [RoleplayMessage] = []
    @Published var roleplayInput: String = ""
    @Published var isRoleplayBusy: Bool = false
    @Published var isRecordingRoleplay: Bool = false
    @Published var isTranscribingRoleplay: Bool = false
    @Published var roleplayAutoSpeak: Bool = true
    @Published var roleplayError: String? = nil

    // Deck management state
    @Published var searchQuery: String = ""
    @Published var newEnglish: String = ""
    @Published var newRussian: String = ""
    @Published var newNote: String = ""
    @Published var deckNotice: String = ""

    let vocabStore: VocabStore
    private let ollamaClient: OllamaClient
    private var checkTask: Task<Void, Never>?
    private var roleplayTask: Task<Void, Never>?

    init(vocabStore: VocabStore, ollamaClient: OllamaClient) {
        self.vocabStore = vocabStore
        self.ollamaClient = ollamaClient
        refreshQueue()
        startRoleplay(scenario: .deadlineShift, autoSpeakOpening: false)
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

    // MARK: - Flashcards Practice

    func refreshQueue(includeAllAhead: Bool = false) {
        practiceAheadMode = includeAllAhead
        let cards = includeAllAhead ? vocabStore.cards : vocabStore.dueCards()
        sessionQueue = cards.map { $0.id }
        resetCurrentCardUI()
    }

    func resetCurrentCardUI() {
        checkTask?.cancel()
        micRecorder.cancelRecording()
        isAnswerRevealed = false
        userAttempt = ""
        aiFeedback = ""
        isCheckingWithAI = false
        aiError = nil
        isTranscribingSpeech = false
        speakingComparison = nil
        speakingError = nil
        whisperReady = WhisperService.isReady
    }

    func toggleSpeakingRecording() {
        guard let card = currentCard else { return }
        speakingError = nil
        whisperReady = WhisperService.isReady

        if micRecorder.isRecording {
            isTranscribingSpeech = true
            do {
                let wavURL = try micRecorder.stopRecording()
                let expected = card.english
                Task { [weak self] in
                    guard let self = self else { return }
                    defer { try? FileManager.default.removeItem(at: wavURL) }
                    do {
                        let heard = try await WhisperService.transcribe(wavURL: wavURL, language: "en")
                        let comparison = PronunciationDiff.compare(expected: expected, heard: heard)
                        self.speakingComparison = comparison
                        self.isTranscribingSpeech = false
                        self.isAnswerRevealed = true
                    } catch {
                        self.speakingError = error.localizedDescription
                        self.isTranscribingSpeech = false
                    }
                }
            } catch {
                speakingError = error.localizedDescription
                isTranscribingSpeech = false
            }
        } else {
            SpeechHelper.shared.stop()
            speakingComparison = nil
            aiFeedback = ""
            aiError = nil
            Task { [weak self] in
                guard let self = self else { return }
                do {
                    try await self.micRecorder.startRecording()
                } catch {
                    self.speakingError = error.localizedDescription
                }
            }
        }
    }

    func analyzeSpeakingWithAI() {
        guard let card = currentCard, let cmp = speakingComparison else { return }
        checkTask?.cancel()
        isCheckingWithAI = true
        aiError = nil
        aiFeedback = ""

        let cfg = ConfigStore.shared.config
        checkTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let fb = try await self.ollamaClient.evaluateSpeakingAttemptStream(
                    targetEnglish: card.english,
                    heardEnglish: cmp.heardClean.isEmpty ? "(тишина / не распознано)" : cmp.heardClean,
                    accuracy: cmp.accuracyPercent,
                    config: cfg
                ) { [weak self] partial in
                    Task { @MainActor in
                        self?.aiFeedback = partial
                    }
                }
                guard !Task.isCancelled else { return }
                self.aiFeedback = fb
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

    func toggleRoleplayMic() {
        roleplayError = nil
        if isRecordingRoleplay {
            isRecordingRoleplay = false
            isTranscribingRoleplay = true
            do {
                let wavURL = try micRecorder.stopRecording()
                Task { [weak self] in
                    guard let self = self else { return }
                    defer { try? FileManager.default.removeItem(at: wavURL) }
                    do {
                        let heard = try await WhisperService.transcribe(wavURL: wavURL, language: "en")
                        self.isTranscribingRoleplay = false
                        if !heard.isEmpty {
                            self.roleplayInput = heard
                            self.sendRoleplayMessage()
                        } else {
                            self.roleplayError = "Не удалось распознать речь — попробуйте чуть громче"
                        }
                    } catch {
                        self.roleplayError = error.localizedDescription
                        self.isTranscribingRoleplay = false
                    }
                }
            } catch {
                roleplayError = error.localizedDescription
                isTranscribingRoleplay = false
            }
        } else {
            SpeechHelper.shared.stop()
            Task { [weak self] in
                guard let self = self else { return }
                do {
                    try await self.micRecorder.startRecording()
                    self.isRecordingRoleplay = true
                } catch {
                    self.roleplayError = error.localizedDescription
                }
            }
        }
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
                sessionQueue.append(ratedID)
            }
        }
        resetCurrentCardUI()

        if practiceDirection == .listening, let next = currentCard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                SpeechHelper.shared.speakEnglish(next.english)
            }
        }
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
        let isListening = (practiceDirection == .listening)
        checkTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let feedback: String
                if isListening {
                    feedback = try await self.ollamaClient.evaluateListeningAttemptStream(
                        spokenEnglish: card.english,
                        russianMeaning: card.russian,
                        userInput: attempt,
                        config: cfg
                    ) { [weak self] partial in
                        Task { @MainActor in
                            self?.aiFeedback = partial
                        }
                    }
                } else {
                    feedback = try await self.ollamaClient.evaluatePracticeAttemptStream(
                        russianPrompt: card.russian,
                        referenceEnglish: card.english,
                        userEnglish: attempt,
                        config: cfg
                    ) { [weak self] partial in
                        Task { @MainActor in
                            self?.aiFeedback = partial
                        }
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

    // MARK: - Client Chat Roleplay

    func startRoleplay(scenario: RoleplayScenario, autoSpeakOpening: Bool = true) {
        roleplayTask?.cancel()
        SpeechHelper.shared.stop()
        selectedScenario = scenario
        roleplayInput = ""
        roleplayError = nil
        isRoleplayBusy = false

        let opening = RoleplayMessage(isUser: false, text: scenario.openingClientMessage)
        roleplayMessages = [opening]
        if autoSpeakOpening && roleplayAutoSpeak {
            SpeechHelper.shared.speakEnglish(opening.text)
        }
    }

    func sendRoleplayMessage() {
        let trimmed = roleplayInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRoleplayBusy else { return }

        let historySnapshot = roleplayMessages
        let userMsg = RoleplayMessage(isUser: true, text: trimmed)
        roleplayMessages.append(userMsg)
        roleplayInput = ""
        roleplayError = nil
        isRoleplayBusy = true

        let scenario = selectedScenario
        let cfg = ConfigStore.shared.config

        roleplayTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let turn = try await self.ollamaClient.roleplayTurn(
                    scenario: scenario,
                    history: historySnapshot,
                    userMessage: trimmed,
                    config: cfg
                )
                guard !Task.isCancelled else { return }

                // Attach coach feedback to the user's message
                if let idx = self.roleplayMessages.firstIndex(where: { $0.id == userMsg.id }) {
                    self.roleplayMessages[idx].coachNote = turn.coachNote
                    self.roleplayMessages[idx].betterPhrase = turn.betterPhrase
                }

                let clientMsg = RoleplayMessage(isUser: false, text: turn.clientReply)
                self.roleplayMessages.append(clientMsg)
                self.isRoleplayBusy = false

                if self.roleplayAutoSpeak {
                    SpeechHelper.shared.speakEnglish(clientMsg.text)
                }
            } catch OllamaError.cancelled {
                self.isRoleplayBusy = false
            } catch {
                guard !Task.isCancelled else { return }
                self.roleplayError = error.localizedDescription
                self.isRoleplayBusy = false
            }
        }
    }

    func translateClientMessageHint(id: UUID) {
        guard let idx = roleplayMessages.firstIndex(where: { $0.id == id }) else { return }
        if roleplayMessages[idx].russianHint != nil { return }

        let eng = roleplayMessages[idx].text
        let cfg = ConfigStore.shared.config
        Task { [weak self] in
            guard let self = self else { return }
            if let res = try? await self.ollamaClient.translate(text: eng, config: cfg, directionOverride: .enToRu) {
                if let currentIdx = self.roleplayMessages.firstIndex(where: { $0.id == id }) {
                    self.roleplayMessages[currentIdx].russianHint = res.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
    }

    func saveBetterPhraseToVocab(english: String, userOriginal: String) {
        vocabStore.addCard(english: english, russian: "Более естественный вариант (вместо: \(userOriginal))", note: "Из диалога: \(selectedScenario.title)")
    }

    // MARK: - Deck Management

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
    @ObservedObject var micRecorder: MicRecorder
    @ObservedObject var whisperDownloader = WhisperModelDownloader.shared

    var body: some View {
        VStack(spacing: 12) {
            // Top header bar with stats & tab picker
            HStack(spacing: 12) {
                Picker("", selection: $vm.selectedTab) {
                    Text("Тренировка (\(vm.dueCount))").tag(FlashcardTab.practice)
                    Text("💬 Диалог").tag(FlashcardTab.roleplay)
                    Text("Мой словарь (\(vocabStore.cards.count))").tag(FlashcardTab.deck)
                }
                .pickerStyle(.segmented)
                .frame(width: 390)

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

            switch vm.selectedTab {
            case .practice:
                practiceView()
            case .roleplay:
                roleplayView()
            case .deck:
                deckView()
            }
        }
        .padding(16)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 560, idealHeight: 650)
    }

    // MARK: - Tab 1: Practice (RU->EN, EN->RU, Listening)

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
                Text("Сохраняйте полезные фразы кнопкой 🔖 из всплывающего окна (⌃⌥P), истории переводов или добавьте стартовый набор фраз для общения с клиентами.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
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
            VStack(spacing: 12) {
                HStack {
                    Picker("Режим:", selection: $vm.practiceDirection) {
                        ForEach(PracticeDirection.allCases) { dir in
                            Text(dir.label).tag(dir)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 470)

                    Spacer()

                    Text("Осталось: \(vm.sessionQueue.count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }

                ScrollView {
                    VStack(spacing: 12) {
                        // Card front
                        VStack(alignment: .leading, spacing: 10) {
                            if vm.practiceDirection == .speaking {
                                HStack {
                                    Label("Прослушайте образец и произнесите вслух (Shadowing)", systemImage: "mic.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                    Spacer()
                                    Button {
                                        SpeechHelper.shared.speakEnglish(card.english)
                                    } label: {
                                        Label("Образец", systemImage: "speaker.wave.2.fill")
                                            .font(.system(size: 11.5))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button {
                                        SpeechHelper.shared.speakEnglish(card.english, speedOverride: 0.75)
                                    } label: {
                                        Text("🐢 0.75x")
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }

                                Text(card.english)
                                    .font(.system(size: 19, weight: .bold))
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(card.russian)
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if vm.practiceDirection == .listening {
                                HStack {
                                    Label("Прослушайте фразу на слух (текст скрыт)", systemImage: "headphones")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                    Spacer()
                                }

                                HStack(spacing: 10) {
                                    Button {
                                        SpeechHelper.shared.speakEnglish(card.english)
                                    } label: {
                                        Label("Прослушать", systemImage: "speaker.wave.2.fill")
                                            .font(.system(size: 13, weight: .semibold))
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button {
                                        SpeechHelper.shared.speakEnglish(card.english, speedOverride: 0.75)
                                    } label: {
                                        Label("🐢 Медленно (0.75x)", systemImage: "tortoise.fill")
                                            .font(.system(size: 12.5))
                                    }
                                    .buttonStyle(.bordered)

                                    Spacer()
                                }
                            } else {
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

                                        Button {
                                            SpeechHelper.shared.speakEnglish(card.english, speedOverride: 0.75)
                                        } label: {
                                            Text("🐢 0.75x")
                                                .font(.system(size: 11))
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }

                                Text(vm.practiceDirection == .ruToEn ? card.russian : card.english)
                                    .font(.system(size: 18, weight: .semibold))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(16)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        )

                        // Speaking & Shadowing Recorder + Word-by-word Diff
                        if vm.practiceDirection == .speaking {
                            VStack(alignment: .leading, spacing: 10) {
                                if !vm.whisperReady {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Image(systemName: "waveform.badge.exclamationmark")
                                                .foregroundColor(.orange)
                                            Text(WhisperService.whisperCLIURL == nil
                                                 ? "Установите whisper-cli: brew install whisper-cpp"
                                                 : "Для проверки речи скачайте локальную модель Whisper large-v3-turbo (~574 МБ)")
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            if whisperDownloader.isDownloading {
                                                Button("Отмена") { whisperDownloader.cancel() }
                                                    .controlSize(.small)
                                            } else if WhisperService.whisperCLIURL != nil {
                                                Button("Скачать (~574 МБ)") {
                                                    whisperDownloader.startDownload {
                                                        vm.whisperReady = WhisperService.isReady
                                                    }
                                                }
                                                .buttonStyle(.borderedProminent)
                                                .controlSize(.small)
                                            }
                                        }
                                        if whisperDownloader.isDownloading {
                                            ProgressView(value: whisperDownloader.progress)
                                                .progressViewStyle(.linear)
                                            Text(whisperDownloader.statusText)
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(12)
                                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                } else {
                                    HStack(spacing: 12) {
                                        Button {
                                            vm.toggleSpeakingRecording()
                                        } label: {
                                            HStack(spacing: 6) {
                                                if vm.isTranscribingSpeech {
                                                    ProgressView().controlSize(.small)
                                                    Text("Распознаю речь...")
                                                } else if micRecorder.isRecording {
                                                    Image(systemName: "stop.circle.fill")
                                                    Text(String(format: "Стоп и проверить (%.1fс)", micRecorder.elapsedSeconds))
                                                } else {
                                                    Image(systemName: "mic.fill")
                                                    Text("Произнести вслух")
                                                }
                                            }
                                            .font(.system(size: 13.5, weight: .semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(micRecorder.isRecording ? .red : .accentColor)
                                        .disabled(vm.isTranscribingSpeech)

                                        if micRecorder.isRecording {
                                            // Live audio level meter
                                            GeometryReader { geo in
                                                ZStack(alignment: .leading) {
                                                    Capsule().fill(Color.primary.opacity(0.12))
                                                    Capsule()
                                                        .fill(Color.red)
                                                        .frame(width: max(8, geo.size.width * CGFloat(micRecorder.audioLevel)))
                                                }
                                            }
                                            .frame(height: 10)
                                        }

                                        Spacer()
                                    }
                                }

                                if let err = vm.speakingError {
                                    Text(err)
                                        .font(.system(size: 12))
                                        .foregroundColor(.red)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                if let cmp = vm.speakingComparison {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text("Как вас услышал носитель (Whisper):")
                                                .font(.system(size: 11.5, weight: .semibold))
                                                .foregroundColor(.secondary)

                                            Text("\(cmp.accuracyPercent)%")
                                                .font(.system(size: 12, weight: .bold))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 2)
                                                .background(
                                                    (cmp.accuracyPercent >= 85 ? Color.green : (cmp.accuracyPercent >= 60 ? Color.orange : Color.red)).opacity(0.2),
                                                    in: Capsule()
                                                )
                                                .foregroundColor(cmp.accuracyPercent >= 85 ? .green : (cmp.accuracyPercent >= 60 ? .orange : .red))

                                            Spacer()

                                            Button {
                                                vm.analyzeSpeakingWithAI()
                                            } label: {
                                                HStack(spacing: 4) {
                                                    if vm.isCheckingWithAI {
                                                        ProgressView().controlSize(.mini)
                                                    } else {
                                                        Image(systemName: "sparkles")
                                                    }
                                                    Text("Советы по произношению")
                                                }
                                                .font(.system(size: 11.5))
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .disabled(vm.isCheckingWithAI)
                                        }

                                        // Color-coded word-by-word breakdown
                                        Text(cmp.words.reduce(AttributedString()) { acc, item in
                                            var next = acc
                                            if !next.characters.isEmpty { next.append(AttributedString(" ")) }
                                            switch item.status {
                                            case .matched:
                                                var s = AttributedString(item.expected)
                                                s.foregroundColor = .green
                                                next.append(s)
                                            case .missed:
                                                var s = AttributedString(item.expected)
                                                s.foregroundColor = .red
                                                s.strikethroughStyle = .single
                                                next.append(s)
                                            case .substituted(let heard):
                                                var s = AttributedString("\(item.expected) [→ \(heard)]")
                                                s.foregroundColor = .orange
                                                next.append(s)
                                            }
                                            return next
                                        })
                                        .font(.system(size: 15, weight: .medium))
                                        .fixedSize(horizontal: false, vertical: true)

                                        Text("Распознано целиком: «\(cmp.heardClean.isEmpty ? "тишина" : cmp.heardClean)»")
                                            .font(.system(size: 11.5))
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(12)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                                    )
                                }
                            }
                        }

                        // Active typing + AI evaluation (in RU -> EN and Listening modes)
                        if vm.practiceDirection == .ruToEn || vm.practiceDirection == .listening {
                            HStack(spacing: 8) {
                                TextField(
                                    vm.practiceDirection == .listening
                                        ? "Напишите услышанную английскую фразу (или перевод)..."
                                        : "Попробуйте написать свой вариант по-английски...",
                                    text: $vm.userAttempt
                                )
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
                                .font(.system(size: 12.5))
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if vm.isCheckingWithAI || !vm.aiFeedback.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Label(vm.practiceDirection == .listening ? "Проверка аудирования" : "Оценка ИИ", systemImage: "sparkles")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                    if vm.isCheckingWithAI {
                                        ProgressView().controlSize(.mini)
                                    }
                                    Spacer()
                                }

                                Text(vm.aiFeedback.isEmpty ? "Проверяю ваш вариант..." : vm.aiFeedback)
                                    .font(.system(size: 13.5))
                                    .lineSpacing(3)
                                    .foregroundColor(vm.aiFeedback.isEmpty ? .secondary : .primary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(14)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 1)
                            )
                        }

                        // Answer reveal box (not duplicated in Speaking mode since target phrase is already visible)
                        if vm.isAnswerRevealed && vm.practiceDirection != .speaking {
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

                                    Button {
                                        SpeechHelper.shared.speakEnglish(card.english, speedOverride: 0.75)
                                    } label: {
                                        Text("🐢 0.75x")
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }

                                if vm.practiceDirection == .listening {
                                    Text(card.english)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Text(card.russian)
                                        .font(.system(size: 14))
                                        .foregroundColor(.primary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text(vm.practiceDirection == .ruToEn ? card.english : card.russian)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(.accentColor)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                if !card.note.isEmpty {
                                    Text("Заметка: \(card.note)")
                                        .font(.system(size: 12.5))
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(14)
                            .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }

                Divider()

                // Pinned bottom controls
                if vm.isAnswerRevealed {
                    HStack(spacing: 12) {
                        Button {
                            vm.rateCurrent(.again)
                        } label: {
                            VStack(spacing: 2) {
                                Text("Снова").font(.system(size: 13, weight: .semibold))
                                Text("10 мин").font(.system(size: 10.5)).foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
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
                            .padding(.vertical, 5)
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
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)
                        .keyboardShortcut("3", modifiers: [])
                    }
                } else {
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

    // MARK: - Tab 2: Client Chat Roleplay Simulator

    @ViewBuilder
    private func roleplayView() -> some View {
        VStack(spacing: 10) {
            // Scenario selector bar
            HStack(spacing: 8) {
                Picker("Сценарий:", selection: Binding(
                    get: { vm.selectedScenario },
                    set: { vm.startRoleplay(scenario: $0) }
                )) {
                    ForEach(RoleplayScenario.allCases) { sc in
                        Text(sc.title).tag(sc)
                    }
                }
                .frame(width: 240)

                Toggle("Автоозвучка", isOn: $vm.roleplayAutoSpeak)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))

                Spacer()

                Button("Начать заново") {
                    vm.startRoleplay(scenario: vm.selectedScenario)
                }
                .controlSize(.small)
            }

            // Chat messages
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(vm.roleplayMessages) { msg in
                        if msg.isUser {
                            VStack(alignment: .trailing, spacing: 5) {
                                HStack {
                                    Spacer(minLength: 60)
                                    Text(msg.text)
                                        .font(.system(size: 13.5))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 9)
                                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                                        .textSelection(.enabled)
                                }

                                if let coach = msg.coachNote {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label(coach, systemImage: "graduationcap.fill")
                                            .font(.system(size: 12))
                                            .foregroundColor(.primary)
                                            .fixedSize(horizontal: false, vertical: true)

                                        if let better = msg.betterPhrase {
                                            HStack(spacing: 6) {
                                                Text("💡 Естественнее: «\(better)»")
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundColor(.accentColor)
                                                    .textSelection(.enabled)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                Spacer()
                                                Button {
                                                    SpeechHelper.shared.speakEnglish(better)
                                                } label: {
                                                    Image(systemName: "speaker.wave.2")
                                                        .font(.system(size: 11))
                                                }
                                                .buttonStyle(.plain)

                                                Button {
                                                    vm.saveBetterPhraseToVocab(english: better, userOriginal: msg.text)
                                                } label: {
                                                    Image(systemName: vocabStore.contains(english: better) ? "bookmark.fill" : "bookmark")
                                                        .font(.system(size: 11))
                                                        .foregroundColor(.orange)
                                                }
                                                .buttonStyle(.plain)
                                                .help("Сохранить этот вариант в тренажёр")
                                            }
                                        }
                                    }
                                    .padding(10)
                                    .frame(maxWidth: 520, alignment: .leading)
                                    .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .strokeBorder(Color.orange.opacity(0.24), lineWidth: 1)
                                    )
                                }
                            }
                        } else {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        Text("Клиент")
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Button {
                                            SpeechHelper.shared.speakEnglish(msg.text)
                                        } label: {
                                            Image(systemName: "speaker.wave.2")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Озвучить реплику клиента")

                                        Button {
                                            SpeechHelper.shared.speakEnglish(msg.text, speedOverride: 0.75)
                                        } label: {
                                            Text("🐢")
                                                .font(.system(size: 11))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Озвучить медленно (0.75x)")

                                        Button("Перевод") {
                                            vm.translateClientMessageHint(id: msg.id)
                                        }
                                        .font(.system(size: 10.5))
                                        .buttonStyle(.plain)
                                        .foregroundColor(.accentColor)
                                    }

                                    Text(msg.text)
                                        .font(.system(size: 13.5))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)

                                    if let hint = msg.russianHint {
                                        Divider()
                                        Text(hint)
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(12)
                                .frame(maxWidth: 500, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                                )
                                Spacer(minLength: 40)
                            }
                        }
                    }

                    if vm.isRoleplayBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Клиент печатает и коуч проверяет ответ...")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 4)
                    }
                }
                .padding(.vertical, 4)
            }

            if let err = vm.roleplayError {
                Text(err)
                    .font(.system(size: 11.5))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    vm.toggleRoleplayMic()
                } label: {
                    if vm.isTranscribingRoleplay {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: vm.isRecordingRoleplay ? "stop.circle.fill" : "mic.fill")
                            .foregroundColor(vm.isRecordingRoleplay ? .red : .primary)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(vm.isRoleplayBusy || vm.isTranscribingRoleplay)
                .help(vm.isRecordingRoleplay ? "Остановить запись и отправить клиенту" : "Ответить клиенту голосом (Whisper EN)")

                TextField(
                    vm.isRecordingRoleplay ? "Слушаю ваш английский ответ..." : "Ответьте клиенту по-английски (текстом или голосом 🎙️)...",
                    text: $vm.roleplayInput
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13.5))
                .onSubmit {
                    vm.sendRoleplayMessage()
                }

                Button {
                    vm.sendRoleplayMessage()
                } label: {
                    Label("Отправить", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isRoleplayBusy || vm.isRecordingRoleplay || vm.roleplayInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Tab 3: Vocabulary Deck

    @ViewBuilder
    private func deckView() -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
