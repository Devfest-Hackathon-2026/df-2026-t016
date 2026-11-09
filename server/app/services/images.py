"""画像の受け取り（#8）。"""

from __future__ import annotations

import re

from ..core import canonical as c
from ..core.crypto import verify_device_sig
from ..deps import Deps
from ..errors import ApiError
from ..repo.base import SESSIONS
from . import paths

MAX_IMAGE = 2 * 1024 * 1024
MAX_IMAGES = 150  # 1セッションの画像の枚数（T13）


def receive(deps: Deps, sid: str, sha: str, content_type: str, sig_b64: str, data: bytes) -> dict:
    if not re.fullmatch(r"[0-9a-f]{64}", sha):
        raise ApiError("BAD_REQUEST", "sha256 must be 64 lowercase hex")
    if content_type.split(";")[0].strip().lower() != "image/jpeg":
        raise ApiError("UNSUPPORTED_MEDIA", "Content-Type must be image/jpeg")
    if len(data) > MAX_IMAGE:
        raise ApiError("TOO_LARGE", "image exceeds 2MB")
    s = deps.repo.get(SESSIONS, sid)
    if s is None:
        raise ApiError("NOT_FOUND", "session not found")
    if s.get("status") not in ("recording", "completed"):
        raise ApiError("SESSION_CLOSED", "session is not accepting images")
    if c.sha256_hex(data) != sha:
        raise ApiError("HASH_MISMATCH", "image hash does not match the path")
    if not sig_b64 or not verify_device_sig(s["devicePubKey"], sig_b64, f"image:{sid}:{sha}".encode("utf-8")):
        raise ApiError("SIGNATURE_INVALID", "X-Device-Sig does not verify")
    path = paths.image(sid, sha)
    if deps.store.exists(path):
        return {"sha256": sha}  # すでにあれば成功（再送）
    # 上限の確認と同じハッシュの予約を1つのトランザクションにする。
    # GCS の保存前に確保するので、保存直後の障害でも数え漏れない。
    deps.repo.reserve_image(sid, sha, MAX_IMAGES)
    deps.store.create_if_absent(path, data, "image/jpeg")
    return {"sha256": sha}
