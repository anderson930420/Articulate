"""Articulate's companion recognizer: a Qwen3-ASR model (TEA-ASR-1.1) on MLX behind a tiny local HTTP API.

GET  /           -> "articulate-asr" once the model is loaded
POST /inference  -> multipart form: file (16 kHz mono 16-bit WAV), prompt (optional context) -> {"text": "..."}

Usage: python -I asr_server.py <model_dir> <port>
Articulate starts it on demand and stops it when idle; it also exits on its own when Articulate goes away.
"""
import email
import io
import json
import os
import re
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, HTTPServer

import mlx.core as mx
import numpy as np
from mlx_qwen3_asr import load_model, transcribe

MODEL_DIR, PORT = sys.argv[1], int(sys.argv[2])
# TEA marks rewritten tokens with private-use characters; its tokenizer.json decoder strips them.
PRIVATE_USE = re.compile("[-]+")
PARENT = os.getppid()
# MLX keeps freed GPU buffers for reuse with no upper bound by default, so memory would only grow with use.
# Cap that cache and empty it after every request: the model itself is about 2 GB, the rest stays small.
mx.set_cache_limit(256 * 1024 * 1024)


def exit_with_parent():
    while True:
        time.sleep(2)
        if os.getppid() != PARENT:
            os._exit(0)


def parse_form(content_type: str, body: bytes) -> dict:
    message = email.message_from_bytes(b"Content-Type: " + content_type.encode() + b"\r\n\r\n" + body)
    fields = {}
    for part in message.get_payload():
        fields[part.get_param("name", header="content-disposition")] = part.get_payload(decode=True)
    return fields


def wav_samples(data: bytes) -> np.ndarray:
    with wave.open(io.BytesIO(data)) as w:
        if w.getframerate() != 16000 or w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise ValueError("expected 16 kHz mono 16-bit WAV")
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    return pcm.astype(np.float32) / 32768.0


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.reply(200, b"articulate-asr", "text/plain")

    def do_POST(self):
        if self.path != "/inference":
            self.reply(404, b"not found", "text/plain")
            return
        try:
            fields = parse_form(self.headers["Content-Type"], self.rfile.read(int(self.headers["Content-Length"])))
            audio = wav_samples(fields["file"])
            context = (fields.get("prompt") or b"").decode("utf-8")
            text = ""
            if len(audio) >= 1600:
                text = PRIVATE_USE.sub("", transcribe(audio, model=MODEL, context=context, language="Chinese").text).strip()
            self.reply(200, json.dumps({"text": text}, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")
        except Exception as error:  # Articulate falls back to Apple's transcript on any failure.
            self.reply(500, json.dumps({"error": str(error)}).encode("utf-8"), "application/json")
        finally:
            mx.clear_cache()

    def reply(self, status: int, payload: bytes, content_type: str):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


threading.Thread(target=exit_with_parent, daemon=True).start()
started = time.time()
MODEL = load_model(MODEL_DIR)[0]
# The first transcription compiles GPU kernels (about a second); do it before reporting ready.
transcribe(np.zeros(16000 * 3, dtype=np.float32), model=MODEL, language="Chinese")
mx.clear_cache()
print(f"loaded and warmed up {MODEL_DIR} in {time.time() - started:.1f}s, "
      f"{mx.get_active_memory() / 2**30:.2f} GB in use", flush=True)
# One request at a time: MLX inference is not meant to run concurrently on one model.
HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
