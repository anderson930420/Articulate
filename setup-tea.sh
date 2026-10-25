#!/bin/bash
# Installs the companion recognizer for Articulate's "Apple＋TEA 融合" mode:
#   - a Python environment with mlx-qwen3-asr (packages pinned to releases from before 2026-09-30)
#   - TEA-ASR-1.1 (JacobLinCool/TEA-ASR-1.1, MIT, ~4.1 GB, pinned revision, SHA-256 checked) and an 8-bit copy (~2.5 GB)
#   - the local server script Articulate starts while you dictate
# Needs uv (brew install uv) and Python 3.12 (brew install python@3.12). Safe to run again.
set -euo pipefail
cd "$(dirname "$0")"

SUPPORT="$HOME/Library/Application Support/Articulate"
ASR="$SUPPORT/ASR"
SOURCE="$SUPPORT/Models/tea-asr-1.1"
TARGET="$SUPPORT/Models/tea-asr-1.1-8bit"
REVISION=bda08df76d4fd6b487b4a1dd7f0bddf8541696f8
WEIGHTS_SHA256=1e9db0943be34be1e6d13b9a895dfccfe941de045bba1b502d8449431ee79ea2
FILES="added_tokens.json chat_template.jinja config.json generation_config.json preprocessor_config.json
special_tokens_map.json tokenizer.json tokenizer_config.json model.safetensors"

mkdir -p "$ASR"
cp Tools/asr_server.py Tools/prepare_asr_model.py "$ASR/"

if [ ! -x "$ASR/venv/bin/python" ]; then
    echo "== Python environment"
    uv venv --python python3.12 "$ASR/venv"
    VIRTUAL_ENV="$ASR/venv" uv pip install --exclude-newer 2026-09-30 "mlx-qwen3-asr==0.4.4"
fi

if [ ! -f "$TARGET/model.safetensors" ]; then
    if [ ! -f "$SOURCE/model.safetensors" ]; then
        echo "== Downloading TEA-ASR-1.1 (about 4.1 GB)"
        mkdir -p "$SOURCE"
        for f in $FILES; do
            curl -sSfL --retry 3 -C - -o "$SOURCE/$f" "https://huggingface.co/JacobLinCool/TEA-ASR-1.1/resolve/$REVISION/$f"
        done
    fi
    echo "== Checking the model's SHA-256"
    echo "$WEIGHTS_SHA256  $SOURCE/model.safetensors" | shasum -a 256 -c -
    echo "== Making the 8-bit copy"
    "$ASR/venv/bin/python" -I "$ASR/prepare_asr_model.py" "$SOURCE" "$TARGET" 8
fi

echo "TEA-ASR ready. In Articulate: Settings › 語言 › 辨識模型 › Apple＋TEA 融合."
