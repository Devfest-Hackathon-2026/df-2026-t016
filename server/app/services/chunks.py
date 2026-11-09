"""チャンクの受け取り（#7、tasks/T04 の処理順）。

途中で止まっても、同じ要求が重なっても、再送すれば同じ結果になるようにする。
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta

from ..core import canonical as c
from ..core.crypto import verify_device_sig
from ..deps import Deps
from ..errors import ApiError
from ..repo.base import SESSIONS
from ..schemas import first_error
from . import paths

MAX_HEADER = 4 * 1024
MAX_BODY = 64 * 1024
MAX_CHUNKS = 5000
MAX_DURATION = timedelta(hours=6)


def _parse_time(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def _read(deps: Deps, path: str) -> dict | None:
    raw = deps.store.get(path)
    return json.loads(raw) if raw is not None else None


def _stored_header_hash(doc: dict) -> str:
    return c.sha256_hex(c.b64d(doc["header"]))


def _receipt_header_hash(doc: dict) -> str:
    return json.loads(c.b64d(doc["receipt"]))["header"]


def receive(deps: Deps, sid: str, header_bytes: bytes, sig_rs: bytes, body_bytes: bytes) -> dict:
    h = c.sha256_hex(header_bytes)

    # 1. セッションとヘッダの seq
    s = deps.repo.get(SESSIONS, sid)
    if s is None:
        raise ApiError("NOT_FOUND", "session not found")
    if len(header_bytes) > MAX_HEADER:
        _reject(deps, sid)
        raise ApiError("TOO_LARGE", "header exceeds 4KB")
    if len(body_bytes) > MAX_BODY:
        _reject(deps, sid)
        raise ApiError("TOO_LARGE", "body exceeds 64KB")
    try:
        header = json.loads(header_bytes)
        seq = header["seq"]
        if not isinstance(seq, int) or isinstance(seq, bool) or seq < 0:
            raise ValueError
    except (ValueError, KeyError, TypeError):
        _reject(deps, sid)
        raise ApiError("BAD_REQUEST", "header is not valid JSON with seq")

    # 2. 受領証がすでにある
    rec = _read(deps, paths.receipt(sid, seq))
    if rec is not None:
        if _receipt_header_hash(rec) != h:
            raise ApiError("SEQ_CONFLICT", f"seq {seq} already has another header")
        return _finish(deps, sid, seq, h, header, rec)

    # 3. チャンクだけがすでにある（前回が保存の直後に止まった）
    stored = _read(deps, paths.chunk(sid, seq))
    if stored is not None:
        if _stored_header_hash(stored) != h:
            raise ApiError("SEQ_CONFLICT", f"seq {seq} already has another header")
        return _make_receipt(deps, sid, seq, h, header)

    # 4. 確かめる
    try:
        _verify(deps, sid, s, seq, header, h, header_bytes, sig_rs, body_bytes)
    except ApiError:
        _reject(deps, sid)
        raise

    # 5. チャンクを保存する（重なったら、先に保存された方だけを採用する）
    doc = {"header": c.b64e(header_bytes), "sig": c.b64e(sig_rs), "body": c.b64e(body_bytes)}
    if not deps.store.create_if_absent(paths.chunk(sid, seq), c.dumps_bytes(doc), "application/json"):
        stored = _read(deps, paths.chunk(sid, seq))
        if stored is None or _stored_header_hash(stored) != h:
            raise ApiError("SEQ_CONFLICT", f"seq {seq} already has another header")

    return _make_receipt(deps, sid, seq, h, header)


def _reject(deps: Deps, sid: str) -> None:
    deps.repo.increment_rejected(sid)


def _verify(deps, sid, s, seq, header, h, header_bytes, sig_rs, body_bytes) -> None:
    if s.get("status") != "recording":
        raise ApiError("SESSION_CLOSED", "session is not recording")
    head = s["head"]
    if head.get("final"):
        raise ApiError("SESSION_CLOSED", "final chunk already received")
    err = first_error("header", header)
    if err:
        raise ApiError("BAD_REQUEST", f"header: {err}")
    if header["sid"] != sid:
        raise ApiError("BAD_REQUEST", "header.sid does not match")
    if seq != head["seq"] + 1:
        raise ApiError("SEQ_GAP", f"expected seq {head['seq'] + 1}")
    if header["prev"] != head["hash"]:
        raise ApiError("PREV_MISMATCH", "prev does not match the head")
    if not verify_device_sig(s["devicePubKey"], c.b64e(sig_rs), header_bytes):
        raise ApiError("SIGNATURE_INVALID", "device signature does not verify")
    if c.sha256_hex(body_bytes) != header["body"] or len(body_bytes) != header["bodyLen"]:
        raise ApiError("HASH_MISMATCH", "body hash or length does not match")
    try:
        body = json.loads(body_bytes)
    except ValueError:
        raise ApiError("BAD_REQUEST", "body is not JSON")
    err = first_error("body", body)
    if err:
        raise ApiError("BAD_REQUEST", f"body: {err}")
    if len(c.b64d(body["tiles"])) != 96:
        raise ApiError("BAD_REQUEST", "body.tiles must be 96 bytes")
    if seq >= MAX_CHUNKS:
        raise ApiError("LIMIT_EXCEEDED", f"up to {MAX_CHUNKS} chunks per session")
    if deps.clock() - _parse_time(s["startedAt"]) > MAX_DURATION:
        raise ApiError("LIMIT_EXCEEDED", "session is longer than 6 hours")


def _make_receipt(deps: Deps, sid: str, seq: int, h: str, header: dict) -> dict:
    # 6. 受領証を作る（重なったら、先に保存された方を使う）
    obj = {"v": 1, "type": "receipt", "sid": sid, "seq": seq, "header": h, "receivedAt": c.iso_ms(deps.clock())}
    rb = c.dumps_bytes(obj)
    doc = {"receipt": c.b64e(rb), "sig": c.b64e(deps.signer.sign(rb))}
    if not deps.store.create_if_absent(paths.receipt(sid, seq), c.dumps_bytes(doc), "application/json"):
        doc = _read(deps, paths.receipt(sid, seq))
        assert doc is not None
        if _receipt_header_hash(doc) != h:
            raise ApiError("SEQ_CONFLICT", f"seq {seq} already has another header")
    return _finish(deps, sid, seq, h, header, doc)


def _finish(deps: Deps, sid: str, seq: int, h: str, header: dict, rec: dict) -> dict:
    # 7. 先頭を進める（中で状態を確かめ直す）。receivedAt は保存済みの受領証の値
    received_at = json.loads(c.b64d(rec["receipt"]))["receivedAt"]
    deps.repo.advance_head(sid, seq, h, received_at, bool(header.get("final") is True))
    # 8.
    return {"receipt": rec["receipt"], "sig": rec["sig"]}
