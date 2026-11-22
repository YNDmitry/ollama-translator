import Foundation

@main
struct TestRunner {
    static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        if actual != expected {
            fputs("FAIL [\(label)]:\n  expected: \(expected)\n  actual:   \(actual)\n", stderr)
            exit(1)
        } else {
            print("PASS [\(label)]")
        }
    }

    static func main() {
        // 1. Language detection
        assertEqual(LanguageDetector.detectDirection(for: "Привет, давай созвонимся завтра в 15:00?"), .ruToEn, "RU -> EN detect")
        assertEqual(LanguageDetector.detectDirection(for: "Hi! Could we schedule a quick call tomorrow?"), .enToRu, "EN -> RU detect")
        assertEqual(LanguageDetector.detectDirection(for: "Отправил PR в GitHub, проверь пожалуйста"), .ruToEn, "Mixed mostly RU -> EN")
        assertEqual(LanguageDetector.detectDirection(for: "Thanks for the update on ТЗ, looks great!"), .enToRu, "Mixed mostly EN -> RU")

        // 2. Default config & hotkeys
        let cfg = AppConfig()
        assertEqual(cfg.modelName, "hf.co/mradermacher/Qwen3.5-4B-SOMPOA-heresy-v2-GGUF:Q4_K_M", "Default model name")
        assertEqual(cfg.disableThinking, true, "Disable thinking default")
        assertEqual(cfg.autoSelectAllWhenEmpty, true, "Auto-select-all default")
        assertEqual(cfg.replaceHotkey.displayString, "⌃⌥T", "Default replace hotkey")
        assertEqual(cfg.popupHotkey.displayString, "⌃⌥P", "Default popup hotkey")
        assertEqual(cfg.polishHotkey.displayString, "⌃⌥E", "Default polish hotkey")
        assertEqual(cfg.quickWindowHotkey.displayString, "⌃⌥G", "Default quick window hotkey")
        assertEqual(cfg.flashcardsHotkey.displayString, "⌃⌥L", "Default flashcards hotkey")

        // 3. Backward-compatible JSON decoding from v1.0 config (missing new fields)
        let v1JSON = """
        {
          "ollamaBaseURL": "http://127.0.0.1:11434",
          "modelName": "custom-model",
          "defaultTone": "friendly",
          "glossary": [
            { "id": "00000000-0000-0000-0000-000000000001", "source": "созвон", "target": "quick call", "direction": "ruToEn", "mode": "promptHint", "enabled": true }
          ]
        }
        """.data(using: .utf8)!
        let decodedV1 = try! JSONDecoder().decode(AppConfig.self, from: v1JSON)
        assertEqual(decodedV1.modelName, "custom-model", "v1 config preserves modelName")
        assertEqual(decodedV1.defaultTone, .friendly, "v1 config preserves defaultTone")
        assertEqual(decodedV1.glossary.count, 1, "v1 config preserves glossary")
        assertEqual(decodedV1.polishHotkey.displayString, "⌃⌥E", "v1 config defaults new polishHotkey")
        assertEqual(decodedV1.flashcardsHotkey.displayString, "⌃⌥L", "v1 config defaults new flashcardsHotkey")
        assertEqual(decodedV1.autoSelectAllWhenEmpty, true, "v1 config defaults new autoSelectAllWhenEmpty")
        assertEqual(decodedV1.ttsEngine, .kokoro, "v1 config defaults new ttsEngine")
        assertEqual(decodedV1.kokoroVoice, "af_heart", "v1 config defaults new kokoroVoice")
        assertEqual(decodedV1.ttsSpeed, 0.95, "v1 config defaults new ttsSpeed")

        // 4. Streaming preview & think-tag cleanup
        let client = OllamaClient()
        assertEqual(
            client.cleanStreamingPreview("<think>thinking about tone...", originalCore: "Привет"),
            "",
            "Hide unclosed <think> during streaming"
        )
        assertEqual(
            client.cleanStreamingPreview("<think>ok</think>\nHi there!", originalCore: "Привет"),
            "Hi there!",
            "Show text after </think> during streaming"
        )

        let withThink = "<think>\nLet me translate this politely...\n</think>\n\"Could we schedule a quick call tomorrow?\""
        assertEqual(
            client.cleanModelOutput(withThink, originalCore: "Можем созвониться завтра?"),
            "Could we schedule a quick call tomorrow?",
            "Strip <think> and unrequested quotes"
        )
        assertEqual(
            client.cleanModelOutput("\"Hello\"", originalCore: "\"Привет\""),
            "\"Hello\"",
            "Keep quotes when original had quotes"
        )

        // 5. Exact glossary replacement with boundaries & capitalization preservation
        let rules = [
            GlossaryEntry(source: "meeting", target: "quick call", direction: .ruToEn, mode: .exactReplace, enabled: true),
            GlossaryEntry(source: "API", target: "REST API", direction: .auto, mode: .exactReplace, enabled: true),
            GlossaryEntry(source: "disabled", target: "NOPE", direction: .auto, mode: .exactReplace, enabled: false)
        ]
        assertEqual(
            client.applyExactGlossaryReplacements("Meeting about our rapid API integration (disabled stays).", direction: .polishEn, glossary: rules),
            "Quick call about our rapid REST API integration (disabled stays).",
            "Exact glossary replacement works in polishEn and preserves capitalization/boundaries"
        )

        let ruRules = [
            GlossaryEntry(source: "встреча", target: "созвон", direction: .enToRu, mode: .exactReplace, enabled: true)
        ]
        assertEqual(
            client.applyExactGlossaryReplacements("Встреча перенесена на завтра.", direction: .enToRu, glossary: ruRules),
            "Созвон перенесена на завтра.",
            "Cyrillic exact replacement preserves capitalization"
        )

        // 6. Spaced Repetition (SRS) scheduling, daily streak & Anki TSV export
        let baseDate = Date(timeIntervalSince1970: 1_750_000_000)
        var card = VocabCard(english: "Could we hop on a quick call?", russian: "Можем созвониться ненадолго?", note: "Client phrase", createdAt: baseDate, nextReviewAt: baseDate)
        card = SRSScheduler.apply(rating: .good, to: card, now: baseDate)
        assertEqual(card.repetitions, 1, "SRS first good sets repetitions=1")
        assertEqual(card.intervalDays, 1.0, "SRS first good sets interval=1 day")

        card = SRSScheduler.apply(rating: .good, to: card, now: baseDate.addingTimeInterval(86_400))
        assertEqual(card.repetitions, 2, "SRS second good sets repetitions=2")
        assertEqual(card.intervalDays, 3.0, "SRS second good sets interval=3 days")

        card = SRSScheduler.apply(rating: .again, to: card, now: baseDate.addingTimeInterval(4 * 86_400))
        assertEqual(card.repetitions, 0, "SRS again resets repetitions")
        assertEqual(card.intervalDays, 0.0, "SRS again resets intervalDays")

        var stats = VocabStats()
        stats = SRSScheduler.updatedStats(stats, now: baseDate)
        assertEqual(stats.streakDays, 1, "First review sets streak=1")
        assertEqual(stats.totalReviews, 1, "Total reviews increments")
        stats = SRSScheduler.updatedStats(stats, now: baseDate.addingTimeInterval(3600))
        assertEqual(stats.streakDays, 1, "Same-day second review keeps streak=1")
        stats = SRSScheduler.updatedStats(stats, now: baseDate.addingTimeInterval(86_400))
        assertEqual(stats.streakDays, 2, "Next-day review increments streak=2")

        let tsv = SRSScheduler.exportAnkiTSV(cards: [
            VocabCard(english: "Heads-up", russian: "Предупреждение", note: "Line 1\nLine 2")
        ])
        assertEqual(tsv, "Heads-up\tПредупреждение\tLine 1<br>Line 2", "Anki TSV export escapes newlines cleanly")

        // 7. Phrase extractor JSON parsing (including markdown fence handling)
        let rawPhrases = """
        ```json
        [
          {"english": "hop on a quick call", "russian": "созвониться ненадолго", "note": "разговорно-деловой стиль"},
          {"english": "touch base", "russian": "связаться для сверки", "note": "короткий чек-ин"}
        ]
        ```
        """
        let extracted = client.parseExtractedPhrases(from: rawPhrases)
        assertEqual(extracted.count, 2, "Extracted phrases count")
        assertEqual(extracted[0].english, "hop on a quick call", "First extracted phrase english")
        assertEqual(extracted[1].russian, "связаться для сверки", "Second extracted phrase russian")

        // 8. Roleplay response parser (COACH / BETTER / CLIENT)
        let rpRaw = """
        COACH: Отличный ответ, но лучше чуть мягче.
        BETTER: Could we push the release to Thursday so we can finish QA?
        CLIENT: Thursday works for us! Thanks for the heads-up.
        """
        let parsedRP = client.parseRoleplayResponse(rpRaw)
        assertEqual(parsedRP.coachNote, "Отличный ответ, но лучше чуть мягче.", "Roleplay coach note parsed")
        assertEqual(parsedRP.betterPhrase, "Could we push the release to Thursday so we can finish QA?", "Roleplay better phrase parsed")
        assertEqual(parsedRP.clientReply, "Thursday works for us! Thanks for the heads-up.", "Roleplay client reply parsed")

        let rpNone = client.parseRoleplayResponse("COACH: Идеально!\nBETTER: NONE\nCLIENT: Sounds great!")
        assertEqual(rpNone.betterPhrase, nil, "Roleplay BETTER: NONE parses as nil")

        print("All logic assertions passed!")
    }
}
