import Foundation
import Carbon

enum TranslationDirection: String, Codable, CaseIterable, Identifiable {
    case auto
    case ruToEn
    case enToRu
    case polishEn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Авто (RU ↔ EN)"
        case .ruToEn: return "RU → EN"
        case .enToRu: return "EN → RU"
        case .polishEn: return "Улучшить EN ✨"
        }
    }

    var shortBadge: String {
        switch self {
        case .auto: return "AUTO"
        case .ruToEn: return "RU → EN"
        case .enToRu: return "EN → RU"
        case .polishEn: return "EN ✨ EN"
        }
    }

    static var glossaryDirections: [TranslationDirection] {
        [.auto, .ruToEn, .enToRu]
    }
}

enum TonePreset: String, Codable, CaseIterable, Identifiable {
    case business
    case friendly
    case concise
    case neutral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .business: return "Деловой"
        case .friendly: return "Дружелюбный"
        case .concise: return "Краткий"
        case .neutral: return "Нейтральный"
        }
    }

    var subtitle: String {
        switch self {
        case .business: return "Вежливый, профессиональный тон для клиентов"
        case .friendly: return "Тёплый, естественный и уважительный стиль общения"
        case .concise: return "Коротко и по делу, без лишней воды"
        case .neutral: return "Точный перевод с сохранением исходного тона"
        }
    }

    var promptInstruction: String {
        switch self {
        case .business:
            return "Use a polite, clear, professional tone appropriate for business communication with clients. Sound natural like a native speaker."
        case .friendly:
            return "Use a warm, friendly, approachable yet respectful tone suitable for ongoing client chats. Sound natural and conversational."
        case .concise:
            return "Keep the output concise, direct, and clear while remaining polite. Remove unnecessary filler words."
        case .neutral:
            return "Keep the output accurate and natural, preserving the original tone, intent, and formality level."
        }
    }
}

enum GlossaryMatchMode: String, Codable, CaseIterable, Identifiable {
    case promptHint
    case exactReplace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .promptHint: return "Подсказка ИИ"
        case .exactReplace: return "Точная замена"
        }
    }

    var helpText: String {
        switch self {
        case .promptHint: return "Передаётся модели в инструкцию (естественно склоняется в контексте)"
        case .exactReplace: return "Жёстко заменяет указанное слово/фразу в готовом переводе"
        }
    }
}

struct GlossaryEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var source: String
    var target: String
    var direction: TranslationDirection = .auto
    var mode: GlossaryMatchMode = .promptHint
    var enabled: Bool = true
}

struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey)

    static let defaultReplace = HotkeyBinding(
        keyCode: UInt32(kVK_ANSI_T),
        modifiers: UInt32(controlKey | optionKey)
    )

    static let defaultPopup = HotkeyBinding(
        keyCode: UInt32(kVK_ANSI_P),
        modifiers: UInt32(controlKey | optionKey)
    )

    static let defaultQuickWindow = HotkeyBinding(
        keyCode: UInt32(kVK_ANSI_G),
        modifiers: UInt32(controlKey | optionKey)
    )

    static let defaultPolish = HotkeyBinding(
        keyCode: UInt32(kVK_ANSI_E),
        modifiers: UInt32(controlKey | optionKey)
    )

    var displayString: String {
        var parts = ""
        if (modifiers & UInt32(controlKey)) != 0 { parts += "⌃" }
        if (modifiers & UInt32(optionKey)) != 0 { parts += "⌥" }
        if (modifiers & UInt32(shiftKey)) != 0 { parts += "⇧" }
        if (modifiers & UInt32(cmdKey)) != 0 { parts += "⌘" }
        parts += KeyCodeMapper.symbol(for: keyCode)
        return parts
    }
}

struct AppConfig: Codable, Equatable {
    var ollamaBaseURL: String = "http://127.0.0.1:11434"
    var modelName: String = "hf.co/mradermacher/Qwen3.5-4B-SOMPOA-heresy-v2-GGUF:Q4_K_M"
    var defaultTone: TonePreset = .business
    var keepAlive: String = "30m"
    var disableThinking: Bool = true
    var replaceHotkey: HotkeyBinding = .defaultReplace
    var popupHotkey: HotkeyBinding = .defaultPopup
    var quickWindowHotkey: HotkeyBinding = .defaultQuickWindow
    var polishHotkey: HotkeyBinding = .defaultPolish
    var glossary: [GlossaryEntry] = []
    var restoreClipboardAfterReplace: Bool = true
    var autoSelectAllWhenEmpty: Bool = true
    var customSystemNotes: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        ollamaBaseURL = (try? c.decodeIfPresent(String.self, forKey: .ollamaBaseURL)) ?? d.ollamaBaseURL
        modelName = (try? c.decodeIfPresent(String.self, forKey: .modelName)) ?? d.modelName
        defaultTone = (try? c.decodeIfPresent(TonePreset.self, forKey: .defaultTone)) ?? d.defaultTone
        keepAlive = (try? c.decodeIfPresent(String.self, forKey: .keepAlive)) ?? d.keepAlive
        disableThinking = (try? c.decodeIfPresent(Bool.self, forKey: .disableThinking)) ?? d.disableThinking
        replaceHotkey = (try? c.decodeIfPresent(HotkeyBinding.self, forKey: .replaceHotkey)) ?? d.replaceHotkey
        popupHotkey = (try? c.decodeIfPresent(HotkeyBinding.self, forKey: .popupHotkey)) ?? d.popupHotkey
        quickWindowHotkey = (try? c.decodeIfPresent(HotkeyBinding.self, forKey: .quickWindowHotkey)) ?? d.quickWindowHotkey
        polishHotkey = (try? c.decodeIfPresent(HotkeyBinding.self, forKey: .polishHotkey)) ?? d.polishHotkey
        glossary = (try? c.decodeIfPresent([GlossaryEntry].self, forKey: .glossary)) ?? d.glossary
        restoreClipboardAfterReplace = (try? c.decodeIfPresent(Bool.self, forKey: .restoreClipboardAfterReplace)) ?? d.restoreClipboardAfterReplace
        autoSelectAllWhenEmpty = (try? c.decodeIfPresent(Bool.self, forKey: .autoSelectAllWhenEmpty)) ?? d.autoSelectAllWhenEmpty
        customSystemNotes = (try? c.decodeIfPresent(String.self, forKey: .customSystemNotes)) ?? d.customSystemNotes
    }
}

struct TranslationResult: Equatable {
    let originalText: String
    let translatedText: String
    let direction: TranslationDirection
    let tone: TonePreset
    let durationMs: Int
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var originalText: String
    var translatedText: String
    var direction: TranslationDirection
    var tone: TonePreset
    var durationMs: Int
}

enum KeyCodeMapper {
    static func symbol(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Grave: return "`"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "Key(\(keyCode))"
        }
    }
}
