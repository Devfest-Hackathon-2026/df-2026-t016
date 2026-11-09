"""開始（#6）。同じトークン・同じ公開鍵の再送には、保存済みの開始証を返す。"""

from __future__ import annotations

import hmac
import json

from ..core import canonical as c
from ..core.crypto import load_device_key
from ..deps import Deps
from ..errors import ApiError
from ..repo.base import SESSIONS, WORKS
from . import paths


def _stored_start(deps: Deps, sid: str) -> tuple[dict, dict] | None:
    """保存済みの start.json と、その中の開始証（オブジェクト）を返す。"""
    raw = deps.store.get(paths.start(sid))
    if raw is None:
        return None
    stored = json.loads(raw)
    cert = json.loads(c.b64d(stored["startCert"]))
    return stored, cert


def start(deps: Deps, sid: str, start_token: str, device_pub_b64: str) -> dict:
    s = deps.repo.get(SESSIONS, sid)
    if s is None:
        raise ApiError("NOT_FOUND", "session not found")
    # 【T14】確定の途中・確定済みの作品には、新しい記録を始めない（手順7 でも確かめ直す）
    w = deps.repo.get(WORKS, s["workId"])
    if w is not None and w.get("status") in ("finalizing", "finalized") and not s.get("startTokenUsed"):
        raise ApiError("SESSION_CLOSED", "work is finalized")

    # 1. トークン
    got = c.sha256_hex(start_token.encode("utf-8"))
    if not hmac.compare_digest(got, s.get("startTokenHash") or ""):
        raise ApiError("TOKEN_INVALID", "start token does not match")

    # 2. 公開鍵の形式
    try:
        load_device_key(device_pub_b64)
    except ValueError as e:
        raise ApiError("BAD_REQUEST", f"devicePubKey: {e}") from e

    # 3. 使用済み（期限は見ない。応答が失われた後の再送を通すため）
    if s.get("startTokenUsed"):
        got_start = _stored_start(deps, sid)
        if got_start is None:
            raise ApiError("INTERNAL", "start certificate missing")
        stored, cert = got_start
        if cert["devicePubKey"] != device_pub_b64:
            raise ApiError("TOKEN_USED", "start token already used with another key")
        return {"startCert": stored["startCert"], "sig": stored["sig"]}

    # 4. 期限
    now = deps.clock()
    if c.iso_ms(now) > s["startTokenExpiresAt"]:
        raise ApiError("TOKEN_EXPIRED", "start token expired")

    # 5. 開始証を作って署名する
    cert_obj = {
        "v": 1,
        "type": "start",
        "sid": sid,
        "workId": s["workId"],
        "devicePubKey": device_pub_b64,
        # サーバが確かめたことだけを書く。App Check を通った記録なら appCheck も（T12）
        "checked": ["startToken", "appCheck"] if s.get("appCheckVerifiedAt") else ["startToken"],
        "issuedAt": c.iso_ms(now),
    }
    cert_bytes = c.dumps_bytes(cert_obj)
    sig = deps.signer.sign(cert_bytes)
    doc = {"startCert": c.b64e(cert_bytes), "sig": c.b64e(sig)}

    # 6. 無いときだけ保存する。重なったら、先に保存された方を使う
    created = deps.store.create_if_absent(paths.start(sid), c.dumps_bytes(doc), "application/json")
    if not created:
        got_start = _stored_start(deps, sid)
        assert got_start is not None
        doc, cert_obj = got_start
        if cert_obj["devicePubKey"] != device_pub_b64:
            raise ApiError("TOKEN_USED", "start token already used with another key")
    cert_hash = c.sha256_hex(c.b64d(doc["startCert"]))

    # 7. セッションと作品を更新する
    deps.repo.start_session(sid, device_pub_b64, cert_hash, cert_obj["issuedAt"])

    # 8. 保存済みのものを返す
    return {"startCert": doc["startCert"], "sig": doc["sig"]}
