#!/usr/bin/env bash
set -euo pipefail

APP_SUPPORT="$HOME/Library/Application Support/OllamaTranslator"
VENV_DIR="$APP_SUPPORT/kokoro-venv"
MODEL_DIR="$APP_SUPPORT/kokoro"

mkdir -p "$MODEL_DIR"

echo "==> Setting up isolated Python environment in $VENV_DIR..."
if command -v uv >/dev/null 2>&1; then
    uv venv --python 3.12 "$VENV_DIR"
    uv pip install --python "$VENV_DIR/bin/python" kokoro-onnx soundfile
else
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --upgrade pip
    "$VENV_DIR/bin/pip" install kokoro-onnx soundfile
fi

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

echo "==> Verifying Kokoro-82M installation..."
"$VENV_DIR/bin/python" -c "
from kokoro_onnx import Kokoro
k = Kokoro('$MODEL_FILE', '$VOICES_FILE')
samples, sr = k.create('Ready for realistic English pronunciation!', voice='af_heart', speed=0.95, lang='en-us')
print(f'OK! Generated {len(samples)} samples at {sr} Hz')
"

echo "==> Done! OllamaTranslator will now automatically use Kokoro-82M for natural offline English voice."
