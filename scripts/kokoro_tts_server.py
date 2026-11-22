#!/usr/bin/env python3
"""Lightweight local HTTP server for Kokoro-82M neural TTS (kokoro-onnx)."""

import argparse
import io
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import soundfile as sf
from kokoro_onnx import Kokoro


def default_model_dir() -> str:
    return os.path.expanduser("~/Library/Application Support/OllamaTranslator/kokoro")


def main() -> None:
    parser = argparse.ArgumentParser(description="Local Kokoro-82M TTS server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18421)
    parser.add_argument("--model-dir", default=default_model_dir())
    args = parser.parse_args()

    model_path = os.path.join(args.model_dir, "kokoro-v1.0.onnx")
    voices_path = os.path.join(args.model_dir, "voices-v1.0.bin")

    if not os.path.exists(model_path) or not os.path.exists(voices_path):
        sys.stderr.write(f"Kokoro model files not found in {args.model_dir}\n")
        sys.exit(1)

    kokoro = Kokoro(model_path, voices_path)

    class TTSHandler(BaseHTTPRequestHandler):
        def log_message(self, format, *log_args):
            # Keep stdout/stderr quiet when launched from macOS app bundle
            return

        def do_GET(self):
            if self.path == "/health":
                payload = json.dumps({"status": "ok"}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            else:
                self.send_error(404)

        def do_POST(self):
            if self.path != "/tts":
                self.send_error(404)
                return

            try:
                content_len = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(content_len)
                data = json.loads(raw.decode("utf-8"))
                text = str(data.get("text", "")).strip()
                voice = str(data.get("voice", "af_heart")).strip() or "af_heart"
                speed = float(data.get("speed", 0.95))
                speed = max(0.5, min(2.0, speed))

                if not text:
                    self.send_error(400, "Empty text")
                    return

                lang = "en-gb" if voice.startswith(("bf_", "bm_")) else "en-us"
                samples, sample_rate = kokoro.create(text, voice=voice, speed=speed, lang=lang)

                buf = io.BytesIO()
                sf.write(buf, samples, sample_rate, format="WAV", subtype="PCM_16")
                wav_bytes = buf.getvalue()

                self.send_response(200)
                self.send_header("Content-Type", "audio/wav")
                self.send_header("Content-Length", str(len(wav_bytes)))
                self.end_headers()
                self.wfile.write(wav_bytes)
            except Exception as exc:
                msg = str(exc).encode("utf-8")
                self.send_response(500)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(msg)))
                self.end_headers()
                self.wfile.write(msg)

    server = ThreadingHTTPServer((args.host, args.port), TTSHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
