# AGENTS.md — Ollama Translator (macOS)

This file provides complete architectural context, build/test commands, and macOS/Swift gotchas for AI agents working on this repository.

## 1. Project Overview

**OllamaTranslator** (`com.local.OllamaTranslator`) is a lightweight, zero-dependency native macOS menu bar app (`LSUIElement = true`) for fast local **Russian ↔ English** translation and active English learning powered by a local [Ollama](https://ollama.com) instance.

- **Default Ollama endpoint**: `http://127.0.0.1:11434`
- **Default model**: `hf.co/mradermacher/Qwen3.5-4B-SOMPOA-heresy-v2-GGUF:Q4_K_M` (user-configurable; works with any Ollama chat model)
- **Target OS**: macOS 13.0+ (built natively for `arm64` / host arch)
- **Frameworks**: `AppKit`, `SwiftUI`, `Carbon`, `ApplicationServices`, `AVFoundation`, `Foundation` (Swift UI) + standalone native Rust crate `rust-tts/` (`kokoro-tts-rs`: `ort` + `misaki-rs` + `tiny_http`, statically linked, zero Python/espeak-ng runtime dependencies)
- **UI language**: Russian (documentation is bilingual: `README.md` in English by default, `README.ru.md` in Russian)

---

## 2. Repository Structure

```text
ollama-translator/
├── AGENTS.md                        # This file — agent instructions & context
├── Package.swift                    # SwiftPM manifest (for IDE/Xcode reference)
├── README.md                        # English README (default)
├── README.ru.md                     # Russian README
├── LICENSE                          # MIT
├── .gitignore                       # Ignores .build/, dist/, .DS_Store, etc.
├── rust-tts/                        # Native Rust Kokoro-82M TTS server (zero Python, zero espeak-ng)
│   ├── Cargo.toml                   # ort (static ONNX Runtime) + misaki-rs (pure Rust US/UK G2P) + tiny_http
│   ├── build.rs                     # Links Apple clang_rt.osx for CoreML version check symbol
│   ├── .cargo/config.toml           # Sets MACOSX_DEPLOYMENT_TARGET=14.0
│   ├── assets/kokoro_config.json    # Official hexgrad/Kokoro-82M IPA vocab embedded at compile time
│   └── src/main.rs                  # HTTP /health, /tts, /shutdown + 10m idle timeout + parent-PID watchdog + unit tests
├── scripts/
│   ├── build_app.sh                 # Release build (Swift + bundles kokoro-tts-rs), icon generation, .app bundling, ad-hoc codesign
│   ├── kokoro_tts_server.py         # Legacy Python fallback TTS server
│   ├── setup_kokoro_tts.sh          # Downloads ONLY Kokoro ONNX weights & voices (zero Python needed!)
│   └── test_logic.swift             # Standalone unit test runner (45+ assertions)
└── Sources/OllamaTranslator/
    ├── main.swift                   # NSApplication bootstrap (.accessory policy, MainActor.assumeIsolated)
    ├── AppDelegate.swift            # Menu bar (NSStatusItem), Ollama health check, workflow orchestration, window lifecycle
    ├── Models.swift                 # Data models (AppConfig, GlossaryEntry, HotkeyBinding, VocabCard, HistoryEntry, etc.)
    ├── ConfigStore.swift            # JSON config store + glossary helpers
    ├── HistoryStore.swift           # Last 50 translations persisted to history.json
    ├── VocabStore.swift             # Spaced-repetition (SM-2 lite) SRSScheduler + VocabStore (vocab.json, Anki TSV export)
    ├── LanguageDetector.swift       # Fast Unicode Cyrillic vs Latin RU↔EN direction detector
    ├── OllamaClient.swift           # Async/streaming Ollama /api/chat & /api/tags client, prompts, <think> stripping, exact glossary replace
    ├── HotkeyManager.swift          # Global Carbon hotkeys (works in both RU & EN keyboard layouts)
    ├── TextAutomation.swift         # Accessibility check, AXSelectedText + modifier-safe ⌘A/⌘C/⌘V, full pasteboard snapshot/restore
    ├── SpeechHelper.swift           # Local Kokoro-82M neural TTS (auto-started local HTTP daemon + AVAudioPlayer) with AVSpeechSynthesizer fallback
    ├── KokoroDownloader.swift       # In-app URLSessionDownloadDelegate downloader for Kokoro-82M weights with live progress & cancel
    ├── MicRecorder.swift            # AVAudioEngine 16 kHz mono PCM WAV recorder with live RMS level meter
    ├── WhisperService.swift         # Local whisper-cli runner (shared ~/Library/Application Support/WhisperModels/), model downloader, and LCS PronunciationDiff
    ├── LaunchAgentManager.swift     # Login auto-start toggle via ~/Library/LaunchAgents/com.local.OllamaTranslator.plist
    ├── HUDPanel.swift               # Non-activating floating NSPanel HUD (loading, toast, streaming popup, inline Coach/Reply/Glossary)
    ├── QuickTranslatorWindow.swift  # Standalone floating translator window (⌃⌥G) with streaming, TTS, Coach, and bookmarking
    ├── FlashcardsWindow.swift       # SRS English trainer window (⌃⌥L) with Practice + Deck tabs, AI attempt grading, streak, Anki export
    └── SettingsView.swift           # 4-tab Settings window (General, Glossary, Hotkeys with live recorder, searchable History)
```

---

## 3. Core User Workflows & Default Hotkeys

All hotkeys use physical Carbon `kVK_*` keycodes so they work identically regardless of whether the user is in Russian or English keyboard layout:

| Action | Default Hotkey | Behavior |
|---|---|---|
| Translate & Replace | `⌃⌥T` | Captures selected text (or auto-selects active input field via `⌘A` if `autoSelectAllWhenEmpty` is enabled and length ≤ 8000 chars), translates `RU ↔ EN`, pastes via `⌘V`, restores clipboard. |
| Floating Popup HUD | `⌃⌥P` | Captures selection, opens floating HUD near cursor with real-time NDJSON streaming, tone pills, Regenerate (`↻`), Polish (`✨`), Pronunciation (`🔊`), AI English Coach (`🎓`), Save to Flashcards (`🔖`), inline Glossary (`📖`), and context-aware Client Reply drawer. |
| Polish English | `⌃⌥E` | Rewrites selected English text (or active input field) into natural, grammatically clean client English (`EN ✨ EN`) in place. |
| Quick Translator | `⌃⌥G` | Opens floating composer window (`⌘↩` translate, `⌘⇧C` copy, streaming, Coach, TTS, Bookmark). |
| English Trainer | `⌃⌥L` | Opens SRS Flashcards window (`Space` reveal, `1/2/3` rate Again/Good/Easy, active typing with AI grading, daily streak, Anki `.tsv` export). |
| Cancel / Dismiss | `Esc` | Cancels active streaming/translation task (and restores clipboard if pending), or dismisses popup HUD. |

---

## 4. Runtime Data Paths

All user data is stored in `~/Library/Application Support/OllamaTranslator/`:

- `config.json` — `AppConfig` (Ollama URL, model name, default tone, keep-alive, `think: false`, custom hotkeys, glossary rules, flags)
- `history.json` — `[HistoryEntry]` (capped at 50 most recent entries, ISO-8601 dates)
- `vocab.json` — `VocabDatabase` (`cards: [VocabCard]`, `stats: VocabStats` with daily streak & total reviews)
- `~/Library/LaunchAgents/com.local.OllamaTranslator.plist` — created/deleted by `LaunchAgentManager` when "Launch at login" is toggled

---

## 5. Build, Test & Verification Commands

### Build release `.app` bundle
```bash
./scripts/build_app.sh
```
Produces signed `dist/OllamaTranslator.app` and verifies binary creation.

### Run unit tests
Include every pure-logic source file needed by `scripts/test_logic.swift`:
```bash
swiftc \
  -module-cache-path .build/module-cache \
  -framework Carbon -framework Foundation \
  Sources/OllamaTranslator/Models.swift \
  Sources/OllamaTranslator/LanguageDetector.swift \
  Sources/OllamaTranslator/OllamaClient.swift \
  Sources/OllamaTranslator/VocabStore.swift \
  scripts/test_logic.swift \
  -o .build/test_logic && ./.build/test_logic
```

### Verify `.app` signature & package release zip
```bash
codesign --verify --verbose dist/OllamaTranslator.app
ditto -c -k --sequesterRsrc --keepParent dist/OllamaTranslator.app dist/OllamaTranslator-vX.Y.Z-arm64.zip
shasum -a 256 dist/OllamaTranslator-vX.Y.Z-arm64.zip
```

### Install / update locally
```bash
killall OllamaTranslator 2>/dev/null || true
rm -rf /Applications/OllamaTranslator.app
cp -R dist/OllamaTranslator.app /Applications/
open /Applications/OllamaTranslator.app
```

---

## 6. Critical Technical Gotchas (READ BEFORE EDITING)

1. **NEVER use SwiftUI `@State` in this codebase**:
   - On macOS 27 Command Line Tools (without full Xcode.app), `SwiftUI.State` is declared as `#externalMacro(module: "SwiftUIMacros", type: "StateMacro")`, whose compiler plugin is missing in CLT.
   - Always hold view state in `@MainActor final class ...ViewModel: ObservableObject` using `@Published` + `@ObservedObject` (or `@Binding`). This compiles cleanly with `swiftc` across macOS 13–27.

2. **Compile directly via `swiftc`, not `swift build`**:
   - `./scripts/build_app.sh` invokes `swiftc -O -module-cache-path .build/module-cache ...` directly. This avoids SwiftPM/XCBuild cache permission errors in sandboxed environments and builds much faster because there are zero third-party dependencies.
   - When adding a new Apple framework, add `-framework <Name>` to both `scripts/build_app.sh` and `Package.swift`.

3. **Carbon Hotkey C-macro limitation**:
   - Do not use `InstallApplicationEventHandler(...)` — it is a function-like C macro unavailable in Swift. Always call `InstallEventHandler(GetApplicationEventTarget(), ...)` directly.

4. **Non-activating HUD focus & pasting (`HUDPanel.swift` + `TextAutomation.swift`)**:
   - `FloatingHUDPanel` uses `.nonactivatingPanel` and switches `allowsKeyFocus`:
     - `false` during `.loading` and `.toast` so the frontmost app never loses focus or text selection.
     - `true` during `.popup` so inline TextFields (Context Reply, Quick Glossary) accept typing when clicked.
   - `AppDelegate` snapshots `lastTargetApp = NSWorkspace.shared.frontmostApplication` before handling hotkeys and passes it to `TextAutomation.replaceSelectedText(..., targetApp:)` so pasting from Popup HUD reliably reactivates the target chat app first.

5. **Modifier-key collision when sending synthetic `⌘C` / `⌘A` / `⌘V`**:
   - When triggered by a hotkey like `⌃⌥T`, physical `⌃` and `⌥` are often still held down for ~100–250ms.
   - `TextAutomation.captureSelectedText()` first tries instant `AXSelectedTextAttribute` (zero clipboard flicker). On fallback, it polls `CGEventSource.flagsState(.hidSystemState)` until modifiers release (up to 420ms) before posting synthetic `CGEvent`s via `.privateState`.
   - Always preserve/restore the full `NSPasteboard` (all items & data types) unless `changeCount` changed externally.
   - Keep the `maxAutoSelectLength = 8000` safety guard on auto-`⌘A` so users never accidentally overwrite an entire webpage or large document.

6. **Qwen3.5 / Ollama streaming & output hygiene (`OllamaClient.swift`)**:
   - Always pass `"think": false` when `config.disableThinking == true` (with automatic retry fallback if Ollama returns HTTP 400 mentioning `think`).
   - During NDJSON streaming (`stream: true`), `cleanStreamingPreview` hides complete `<think>...</think>` blocks AND suppresses output while inside an unclosed `<think>` tag.
   - `cleanModelOutput` strips residual `<think>` tags and wrapping quotes (unless the original text itself was quoted).
   - `translateStream` preserves leading/trailing whitespace so in-place replacement does not glue adjacent words together.
   - `applyExactGlossaryReplacements` uses Unicode letter boundaries `(?<!\p{L})...(?!\p{L})` and preserves leading uppercase capitalization.

7. **Backward-compatible `AppConfig` decoding (`Models.swift`)**:
   - Whenever adding a new property to `AppConfig`, ALWAYS decode it in `init(from decoder: Decoder)` with `decodeIfPresent(...) ?? d.<field>` so existing users' `config.json` (glossary, custom hotkeys, model name) never resets on upgrade.
   - Also update `scripts/test_logic.swift` to verify v1 JSON decodes cleanly with the new default.

8. **App Icon bundling (`scripts/build_app.sh`)**:
   - `iconutil` can fail inside restricted sandboxes (`Invalid Iconset`). The build script keeps a pure-Python `.icns` packer fallback (`icp4`..`ic14`) that creates a valid Apple `.icns` from the `sips`-resized PNGs. Keep that fallback intact.

9. **GitHub Actions workflow scope**:
   - The local `gh` / git OAuth token may not have the `workflow` scope; pushing `.github/workflows/*.yml` will be rejected unless the user explicitly refreshes token scopes with `gh auth refresh -s workflow`.

---

## 7. Conventions for Future Changes

- **Keep pure logic decoupled from AppKit/SwiftUI**: put algorithms (language detection, output cleaning, regex glossary matching, SRS scheduling, TSV export) in pure Swift enums/methods so `scripts/test_logic.swift` can compile and test them headlessly in < 2 seconds.
- **Update version consistently**: when cutting a release, bump `CFBundleShortVersionString` and `CFBundleVersion` in `scripts/build_app.sh`, run `./scripts/build_app.sh`, run `scripts/test_logic.swift`, and verify `codesign --verify --verbose dist/OllamaTranslator.app`.
- **Keep docs in sync**: update both `README.md` (English, default) and `README.ru.md` (Russian) whenever hotkeys, features, or install steps change.
- **Avoid Swift 6 capture warnings where touching async closures**: prefer explicit `[weak self]` on the outer `Task { [weak self] in ... }` rather than mixing implicit strong outer capture with weak inner capture.
