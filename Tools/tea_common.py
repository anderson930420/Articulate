"""CPU-only helpers used by the shipped TEA server and model loader."""
from __future__ import annotations

import json
import re
from pathlib import Path

PRIVATE_USE = re.compile("[\ue000-\uf8ff]+")


def read_json(path):
    return json.loads(Path(path).read_text("utf-8"))
