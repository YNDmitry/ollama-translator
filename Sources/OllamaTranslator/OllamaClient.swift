import Foundation

enum OllamaError: LocalizedError {
    case invalidURL
    case connectionFailed(String)
    case httpError(Int, String)
    case emptyResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Некорректный URL Ollama"
        case .connectionFailed(let msg):
            return "Не удалось подключиться к Ollama. Убедитесь, что Ollama запущена (\(msg))"
        case .httpError(let code, let body):
            if code == 404 {
                return "Модель не найдена в Ollama (404). Проверьте имя модели в настройках."
            }
            return "Ошибка Ollama (\(code)): \(body)"
        case .emptyResponse:
            return "Ollama вернула пустой ответ"
        case .cancelled:
            return "Перевод отменён"
        }
    }
}

final class OllamaClient {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    func fetchModels(baseURL: String) async throws -> [String] {
        guard let url = URL(string: normalizedBaseURL(baseURL) + "/api/tags") else {
            throw OllamaError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OllamaError.connectionFailed(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.httpError(http.statusCode, body)
        }

        struct TagsResponse: Decodable {
            struct ModelInfo: Decodable { let name: String }
            let models: [ModelInfo]?
        }

        let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        return (decoded.models ?? []).map { $0.name }
    }

    func checkHealth(baseURL: String, modelName: String) async -> (online: Bool, modelAvailable: Bool, modelCount: Int) {
        do {
            let models = try await fetchModels(baseURL: baseURL)
            return (true, models.contains(modelName), models.count)
        } catch {
            return (false, false, 0)
        }
    }

    func warmup(config: AppConfig) async throws {
        guard let url = URL(string: normalizedBaseURL(config.ollamaBaseURL) + "/api/chat") else {
            throw OllamaError.invalidURL
        }

        var payload: [String: Any] = [
            "model": config.modelName,
            "messages": [
                ["role": "user", "content": "hi"]
            ],
            "stream": false,
            "keep_alive": config.keepAlive,
            "options": [
                "num_predict": 1
            ]
        ]
        if config.disableThinking {
            payload["think"] = false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.httpError(http.statusCode, body)
        }
    }

    /// Standard non-streaming translation (ideal for in-place replacement).
    func translate(
        text: String,
        config: AppConfig,
        toneOverride: TonePreset? = nil,
        directionOverride: TranslationDirection? = nil,
        alternativeTo: String? = nil
    ) async throws -> TranslationResult {
        try await translateStream(
            text: text,
            config: config,
            toneOverride: toneOverride,
            directionOverride: directionOverride,
            alternativeTo: alternativeTo,
            onPartial: nil
        )
    }

    /// Streaming translation with live partial updates via `onPartial`.
    func translateStream(
        text: String,
        config: AppConfig,
        toneOverride: TonePreset? = nil,
        directionOverride: TranslationDirection? = nil,
        alternativeTo: String? = nil,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> TranslationResult {
        let start = Date()

        let leadingWS = String(text.prefix(while: { $0 == " " || $0 == "\t" || $0 == "\n" }))
        let trailingWS = String(text.reversed().prefix(while: { $0 == " " || $0 == "\t" || $0 == "\n" }).reversed())
        let coreText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !coreText.isEmpty else {
            throw OllamaError.emptyResponse
        }

        let direction: TranslationDirection
        if let override = directionOverride, override != .auto {
            direction = override
        } else {
            direction = LanguageDetector.detectDirection(for: coreText)
        }

        let tone = toneOverride ?? config.defaultTone
        let systemPrompt = buildSystemPrompt(
            direction: direction,
            tone: tone,
            config: config,
            alternativeTo: alternativeTo
        )
        let temperature: Double = (alternativeTo != nil) ? 0.55 : 0.2

        let rawContent = try await streamChat(
            systemPrompt: systemPrompt,
            userPrompt: coreText,
            config: config,
            temperature: temperature
        ) { accumulated in
            if let cb = onPartial {
                let live = self.cleanStreamingPreview(accumulated, originalCore: coreText)
                if !live.isEmpty {
                    cb(live)
                }
            }
        }

        var cleaned = cleanModelOutput(rawContent, originalCore: coreText)
        cleaned = applyExactGlossaryReplacements(cleaned, direction: direction, glossary: config.glossary)

        guard !cleaned.isEmpty else {
            throw OllamaError.emptyResponse
        }

        let finalOutput = leadingWS + cleaned + trailingWS
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)

        return TranslationResult(
            originalText: text,
            translatedText: finalOutput,
            direction: direction,
            tone: tone,
            durationMs: elapsed
        )
    }

