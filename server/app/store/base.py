"""オブジェクトの保存先（共通仕様6章の Cloud Storage）。"""

from __future__ import annotations

from abc import ABC, abstractmethod


class Store(ABC):
    @abstractmethod
    def put(self, path: str, data: bytes, content_type: str) -> None:
        """上書きして保存する。"""

    @abstractmethod
    def create_if_absent(self, path: str, data: bytes, content_type: str) -> bool:
        """無いときだけ作る。作れたら True、すでにあれば何もせず False。"""

    @abstractmethod
    def get(self, path: str) -> bytes | None: ...

    @abstractmethod
    def exists(self, path: str) -> bool: ...

    @abstractmethod
    def list(self, prefix: str) -> list[str]: ...

    @abstractmethod
    def delete_prefix(self, prefix: str) -> int: ...
