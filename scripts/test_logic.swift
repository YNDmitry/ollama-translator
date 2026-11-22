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
        assertEqual(decodedV1.autoSelectAllWhenEmpty, true, "v1 config defaults new autoSelectAllWhenEmpty")

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

        print("All logic assertions passed!")
    }
}
