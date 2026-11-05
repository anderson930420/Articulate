"""Articulate's companion recognizer: a Qwen3-ASR model (TEA-ASR-1.1) on MLX behind a tiny local HTTP API.

GET  /           -> "articulate-asr" once the model is loaded
POST /inference  -> multipart form: file (16 kHz mono 16-bit WAV), prompt (optional context) -> {"text": "..."}

Usage: python -I asr_server.py <model_dir> <port>
Articulate starts it on demand and stops it when idle; it also exits on its own when Articulate goes away.
"""
from __future__ import annotations

import argparse
import email
import io
import json
import os
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

# Articulate uses python -I, which omits the script directory from sys.path.
# Add only this script's trusted sibling directory, never the working directory.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from tea_common import PRIVATE_USE
from tea_model import load_tea_model

# TEA marks rewritten tokens with private-use characters; its tokenizer.json decoder strips them.
PARENT = os.getppid()


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


def main():
    global mx, np, transcribe, MODEL
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model_dir")
    parser.add_argument("port", type=int, nargs="?")
    parser.add_argument("--allow-trim", action="store_true")
    parser.add_argument("--measure-load", action="store_true", help="load, warm, print memory and exit; no HTTP socket")
    parser.add_argument("--no-retie", action="store_true", help="measurement control only")
    args = parser.parse_args()
    if not args.measure_load and args.port is None:
        parser.error("port is required unless --measure-load is used")
    if args.no_retie and not args.measure_load:
        parser.error("--no-retie is only for --measure-load")
    import mlx.core as mx
    import numpy as np
    from mlx_qwen3_asr import transcribe

    mx.set_cache_limit(256 * 1024 * 1024)
    mx.reset_peak_memory()
    started = time.perf_counter()
    MODEL, _, tying = load_tea_model(args.model_dir, retie=not args.no_retie, allow_trim=args.allow_trim)
    loaded_memory = mx.get_active_memory()
    load_peak = mx.get_peak_memory()
    # Compile GPU kernels before reporting ready, just as the original server did.
    transcribe(np.zeros(16000 * 3, dtype=np.float32), model=MODEL, language="Chinese")
    mx.synchronize()
    mx.clear_cache()
    print(f"loaded and warmed up {args.model_dir} in {time.perf_counter() - started:.1f}s, "
          f"{mx.get_active_memory() / 2**30:.2f} GiB in use", flush=True)
    print(json.dumps({"retie": tying, "after_load_active_bytes": loaded_memory,
                      "load_peak_bytes": load_peak, "warmed_active_bytes": mx.get_active_memory(),
                      "peak_bytes": mx.get_peak_memory()}), flush=True)
    if args.measure_load:
        return
    threading.Thread(target=exit_with_parent, daemon=True).start()
    # One request at a time: MLX inference is not meant to run concurrently.
    HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