    /// Translates the user's reply using the client's incoming message as context.
    func translateContextReplyStream(
        clientMessage: String,
        userReply: String,
        config: AppConfig,
        tone: TonePreset,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> TranslationResult {
        let start = Date()
        let replyCore = userReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replyCore.isEmpty else { throw OllamaError.emptyResponse }

        let direction: TranslationDirection = LanguageDetector.detectDirection(for: replyCore) == .ruToEn ? .ruToEn : .polishEn
        let systemPrompt = buildReplySystemPrompt(
            clientMessage: clientMessage.trimmingCharacters(in: .whitespacesAndNewlines),
            direction: direction,
            tone: tone,
            config: config
        )

        let rawContent = try await streamChat(
            systemPrompt: systemPrompt,
            userPrompt: replyCore,
            config: config,
            temperature: 0.25
        ) { accumulated in
            if let cb = onPartial {
                let live = self.cleanStreamingPreview(accumulated, originalCore: replyCore)
                if !live.isEmpty {
                    cb(live)
                }
            }
        }

        var cleaned = cleanModelOutput(rawContent, originalCore: replyCore)
        cleaned = applyExactGlossaryReplacements(cleaned, direction: .ruToEn, glossary: config.glossary)

        guard !cleaned.isEmpty else { throw OllamaError.emptyResponse }

        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        return TranslationResult(
            originalText: replyCore,
            translatedText: cleaned,
            direction: direction,
            tone: tone,
            durationMs: elapsed
        )
    }

    /// Streams a concise Russian English-coach breakdown of vocabulary, grammar, and tone.
    func explainPhraseStream(
        originalText: String,
        translatedText: String,
        direction: TranslationDirection,
        config: AppConfig,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let orig = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trans = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orig.isEmpty, !trans.isEmpty else { throw OllamaError.emptyResponse }

        let englishText = (direction == .enToRu) ? orig : trans
        let systemPrompt: String
        let userPrompt: String

        if direction == .polishEn {
            systemPrompt = """
            Ты лаконичный преподаватель делового английского для русскоязычного специалиста.
            Отвечай строго НА РУССКОМ языке. Максимум 90–120 слов, без воды и вступлений.
            Формат ответа:
            • Что улучшено: 2–3 коротких пункта (грамматика, артикли, естественность речи).
            • Полезные фразы: 1–3 выражения из улучшенного варианта в формате `выражение — перевод`.
            """
            userPrompt = "Было: \(orig)\nСтало: \(trans)"
        } else {
            systemPrompt = """
            Ты лаконичный преподаватель английского для русскоязычного специалиста, который общается с зарубежными клиентами.
            Отвечай строго НА РУССКОМ языке. Максимум 90–120 слов, без воды и вступлений.
            Формат ответа:
            • Ключевые фразы: 2–4 полезных слова, коллокации или фразовых глагола из английского текста в формате `English phrase — перевод (краткий оттенок смысла)`.
            • Нюанс речи: 1 короткое предложение о тоне или почему носители говорят именно так.
            """
            userPrompt = "Английский: \(englishText)\nРусский: \((direction == .enToRu) ? trans : orig)"
        }

        let raw = try await streamChat(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            config: config,
            temperature: 0.3
        ) { accumulated in
            if let cb = onPartial {
                let live = self.cleanStreamingPreview(accumulated, originalCore: orig)
                if !live.isEmpty {
                    cb(live)
                }
            }
        }

        let cleaned = cleanModelOutput(raw, originalCore: orig)
        guard !cleaned.isEmpty else { throw OllamaError.emptyResponse }
        return cleaned
    }

    private func streamChat(
        systemPrompt: String,
        userPrompt: String,
        config: AppConfig,
        temperature: Double,
        onAccumulated: @escaping (String) -> Void
    ) async throws -> String {
        guard let url = URL(string: normalizedBaseURL(config.ollamaBaseURL) + "/api/chat") else {
            throw OllamaError.invalidURL
        }

        var payload: [String: Any] = [
            "model": config.modelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "stream": true,
            "keep_alive": config.keepAlive,
            "options": [
                "temperature": temperature,
                "top_p": 0.9
            ]
        ]

        if config.disableThinking {
            payload["think"] = false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw OllamaError.cancelled
        } catch is CancellationError {
            throw OllamaError.cancelled
        } catch {
            throw OllamaError.connectionFailed(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 400 { break }
            }
            if http.statusCode == 400 && config.disableThinking && errorBody.lowercased().contains("think") {
                var fallbackConfig = config
                fallbackConfig.disableThinking = false
                return try await streamChat(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    config: fallbackConfig,
                    temperature: temperature,
                    onAccumulated: onAccumulated
                )
            }
            throw OllamaError.httpError(http.statusCode, errorBody)
        }

        struct StreamChunk: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
            let done: Bool?
        }

        var accumulated = ""
        let decoder = JSONDecoder()

        do {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard let data = line.data(using: .utf8),
                      let chunk = try? decoder.decode(StreamChunk.self, from: data) else {
                    continue
                }
                if let piece = chunk.message?.content, !piece.isEmpty {
                    accumulated += piece
                    onAccumulated(accumulated)
                }
                if chunk.done == true {
                    break
                }
            }
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw OllamaError.cancelled
        } catch is CancellationError {
            throw OllamaError.cancelled
        } catch {
            throw OllamaError.connectionFailed(error.localizedDescription)
        }

