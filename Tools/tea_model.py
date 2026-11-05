"""Small, lazy MLX adapter shared by the server and experiments."""
from __future__ import annotations

import gc
from pathlib import Path


def arrays_identical(left, right):
    """Compare bits (including signed zero/NaNs), with bounded temporary memory."""
    import mlx.core as mx
    if left.shape != right.shape or left.dtype != right.dtype:
        return False
    if left is right:
        return True
    # About 64 MB per comparison: few GPU round trips (each .item() waits for one), small temporaries.
    rows = max(1, (64 << 20) // max(1, left.nbytes // max(1, left.shape[0])))
    for start in range(0, left.shape[0], rows):
        if not mx.array_equal(left[start:start + rows].view(mx.uint8),
                              right[start:start + rows].view(mx.uint8)).item():
            return False
    return True


def retie_embeddings(model, config):
    """Share arrays only after checking config, packing metadata and every byte.

    Keep the existing QuantizedLinear call path; replacing it with a different
    projection implementation would unnecessarily complicate identity checks.
    """
    import mlx.core as mx
    text = config.text_config
    if not text.tie_word_embeddings or (config.classify_num or text.vocab_size) != text.vocab_size:
        return {"tied": False, "reason": "config_not_tied", "shared_bytes": 0}
    embedding, head = model.model.embed_tokens, model.lm_head
    if getattr(head, "weight", None) is getattr(embedding, "weight", None):
        # Saved without a separate head (prepare_asr_model.py): the library already shares the
        # table. Only its small scales are separate copies (19 MB at 6 bits); checking them costs ~0.2 s of
        # every server start and frees nothing measurable.
        return {"tied": True, "reason": "already_shared", "shared_bytes": 0}
    for attribute in ("bits", "group_size", "mode"):
        if getattr(head, attribute, None) != getattr(embedding, attribute, None):
            return {"tied": False, "reason": "packing_differs", "shared_bytes": 0}
    names = ["weight"]
    for name in ("scales", "biases"):
        left, right = getattr(head, name, None), getattr(embedding, name, None)
        if (left is None) != (right is None):
            return {"tied": False, "reason": "packing_differs", "shared_bytes": 0}
        if left is not None:
            names.append(name)
    if not all(arrays_identical(getattr(head, n), getattr(embedding, n)) for n in names):
        return {"tied": False, "reason": "tensor_bytes_differ", "shared_bytes": 0}
    shared = sum(getattr(head, n).nbytes for n in names if getattr(head, n) is not getattr(embedding, n))
    for name in names:
        setattr(head, name, getattr(embedding, name))
    # Drop the final comparison references as well as the old head arrays.
    left = right = None
    gc.collect()
    mx.clear_cache()
    return {"tied": True, "reason": "identical", "shared_bytes": shared}


def load_tea_model(folder, *, retie=True, allow_trim=False):
    from tea_common import read_json
    folder = Path(folder).resolve()
    if not (folder / "config.json").is_file():
        raise ValueError("model must be an existing local folder; downloads are disabled")
    trimmed = (folder / "tea_trim.json").exists()
    if trimmed and not allow_trim:
        raise ValueError("compact vocabulary requires --allow-trim")
    from mlx_qwen3_asr import load_model
    model, config = load_model(str(folder))
    info = retie_embeddings(model, config) if retie else {"tied": False, "reason": "disabled", "shared_bytes": 0}
    if trimmed:
        if not retie or not info["tied"]:
            raise ValueError("compact vocabulary requires identical tied embeddings")
        install_compact_vocabulary(model, config, folder, read_json(folder / "tea_trim.json"))
    return model, config, info


def install_compact_vocabulary(model, config, folder, metadata):
    """Adapt original IDs to compact rows without patching the ASR library.

    The head computes only kept rows, then scatters those logits into original
    ID positions (-inf elsewhere). The library's unchanged greedy argmax thus
    returns the original ID, including its lowest-ID tie break. A small dense
    logits buffer costs ~0.3 MB per token, not a full vocabulary weight table.

    Removed input embeddings remain on disk. If a dictionary/prompt contains
    one, read only those rows, preserving its exact original embedding. They
    are never candidates for output. No unknown-token substitutions occur.
    """
    import mlx.core as mx
    import mlx.nn as nn
    import numpy as np
    kept = metadata["kept_ids"]
    size = metadata["original_vocab_size"]
    if kept != sorted(set(kept)) or not kept or kept[0] < 0 or kept[-1] >= size:
        raise ValueError("invalid compact vocabulary ID map")
    if len(kept) != config.text_config.vocab_size:
        raise ValueError("compact vocabulary size mismatch")
    mapping = np.full(size, -1, dtype=np.int32)
    mapping[kept] = np.arange(len(kept), dtype=np.int32)
    dropped = sorted(set(range(size)) - set(kept))
    disk_rows = {token_id: row for row, token_id in enumerate(dropped)}
    table = model.model.embed_tokens

    def fallback_rows(ids):
        tensors = {}
        for name, spec in metadata["fallback_tensors"].items():
            dtype = np.dtype(spec["dtype"])
            width = spec["shape"][1]
            row_bytes = width * dtype.itemsize
            filename = spec["file"]
            if Path(filename).name != filename:
                raise ValueError("invalid fallback tensor filename")
            with (folder / filename).open("rb") as stream:
                rows = []
                for token_id in ids:
                    stream.seek(disk_rows[int(token_id)] * row_bytes)
                    data = stream.read(row_bytes)
                    if len(data) != row_bytes:
                        raise ValueError("incomplete fallback tensor")
                    rows.append(np.frombuffer(data, dtype=dtype))
            tensors[name] = mx.array(np.stack(rows))
        return mx.dequantize(tensors["weight"], scales=tensors["scales"], biases=tensors["biases"],
                             group_size=table.group_size, bits=table.bits, mode=table.mode)

    class CompactEmbedding(nn.Module):
        def __init__(self):
            super().__init__()
            self.table = table
            self.id_to_row = mx.array(mapping)

        def __call__(self, ids):
            rows = self.id_to_row[ids]
            embeddings = self.table(mx.maximum(rows, 0))
            if int(mx.min(rows).item()) < 0:
                host_ids = np.asarray(ids).reshape(-1)
                positions = np.flatnonzero(mapping[host_ids] < 0)
                replacement = fallback_rows(host_ids[positions])
                flat = embeddings.reshape(-1, embeddings.shape[-1])
                flat[mx.array(positions.astype(np.int32))] = replacement
                embeddings = flat.reshape(embeddings.shape)
            return embeddings

    class CompactHead(nn.Module):
        def __init__(self, head):
            super().__init__()
            self.head = head
            self.kept_ids = mx.array(kept, dtype=mx.int32)

        def __call__(self, hidden):
            compact = self.head(hidden)
            logits = mx.full((*compact.shape[:-1], size), -float("inf"), dtype=compact.dtype)
            logits[..., self.kept_ids] = compact
            return logits

    model.model.embed_tokens = CompactEmbedding()
    model.lm_head = CompactHead(model.lm_head)
    # Range validation and all public/tokenizer-facing IDs keep the old size.
    config.text_config.vocab_size = size
    model.eval()
    mx.eval(model.parameters())
