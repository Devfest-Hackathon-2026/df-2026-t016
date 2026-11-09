"""メモリ版（テスト用）。threading.RLock でトランザクションを直列にする。"""

from __future__ import annotations

import copy
import threading
from typing import Any, Callable, TypeVar

from .base import Repo, Txn

T = TypeVar("T")


class _MemTxn(Txn):
    def __init__(self, data: dict[str, dict[str, dict]]):
        self._data = data
        self._writes: list[tuple[str, str, str, dict | None]] = []

    def get(self, col, doc_id):
        d = self._data.get(col, {}).get(doc_id)
        return copy.deepcopy(d) if d is not None else None

    def set(self, col, doc_id, data):
        self._writes.append(("set", col, doc_id, copy.deepcopy(data)))

    def update(self, col, doc_id, fields):
        self._writes.append(("update", col, doc_id, copy.deepcopy(fields)))

    def delete(self, col, doc_id):
        self._writes.append(("delete", col, doc_id, None))

    def commit(self):
        for op, col, doc_id, data in self._writes:
            c = self._data.setdefault(col, {})
            if op == "set":
                c[doc_id] = data
            elif op == "update":
                if doc_id not in c:
                    raise KeyError(f"{col}/{doc_id} does not exist")
                c[doc_id].update(data)
            else:
                c.pop(doc_id, None)


class MemoryRepo(Repo):
    def __init__(self):
        self.data: dict[str, dict[str, dict]] = {}
        self._lock = threading.RLock()

    def run_txn(self, fn: Callable[[Txn], T]) -> T:
        with self._lock:
            t = _MemTxn(self.data)
            result = fn(t)  # 例外なら何も書かない
            t.commit()
            return result

    def get(self, col, doc_id):
        with self._lock:
            d = self.data.get(col, {}).get(doc_id)
            return copy.deepcopy(d) if d is not None else None

    def query_eq(self, col: str, field: str, value: Any):
        with self._lock:
            return [(k, copy.deepcopy(v)) for k, v in self.data.get(col, {}).items() if v.get(field) == value]

    # テスト用
    def set_direct(self, col: str, doc_id: str, fields: dict) -> None:
        with self._lock:
            self.data.setdefault(col, {}).setdefault(doc_id, {}).update(copy.deepcopy(fields))
