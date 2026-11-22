import Foundation

enum LanguageDetector {
    /// Detects whether input text should be translated RU -> EN or EN -> RU.
    static func detectDirection(for text: String) -> TranslationDirection {
        var cyrillicCount = 0
        var latinCount = 0

        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x0400...0x04FF).contains(v) || (0x0500...0x052F).contains(v) {
                cyrillicCount += 1
            } else if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) {
                latinCount += 1
            }
        }

        if cyrillicCount > 0 && cyrillicCount >= latinCount {
            return .ruToEn
        }
        if latinCount > 0 {
            return .enToRu
        }
        // Fallback when text has only symbols/numbers: default to RU -> EN
        return .ruToEn
    }
}
