"""エンコードの決まり（tasks/00_共通仕様.md 3章）。

- JSON は sort_keys・区切りに空白なし・ensure_ascii=False で UTF-8 にする
- ハッシュは SHA-256 の16進・小文字
- バイト列は標準 base64（パディングあり）、ID とトークンは base64url（パディングなし）
- 時刻は UTC のミリ秒まで、末尾 Z
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import secrets
from datetime import datetime, timezone
from typing import Any


def dumps_bytes(obj: Any) -> bytes:
    """署名・保存に使う JSON のバイト列を作る。"""
    return json.dumps(
        obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def sha256_hex(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def b64e(b: bytes) -> str:
    """標準 base64（パディングあり）。"""
    return base64.b64encode(b).decode("ascii")


def b64d(s: str) -> bytes:
    """標準 base64 を厳密に復号する。不正な文字やパディングの誤りは ValueError。"""
    try:
        return base64.b64decode(s.encode("ascii"), validate=True)
    except (binascii.Error, UnicodeEncodeError) as e:
        raise ValueError("invalid base64") from e


def b64url_token(nbytes: int) -> str:
    """ランダムな nbytes を base64url（パディングなし）にする。"""
    return base64.urlsafe_b64encode(secrets.token_bytes(nbytes)).rstrip(b"=").decode("ascii")


def new_work_id() -> str:
    return "w_" + b64url_token(12)


def new_sid() -> str:
    return "s_" + b64url_token(12)


def new_public_id() -> str:
    return b64url_token(16)


def new_start_token() -> str:
    return b64url_token(32)


def iso_ms(dt: datetime | None = None) -> str:
    """UTC の `YYYY-MM-DDTHH:MM:SS.sssZ`。"""
    if dt is None:
        dt = datetime.now(timezone.utc)
    if dt.tzinfo is None:
        raise ValueError("naive datetime")
    dt = dt.astimezone(timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"
