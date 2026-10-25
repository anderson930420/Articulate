"""Prepares TEA-ASR-1.1 for mlx_qwen3_asr: tokenizer files, then an MLX 8-bit copy.

Usage: python -I prepare_asr_model.py <source_dir> <target_dir> [bits]
mlx_qwen3_asr reads vocab.json + merges.txt, while TEA ships only tokenizer.json, so those two
are derived from it (the same data, split out). The quantized copy keeps the config and tokenizer files.
"""
import json
import shutil
import sys
import time
from pathlib import Path

source, target = Path(sys.argv[1]), Path(sys.argv[2])
bits = int(sys.argv[3]) if len(sys.argv) > 3 else 8

if not (source / "vocab.json").exists() or not (source / "merges.txt").exists():
    model = json.loads((source / "tokenizer.json").read_text("utf-8"))["model"]
    (source / "vocab.json").write_text(json.dumps(model["vocab"], ensure_ascii=False), "utf-8")
    with open(source / "merges.txt", "w", encoding="utf-8") as f:
        f.write("#version: 0.2\n")
        for pair in model["merges"]:
            a, b = pair.split(" ") if isinstance(pair, str) else pair
            f.write(f"{a} {b}\n")
    print(f"derived vocab.json and merges.txt in {source}")

import mlx.core as mx  # noqa: E402  (only needed for quantizing)
from mlx.utils import tree_flatten  # noqa: E402
from mlx_qwen3_asr import load_model  # noqa: E402
from mlx_qwen3_asr.convert import quantize_model  # noqa: E402

target.mkdir(parents=True, exist_ok=False)
started = time.time()
loaded = load_model(str(source))[0]
quantize_model(loaded, bits=bits, group_size=64)
mx.save_safetensors(str(target / "model.safetensors"), dict(tree_flatten(loaded.parameters())))
(target / "quantization_config.json").write_text(json.dumps({"bits": bits, "group_size": 64}))
for f in source.iterdir():
    if f.name != "model.safetensors" and f.suffix in (".json", ".txt", ".jinja", ".md"):
        shutil.copy2(f, target / f.name)
print(f"quantized to {bits}-bit in {time.time() - started:.1f}s -> {target}")
