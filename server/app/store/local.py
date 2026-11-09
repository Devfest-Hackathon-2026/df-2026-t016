"""ファイルシステム版（テストとローカル用）。"""

from __future__ import annotations

import os
import shutil
import threading
from pathlib import Path

from .base import Store


class LocalStore(Store):
    def __init__(self, root: str | os.PathLike):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()

    def _p(self, path: str) -> Path:
        p = (self.root / path).resolve()
        if self.root.resolve() not in p.parents:
            raise ValueError("path escapes store root")
        return p

    def put(self, path: str, data: bytes, content_type: str) -> None:
        p = self._p(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_name(p.name + ".tmp")
        tmp.write_bytes(data)
        os.replace(tmp, p)

    def create_if_absent(self, path: str, data: bytes, content_type: str) -> bool:
        with self._lock:
            p = self._p(path)
            if p.exists():
                return False
            self.put(path, data, content_type)
            return True

    def get(self, path: str) -> bytes | None:
        p = self._p(path)
        return p.read_bytes() if p.exists() else None

    def exists(self, path: str) -> bool:
        return self._p(path).exists()

    def list(self, prefix: str) -> list[str]:
        base = self.root
        out = []
        for f in base.rglob("*"):
            if f.is_file() and not f.name.endswith(".tmp"):
                rel = f.relative_to(base).as_posix()
                if rel.startswith(prefix):
                    out.append(rel)
        return sorted(out)

    def delete_prefix(self, prefix: str) -> int:
        names = self.list(prefix)
        for n in names:
            self._p(n).unlink(missing_ok=True)
        d = self.root / prefix
        if prefix.endswith("/") and d.is_dir():
            shutil.rmtree(d, ignore_errors=True)
        return len(names)