        return accumulated
    }

    private func normalizedBaseURL(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed.isEmpty ? "http://127.0.0.1:11434" : trimmed
    }

    private func buildSystemPrompt(
        direction: TranslationDirection,
        tone: TonePreset,
        config: AppConfig,
        alternativeTo: String?
    ) -> String {
        var lines: [String] = []

        if direction == .polishEn {
            lines.append("You are an expert native English editor helping refine messages for client communication.")
            lines.append("Improve the user's English message: fix grammar, spelling, and awkward phrasing while preserving the exact meaning.")
            lines.append(tone.promptInstruction)
            lines.append("Strict rules:")
            lines.append("- Output ONLY the improved English message. No explanations, no notes, no prefixes, no quotes around the whole message unless the input itself is quoted.")
            lines.append("- Preserve formatting, line breaks, lists, emojis, URLs, code snippets, and placeholders.")
            lines.append("- Do NOT answer the message — strictly rewrite and polish it.")
        } else {
            let sourceLang = (direction == .ruToEn) ? "Russian" : "English"
            let targetLang = (direction == .ruToEn) ? "English" : "Russian"
            lines.append("You are a professional \(sourceLang)-to-\(targetLang) translator assisting with client communication.")
            lines.append("Translate the user's message from \(sourceLang) into natural, idiomatic \(targetLang).")
            lines.append(tone.promptInstruction)
            lines.append("Strict rules:")
            lines.append("- Output ONLY the final translation. No explanations, no notes, no prefixes, no quotes around the whole message unless the input itself is quoted.")
            lines.append("- Preserve formatting, line breaks, lists, emojis, URLs, code snippets, and placeholders.")
            lines.append("- Do NOT answer the message or continue the conversation — strictly translate it.")
        }

        if let prev = alternativeTo, !prev.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Provide a DIFFERENT natural phrasing than this previous version (keep the same meaning): \"\(prev.trimmingCharacters(in: .whitespacesAndNewlines))\"")
        }

        appendGlossaryAndNotes(to: &lines, direction: direction, config: config)
        return lines.joined(separator: "\n")
    }

    private func buildReplySystemPrompt(
        clientMessage: String,
        direction: TranslationDirection,
        tone: TonePreset,
        config: AppConfig
    ) -> String {
        var lines: [String] = [
            "You are a professional assistant helping write a natural English reply to a client.",
            "Here is the client's message for context ONLY (do NOT translate it):",
            "\"\"\"\n\(clientMessage)\n\"\"\"",
            direction == .polishEn
                ? "Refine the user's draft reply into natural, native-sounding English tailored to the client's message above."
                : "Translate the user's Russian draft reply into natural, idiomatic English tailored to the client's message above.",
            tone.promptInstruction,
            "Strict rules:",
            "- Output ONLY the final English reply ready to send. No explanations, no greetings unless implied by the user's draft, no surrounding quotes.",
            "- Stay faithful to what the user wants to say; do not invent facts or promises."
        ]

        appendGlossaryAndNotes(to: &lines, direction: .ruToEn, config: config)
        return lines.joined(separator: "\n")
    }

    private func appendGlossaryAndNotes(to lines: inout [String], direction: TranslationDirection, config: AppConfig) {
        let effectiveDir: TranslationDirection = (direction == .polishEn) ? .ruToEn : direction
        let activeRules = config.glossary.filter { entry in
            entry.enabled &&
            !entry.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !entry.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (entry.direction == .auto || entry.direction == effectiveDir)
        }

        if !activeRules.isEmpty {
            lines.append("Mandatory terminology / word replacements (always follow these preferences):")
            for rule in activeRules {
                lines.append("- \"\(rule.source)\" -> \"\(rule.target)\"")
            }
        }

        let extraNotes = config.customSystemNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extraNotes.isEmpty {
            lines.append("Additional user instructions:")
            lines.append(extraNotes)
        }
    }

    func cleanStreamingPreview(_ raw: String, originalCore: String) -> String {
        var text = raw
        // Hide complete <think>...</think> blocks
        if let regex = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>", options: [.caseInsensitive]) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }
        // If model opened <think> and hasn't closed it yet, hide reasoning until closed
        if let openRange = text.range(of: "<think>", options: [.caseInsensitive]) {
            text = String(text[..<openRange.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cleanModelOutput(_ raw: String, originalCore: String) -> String {
        var text = raw

        if let regex = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>", options: [.caseInsensitive]) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let origHasQuotes = (originalCore.hasPrefix("\"") && originalCore.hasSuffix("\"")) ||
                            (originalCore.hasPrefix("«") && originalCore.hasSuffix("»"))
        if !origHasQuotes && text.count >= 2 {
            if (text.hasPrefix("\"") && text.hasSuffix("\"")) ||
               (text.hasPrefix("«") && text.hasSuffix("»")) {
                text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return text
    }

    func applyExactGlossaryReplacements(_ text: String, direction: TranslationDirection, glossary: [GlossaryEntry]) -> String {
        let effectiveDir: TranslationDirection = (direction == .polishEn) ? .ruToEn : direction
        let exactRules = glossary.filter { entry in
            entry.enabled &&
            entry.mode == .exactReplace &&
            !entry.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (entry.direction == .auto || entry.direction == effectiveDir)
        }

        guard !exactRules.isEmpty else { return text }

        var result = text
        for rule in exactRules {
            let escaped = NSRegularExpression.escapedPattern(for: rule.source)
            let pattern = "(?<!\\p{L})\(escaped)(?!\\p{L})"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            let matches = regex.matches(in: result, options: [], range: nsRange)
            guard !matches.isEmpty else { continue }

            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let matchedStr = String(result[range])
                var replacement = rule.target

                if let firstMatched = matchedStr.first, firstMatched.isUppercase,
                   let firstRepl = replacement.first, firstRepl.isLowercase {
                    replacement = firstRepl.uppercased() + replacement.dropFirst()
                }
                result.replaceSubrange(range, with: replacement)
            }
        }

        return result
    }
}
