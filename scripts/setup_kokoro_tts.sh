#!/usr/bin/env bash
set -euo pipefail

# Downloads ONLY the Kokoro-82M v1.0 ONNX weights & voice embeddings.
# No Python, no uv, no virtualenvs required — OllamaTranslator v2.4+ bundles
# the self-contained native Rust binary (kokoro-tts-rs) directly inside the .app!

APP_SUPPORT="$HOME/Library/Application Support/OllamaTranslator"
MODEL_DIR="$APP_SUPPORT/kokoro"
mkdir -p "$MODEL_DIR"

MODEL_FILE="$MODEL_DIR/kokoro-v1.0.onnx"
VOICES_FILE="$MODEL_DIR/voices-v1.0.bin"

if [ ! -f "$MODEL_FILE" ]; then
    echo "==> Downloading Kokoro-82M v1.0 model (~310 MB)..."
    curl -fL --progress-bar \
        "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx" \
        -o "$MODEL_FILE.tmp"
    mv "$MODEL_FILE.tmp" "$MODEL_FILE"
else
    echo "==> Model already exists: $MODEL_FILE"
fi

if [ ! -f "$VOICES_FILE" ]; then
    echo "==> Downloading Kokoro v1.0 voices (~28 MB)..."
    curl -fL --progress-bar \
        "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin" \
        -o "$VOICES_FILE.tmp"
    mv "$VOICES_FILE.tmp" "$VOICES_FILE"
else
    echo "==> Voices file already exists: $VOICES_FILE"
fi

# Optional cleanup of legacy Python venv if user passes --clean-python
if [ "${1:-}" = "--clean-python" ] && [ -d "$APP_SUPPORT/kokoro-venv" ]; then
    echo "==> Removing legacy Python venv ($APP_SUPPORT/kokoro-venv)..."
    rm -rf "$APP_SUPPORT/kokoro-venv"
fi

# Verify with bundled native Rust TTS binary if present
RUST_BIN="/Applications/OllamaTranslator.app/Contents/MacOS/kokoro-tts-rs"
if [ ! -x "$RUST_BIN" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
    RUST_BIN="$SCRIPT_DIR/rust-tts/target/release/kokoro-tts-rs"
fi

if [ -x "$RUST_BIN" ]; then
    echo "==> Verifying with native Rust Kokoro engine..."
    "$RUST_BIN" --model-dir "$MODEL_DIR" --test-phrase "Native Rust Kokoro voice is ready!"
fi

echo "==> Done! OllamaTranslator will use the native Rust Kokoro-82M engine (zero Python)."
