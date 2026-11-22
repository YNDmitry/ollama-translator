import Foundation

/// Pure spaced-repetition scheduling math (SM-2 lite), kept separate for easy unit testing.
enum SRSScheduler {
    static func apply(rating: ReviewRating, to card: VocabCard, now: Date = Date()) -> VocabCard {
        var updated = card
        switch rating {
        case .again:
            updated.repetitions = 0
            updated.intervalDays = 0
            updated.easeFactor = max(1.3, card.easeFactor - 0.2)
            updated.nextReviewAt = now.addingTimeInterval(10 * 60) // 10 minutes

        case .good:
            let nextReps = card.repetitions + 1
            let nextInterval: Double
            if nextReps == 1 {
                nextInterval = 1
            } else if nextReps == 2 {
                nextInterval = 3
            } else {
                nextInterval = max(1, (card.intervalDays * card.easeFactor).rounded())
            }
            updated.repetitions = nextReps
            updated.intervalDays = nextInterval
            updated.nextReviewAt = now.addingTimeInterval(nextInterval * 86_400)

        case .easy:
            let nextReps = card.repetitions + 1
            let nextInterval: Double
            if nextReps == 1 {
                nextInterval = 2
            } else if nextReps == 2 {
                nextInterval = 5
            } else {
                nextInterval = max(2, (card.intervalDays * card.easeFactor * 1.3).rounded())
            }
            updated.repetitions = nextReps
            updated.intervalDays = nextInterval
            updated.easeFactor = min(3.2, card.easeFactor + 0.15)
            updated.nextReviewAt = now.addingTimeInterval(nextInterval * 86_400)
        }
        return updated
    }

    static func updatedStats(_ stats: VocabStats, now: Date = Date(), calendar: Calendar = .current) -> VocabStats {
        var next = stats
        next.totalReviews += 1
        let todayKey = dayKey(for: now, calendar: calendar)

        if next.lastStudyDay == todayKey {
            return next
        }

        if let prevKey = next.lastStudyDay,
           let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           dayKey(for: yesterday, calendar: calendar) == prevKey {
            next.streakDays += 1
        } else {
            next.streakDays = 1
        }
        next.lastStudyDay = todayKey
        return next
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    static func exportAnkiTSV(cards: [VocabCard]) -> String {
        cards.map { card in
            let en = sanitizeTSV(card.english)
            let ru = sanitizeTSV(card.russian)
            let note = sanitizeTSV(card.note)
            return "\(en)\t\(ru)\t\(note)"
        }.joined(separator: "\n")
    }

    private static func sanitizeTSV(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class VocabStore: ObservableObject {
    static let shared = VocabStore()

    @Published private(set) var database: VocabDatabase = VocabDatabase()
    let vocabFileURL: URL

    var cards: [VocabCard] { database.cards }
    var stats: VocabStats { database.stats }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("OllamaTranslator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.vocabFileURL = dir.appendingPathComponent("vocab.json")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: vocabFileURL),
           let decoded = try? decoder.decode(VocabDatabase.self, from: data) {
            self.database = decoded
        }
    }

    func dueCards(now: Date = Date()) -> [VocabCard] {
        database.cards
            .filter { $0.nextReviewAt <= now }
            .sorted { $0.nextReviewAt < $1.nextReviewAt }
    }

    func contains(english: String) -> Bool {
        let norm = english.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !norm.isEmpty else { return false }
        return database.cards.contains {
            $0.english.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == norm
        }
    }

    @discardableResult
    func addCard(english: String, russian: String, note: String = "") -> Bool {
        let en = english.trimmingCharacters(in: .whitespacesAndNewlines)
        let ru = russian.trimmingCharacters(in: .whitespacesAndNewlines)
        let nt = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !en.isEmpty, !ru.isEmpty else { return false }
        if contains(english: en) {
            return false
        }

        let card = VocabCard(english: en, russian: ru, note: nt)
        database.cards.insert(card, at: 0)
        save()
        return true
    }

    func review(cardID: UUID, rating: ReviewRating, now: Date = Date()) {
        guard let idx = database.cards.firstIndex(where: { $0.id == cardID }) else { return }
        database.cards[idx] = SRSScheduler.apply(rating: rating, to: database.cards[idx], now: now)
        database.stats = SRSScheduler.updatedStats(database.stats, now: now)
        save()
    }

    func remove(id: UUID) {
        database.cards.removeAll { $0.id == id }
        save()
    }

    func addStarterClientCards() {
        let starters: [(String, String, String)] = [
            ("Could we hop on a quick call tomorrow?", "Можем созвониться ненадолго завтра?", "Естественный разговорно-деловой вариант для созвона"),
            ("Let me double-check and get back to you shortly.", "Дай мне перепроверить, и я скоро вернусь с ответом.", "Вежливый способ взять паузу для проверки"),
            ("Just a quick heads-up regarding the timeline.", "Короткое предупреждение по срокам.", "Heads-up — заранее предупредить клиента"),
            ("Everything looks good on my end.", "С моей стороны всё выглядит отлично.", "On my end — с моей стороны"),
            ("Thanks for bearing with us!", "Спасибо за терпение и понимание!", "Идеально, если была небольшая задержка")
        ]
        for (en, ru, note) in starters {
            addCard(english: en, russian: ru, note: note)
        }
    }

    func exportAnkiTSV() -> String {
        SRSScheduler.exportAnkiTSV(cards: database.cards)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(database) {
            try? data.write(to: vocabFileURL, options: .atomic)
        }
    }
}
