# Ollama Translator (RU ↔ EN) for macOS

**English** | [Русский](README.ru.md)

A lightweight, native macOS menu bar app for fast local **Russian ↔ English** translation powered by [Ollama](https://ollama.com) — built specifically for smooth client communication in Telegram, Slack, WhatsApp, Mail, browsers, and any other app.

Zero cloud APIs, zero subscriptions, 100% local and private. Pre-configured for `hf.co/mradermacher/Qwen3.5-4B-SOMPOA-heresy-v2-GGUF:Q4_K_M` (and works with any Ollama model).

## Download

Grab the prebuilt Apple Silicon bundle from **[GitHub Releases](https://github.com/YNDmitry/ollama-translator/releases/latest)**:

1. Download and unzip `OllamaTranslator-v2.0.0-arm64.zip`.
2. Drag `OllamaTranslator.app` to `/Applications/`.
3. If macOS Gatekeeper warns about an unsigned app, clear quarantine:
   ```bash
   xattr -dr com.apple.quarantine /Applications/OllamaTranslator.app
   ```
4. Launch the app and grant **System Settings → Privacy & Security → Accessibility** so it can read selected text and paste translations in place.

## Global Hotkeys (work in both RU & EN keyboard layouts)

| Shortcut | Action |
|---|---|
| **`⌃⌥T`** | **Translate & Replace in place** — replaces selected text directly inside any input field (automatically selects the entire input field via `⌘A` if nothing is selected) |
| **`⌃⌥P`** | **Floating Translation Popup** — live real-time streaming, one-click tone switching, alternative phrasing (`↻`), English polish (`✨`), inline glossary add, and context-aware reply to clients |
| **`⌃⌥E`** | **Polish English (`EN ✨ EN`)** — fixes grammar and makes your English sound native right in place |
| **`⌃⌥G`** | **Quick Translator Window** — standalone floating composer (`⌘↩` to translate, `⌘⇧C` to copy) |
| **`⌃⌥L`** | **English Trainer (SRS Flashcards)** — practice saved work phrases with spaced repetition, pronunciation, and AI feedback |
| **`Esc`** | Cancel an active translation or close the popup |

All shortcuts can be customized in **Settings → Hotkeys**.

## Features

- **In-place replacement + clipboard safety**: replaces your text directly in chat and automatically restores your previous clipboard contents.
- **Auto-select input field**: if you didn't highlight text before pressing `⌃⌥T` or `⌃⌥E`, the app grabs the whole message in the active input box (with a length safety guard so it won't replace large documents).
- **Real-time streaming**: words appear within ~0.2s in the floating popup (`⌃⌥P`) and Quick Translator (`⌃⌥G`).
- **Context-aware client replies**: highlight an incoming client message → press `⌃⌥P` → click **Reply**, type your answer in Russian, and hit `Enter`. The model uses the client's message as context to produce a natural English reply ready to copy or paste straight into the chat.
- **Active English Learning Suite**:
  - **AI English Coach (`🎓`)** — get a concise Russian breakdown of key vocabulary, phrasal verbs, grammar improvements, and tone nuances right inside the popup or Quick Translator.
  - **Lifelike Local Pronunciation (`🔊`)** — supports **Kokoro-82M** neural offline English voices (US & UK, ~200ms latency on Apple Silicon) with automatic fallback to macOS native speech synthesis. Run `./scripts/setup_kokoro_tts.sh` once to enable studio-quality Kokoro voices.
  - **Spaced-Repetition Flashcards (`⌃⌥L`)** — bookmark real phrases (`★`) from popups or translation history, practice `RU → EN` / `EN → RU` with SM-2-lite scheduling, type your own English translation for instant AI grading, track your daily streak (`🔥`), and export your deck to **Anki (`.tsv`)**.
- **Custom Glossary / Word Replacements**: define preferred translations or strict substitutions per word/phrase — either from Settings or inline right inside the popup:
  - *AI Hint* — injected into the system prompt so the term is inflected naturally in context.
  - *Exact Replace* — enforces strict post-translation replacement while preserving capitalization and word boundaries.
- **Tone Presets**: switch between *Business*, *Friendly*, *Concise*, and *Neutral* from the menu bar or directly inside the popup.
- **Translation History**: last 50 translations searchable in Settings, plus the last 10 accessible for 1-click copy from the menu bar.
- **Optimized for Qwen3.5**: disables reasoning mode (`think: false`), strips residual `<think>` tags, and keeps the model warm in memory (`keep_alive: 30m`).
- **Ollama Status & Launcher**: live connection indicator in the menu bar with 1-click Ollama launch if it isn't running.

## Build from Source

Requires macOS 13+ and Xcode Command Line Tools (`swiftc`). No external Swift dependencies.

```bash
git clone https://github.com/YNDmitry/ollama-translator.git
cd ollama-translator
./scripts/build_app.sh
cp -R dist/OllamaTranslator.app /Applications/
open /Applications/OllamaTranslator.app
```

Make sure Ollama is running and your model is pulled:

```bash
ollama run hf.co/mradermacher/Qwen3.5-4B-SOMPOA-heresy-v2-GGUF:Q4_K_M
```

## Configuration Files

- Settings & glossary: `~/Library/Application Support/OllamaTranslator/config.json`
- Translation history: `~/Library/Application Support/OllamaTranslator/history.json`

## License

[MIT](LICENSE)
