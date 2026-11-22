#!/usr/bin/env python3
"""Lightweight local HTTP server for Kokoro-82M neural TTS (kokoro-onnx).

Features:
- Automatic idle shutdown (--idle-timeout, default 600s) to free RAM when unused.
- Parent PID watchdog (--parent-pid) so the server never stays orphaned if the app exits.
- POST /shutdown endpoint for immediate 1-click RAM release from the menu bar.
"""

import argparse
import io
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import soundfile as sf
from kokoro_onnx import Kokoro


def default_model_dir() -> str:
    return os.path.expanduser("~/Library/Application Support/OllamaTranslator/kokoro")


def parent_is_alive(pid: int) -> bool:
    if pid <= 0:
        return True
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def main() -> None:
    parser = argparse.ArgumentParser(description="Local Kokoro-82M TTS server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18421)
    parser.add_argument("--model-dir", default=default_model_dir())
    parser.add_argument("--idle-timeout", type=int, default=600)
    parser.add_argument("--parent-pid", type=int, default=0)
    args = parser.parse_args()

    model_path = os.path.join(args.model_dir, "kokoro-v1.0.onnx")
    voices_path = os.path.join(args.model_dir, "voices-v1.0.bin")

    if not os.path.exists(model_path) or not os.path.exists(voices_path):
        sys.stderr.write(f"Kokoro model files not found in {args.model_dir}\n")
        sys.exit(1)

    kokoro = Kokoro(model_path, voices_path)
    last_activity = [time.monotonic()]
    stop_event = threading.Event()

    def touch() -> None:
        last_activity[0] = time.monotonic()

    class TTSHandler(BaseHTTPRequestHandler):
        def log_message(self, format, *log_args):
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
            if self.path == "/shutdown":
                payload = b'{"status":"shutting_down"}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                stop_event.set()
                threading.Thread(target=server.shutdown, daemon=True).start()
                return

            if self.path != "/tts":
                self.send_error(404)
                return

            touch()
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
                touch()

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

    def watchdog() -> None:
        while not stop_event.wait(15.0):
            if not parent_is_alive(args.parent_pid):
                server.shutdown()
                return
            if args.idle_timeout > 0 and (time.monotonic() - last_activity[0]) >= args.idle_timeout:
                server.shutdown()
                return

    threading.Thread(target=watchdog, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop_event.set()
        server.server_close()


if __name__ == "__main__":
    main()
