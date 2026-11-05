"""Prepares TEA-ASR-1.1 for mlx_qwen3_asr: tokenizer files, then a quantized MLX copy.

Usage: python -I prepare_asr_model.py <source_dir> <target_dir> [bits]

bits 6 (the default): text decoder 6-bit, audio encoder 8-bit, groups of 64. About 1.75 GB loaded,
against 2.5 GB for the 8-bit copy older installs made. On the user's 200 newest recordings it matched
the unquantized model as closely as 8-bit did; 4-bit did not.
bits 8: everything 8-bit, as before.

mlx_qwen3_asr reads vocab.json + merges.txt, while TEA ships only tokenizer.json, so those two
are derived from it (the same data, split out). The quantized copy keeps the config and tokenizer files.
The output head is tied to the token embeddings: it is saved once, and the loader shares it.
The copy is written next to the target and renamed into place only when complete.
"""
import json
import shutil
import sys
import time
from pathlib import Path

source, target = Path(sys.argv[1]), Path(sys.argv[2])
bits = int(sys.argv[3]) if len(sys.argv) > 3 else 6
if bits not in (6, 8):
    sys.exit("bits must be 6 or 8")
ENCODER_BITS, GROUP_SIZE = 8, 64

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

if target.exists():
    sys.exit(f"{target} already exists")
partial = target.with_name(target.name + ".partial")
if partial.exists():
    shutil.rmtree(partial)  # left by an interrupted run of this script
partial.mkdir(parents=True)
started = time.time()
loaded, config = load_model(str(source))
quantize_model(loaded, bits=bits, group_size=GROUP_SIZE, encoder_bits=ENCODER_BITS)
mx.eval(loaded.parameters())
parameters = dict(tree_flatten(loaded.parameters()))
text = config.text_config
if text.tie_word_embeddings and (config.classify_num or text.vocab_size) == text.vocab_size:
    for name in ("weight", "scales", "biases"):
        head, table = parameters.get("lm_head." + name), parameters.get("model.embed_tokens." + name)
        if head is None or table is None or head.shape != table.shape or head.dtype != table.dtype \
                or not mx.array_equal(head.view(mx.uint8), table.view(mx.uint8)).item():
            sys.exit(f"tied lm_head.{name} differs from the token embeddings")
        del parameters["lm_head." + name]
mx.save_safetensors(str(partial / "model.safetensors"), parameters)
# mlx_qwen3_asr infers 4 and 8 bits from the tensors but not 6, so the decoder width must be stated here.
(partial / "quantization_config.json").write_text(json.dumps(
    {"bits": bits, "group_size": GROUP_SIZE, "encoder_bits": ENCODER_BITS, "mode": "affine"}))
for f in source.iterdir():
    if f.name != "model.safetensors" and f.suffix in (".json", ".txt", ".jinja", ".md"):
        shutil.copy2(f, partial / f.name)
partial.rename(target)
print(f"quantized to {bits}-bit (audio encoder {ENCODER_BITS}-bit) in {time.time() - started:.1f}s -> {target}")
