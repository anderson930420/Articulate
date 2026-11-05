#!/usr/bin/env python3
"""CPU-only tests of shipped TEA code; synthetic fixtures, no Metal or real data."""
from __future__ import annotations

import importlib
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Tools"))
from tea_common import PRIVATE_USE


class RuntimeTests(unittest.TestCase):
    def test_private_use_matches_server_bmp_range(self):
        self.assertEqual(PRIVATE_USE.sub("", " \ue000合\uf8ff成 \n").strip(), "合成")
        self.assertEqual(PRIVATE_USE.sub("", "x\U000f0000"), "x\U000f0000")

    def test_all_tools_import_without_mlx(self):
        for name in ("tea_common", "tea_model", "asr_server"):
            importlib.import_module(name)
        self.assertNotIn("mlx.core", sys.modules)

class RetieTests(unittest.TestCase):
    def test_retie_requires_all_bytes_and_packing_metadata_to_match(self):
        import numpy as np
        from tea_model import arrays_identical, retie_embeddings
        core = types.ModuleType("mlx.core")
        core.uint8 = np.uint8
        core.array_equal = lambda a, b: np.asarray(np.array_equal(a, b))
        core.clear_cache = lambda: None
        mlx = types.ModuleType("mlx")
        mlx.core = core
        with patch.dict(sys.modules, {"mlx": mlx, "mlx.core": core}):
            self.assertFalse(arrays_identical(np.array([0.], dtype=np.float16), np.array([-0.], dtype=np.float16)))
            embedding = types.SimpleNamespace(weight=np.array([[1, 2]], dtype=np.uint32),
                        scales=np.array([[1.]], dtype=np.float16), biases=np.array([[0.]], dtype=np.float16),
                        bits=8, group_size=64, mode="affine")
            head = types.SimpleNamespace(**{key: value.copy() if isinstance(value, np.ndarray) else value
                                           for key, value in vars(embedding).items()})
            model = types.SimpleNamespace(model=types.SimpleNamespace(embed_tokens=embedding), lm_head=head)
            config = types.SimpleNamespace(classify_num=None, text_config=types.SimpleNamespace(tie_word_embeddings=True, vocab_size=1))
            head.biases[0, 0] = 2
            self.assertFalse(retie_embeddings(model, config)["tied"])
            self.assertIsNot(head.weight, embedding.weight)  # No partial mutation.
            head.biases[0, 0] = 0
            head.bits = 4
            self.assertFalse(retie_embeddings(model, config)["tied"])
            head.bits = 8
            info = retie_embeddings(model, config)
            self.assertEqual(info["shared_bytes"], 12)
            for name in ("weight", "scales", "biases"):
                self.assertIs(getattr(head, name), getattr(embedding, name))
            self.assertEqual(retie_embeddings(model, config)["shared_bytes"], 0)

if __name__ == "__main__":
    unittest.main(verbosity=2)
