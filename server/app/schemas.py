"""shared/schemas の JSON Schema で形式を確かめる。"""

from __future__ import annotations

import json
import os
from functools import lru_cache
from pathlib import Path

from jsonschema import Draft202012Validator


def _schema_dir() -> Path:
    env = os.environ.get("SCHEMA_DIR")
    if env:
        return Path(env)
    here = Path(__file__).resolve()
    for base in (here.parents[1], here.parents[2]):  # Docker: /srv、手元: リポジトリのルート
        d = base / "shared" / "schemas"
        if d.is_dir():
            return d
    raise RuntimeError("shared/schemas not found; set SCHEMA_DIR")


@lru_cache(maxsize=None)
def validator(name: str) -> Draft202012Validator:
    schema = json.loads((_schema_dir() / f"{name}.schema.json").read_text(encoding="utf-8"))
    return Draft202012Validator(schema)


def first_error(name: str, obj) -> str | None:
    for e in validator(name).iter_errors(obj):
        where = "/".join(str(p) for p in e.absolute_path) or "(root)"
        return f"{where}: {e.message}"
    return None
