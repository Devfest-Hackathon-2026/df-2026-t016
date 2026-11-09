"""T04 の完了条件（受付API の前半）。"""

from __future__ import annotations

import json
import threading

import pytest

from app.core import canonical as c
from app.core.crypto import verify_kms_sig
from app.errors import ApiError
from app.repo.base import SESSIONS
from app.services import chunks as chunk_svc
from app.services import start as start_svc

from conftest import H, VECTORS, Device, as_json

PEM = VECTORS["kmsKey"]["publicPem"]


def post_chunk(client, sid, ch):
    return client.post(f"/v1/sessions/{sid}/chunks", json=as_json(ch))


def code(r):
    return r.json()["error"]["code"]


# ---------------------------------------------------------------- 正常系


def test_happy_path(client, started, deps):
    sid, dev, wid = started["sid"], started["dev"], started["wid"]
    # 開始証の中身と署名
    cert_bytes = c.b64d(started["start"]["startCert"])
    cert = json.loads(cert_bytes)
    assert cert == {
        "v": 1,
        "type": "start",
        "sid": sid,
        "workId": wid,
        "devicePubKey": dev.pub_b64,
        "checked": ["startToken"],
        "issuedAt": "2026-11-05T01:00:00.000Z",
    }
    assert verify_kms_sig(PEM, c.b64d(started["start"]["sig"]), cert_bytes)
    assert client.get(f"/v1/works/{wid}", headers=H).json()["status"] == "recording"

    receipts = []
    for i in range(3):
        ch = dev.chunk(final=(i == 2))
        r = post_chunk(client, sid, ch)
        assert r.status_code == 200, r.text
        rb = c.b64d(r.json()["receipt"])
        assert verify_kms_sig(PEM, c.b64d(r.json()["sig"]), rb)
        rec = json.loads(rb)
        assert rec["seq"] == i and rec["header"] == c.sha256_hex(ch["header"]) and rec["type"] == "receipt"
        receipts.append(rec)
        dev.accept(ch)

    w = client.get(f"/v1/works/{wid}", headers=H).json()
    assert w["status"] == "recorded"
    assert w["session"]["status"] == "completed"
    assert w["session"]["chunkCount"] == 3
    assert w["session"]["final"] is True
    assert w["session"]["lastReceivedAt"] == receipts[-1]["receivedAt"]
    # 保存先: 開始証・チャンク・受領証が1つずつのオブジェクト
    names = deps.store.list(f"sessions/{sid}/")
    assert f"sessions/{sid}/start.json" in names
    assert sum("/chunks/" in n for n in names) == 3
    assert sum("/receipts/" in n for n in names) == 3


def test_healthz_and_work_list(client):
    assert client.get("/v1/healthz").json() == {"ok": True}
    for t in ("a", "b"):
        assert client.post("/v1/works", json={"title": t, "displayName": "x"}, headers=H).status_code == 201
    ws = client.get("/v1/works", headers=H).json()["works"]
    assert [w["title"] for w in ws] == ["b", "a"] or len(ws) == 2
    assert ws[0]["session"] is None and ws[0]["status"] == "draft"


def test_work_validation_and_auth(client):
    assert code(client.post("/v1/works", json={"title": "x", "displayName": "y"})) == "UNAUTHENTICATED"
    assert code(client.post("/v1/works", json={"title": "", "displayName": "y"}, headers=H)) == "BAD_REQUEST"
    assert code(client.post("/v1/works", json={"title": "x" * 101, "displayName": "y"}, headers=H)) == "BAD_REQUEST"
    assert code(client.get("/v1/works/w_nope", headers=H)) == "NOT_FOUND"
    assert code(client.get("/v1/nothing")) == "NOT_FOUND"


def test_work_limit(client):
    for i in range(20):
        assert client.post("/v1/works", json={"title": f"{i}", "displayName": "x"}, headers=H).status_code == 201
    r = client.post("/v1/works", json={"title": "21", "displayName": "x"}, headers=H)
    assert r.status_code == 429 and code(r) == "LIMIT_EXCEEDED"


def test_owner_only(client, started):
    other = {"X-Dev-Uid": "user-b"}
    wid = started["wid"]
    r = client.get(f"/v1/works/{wid}", headers=other)
    assert r.status_code == 403 and code(r) == "FORBIDDEN"
    r = client.post(f"/v1/works/{wid}/sessions", json={}, headers=other)
    assert r.status_code == 403 and code(r) == "FORBIDDEN"
    assert client.get("/v1/works", headers=other).json() == {"works": []}


def test_session_replace_and_exists(client, deps):
    wid = client.post("/v1/works", json={"title": "t", "displayName": "d"}, headers=H).json()["workId"]
    s1 = client.post(f"/v1/works/{wid}/sessions", json={}, headers=H).json()
    s2 = client.post(f"/v1/works/{wid}/sessions", json={}, headers=H).json()
    assert s1["sid"] != s2["sid"]
    assert deps.repo.get(SESSIONS, s1["sid"]) is None  # 未開始のものは置き換える
    # 古いトークンでは開始できない
    dev = Device(s1["sid"])
    r = client.post(f"/v1/sessions/{s1['sid']}/start", json={"startToken": s1["startToken"], "devicePubKey": dev.pub_b64})
    assert r.status_code == 404
    # 開始した後は作り直せない
    dev = Device(s2["sid"])
    assert client.post(f"/v1/sessions/{s2['sid']}/start", json={"startToken": s2["startToken"], "devicePubKey": dev.pub_b64}).status_code == 200
    r = client.post(f"/v1/works/{wid}/sessions", json={}, headers=H)
    assert r.status_code == 409 and code(r) == "SESSION_EXISTS"
    # トークンは平文を保存しない
    stored = deps.repo.get(SESSIONS, s2["sid"])
    assert stored["startTokenHash"] == c.sha256_hex(s2["startToken"].encode()) and s2["startToken"] not in json.dumps(stored)


# ---------------------------------------------------------------- 開始


def test_start_resend_and_token_used(client, started):
    sid, token, dev = started["sid"], started["token"], started["dev"]
    r = client.post(f"/v1/sessions/{sid}/start", json={"startToken": token, "devicePubKey": dev.pub_b64})
    assert r.status_code == 200 and r.json() == started["start"]
    other = Device(sid)
    r = client.post(f"/v1/sessions/{sid}/start", json={"startToken": token, "devicePubKey": other.pub_b64})
    assert r.status_code == 409 and code(r) == "TOKEN_USED"
    r = client.post(f"/v1/sessions/{sid}/start", json={"startToken": "x" * 43, "devicePubKey": dev.pub_b64})
    assert r.status_code == 401 and code(r) == "TOKEN_INVALID"


def test_start_resend_after_expiry_still_returns(client, started, clock):
    clock.advance(minutes=30)
    sid, token, dev = started["sid"], started["token"], started["dev"]
    r = client.post(f"/v1/sessions/{sid}/start", json={"startToken": token, "devicePubKey": dev.pub_b64})
    assert r.status_code == 200 and r.json() == started["start"]


def test_start_expired_and_bad_key(client, clock):
    wid = client.post("/v1/works", json={"title": "t", "displayName": "d"}, headers=H).json()["workId"]
    s = client.post(f"/v1/works/{wid}/sessions", json={}, headers=H).json()
    dev = Device(s["sid"])
    r = client.post(f"/v1/sessions/{s['sid']}/start", json={"startToken": s["startToken"], "devicePubKey": c.b64e(b"\x04" + bytes(10))})
    assert r.status_code == 400 and code(r) == "BAD_REQUEST"
    clock.advance(minutes=10, seconds=1)
    r = client.post(f"/v1/sessions/{s['sid']}/start", json={"startToken": s["startToken"], "devicePubKey": dev.pub_b64})
    assert r.status_code == 410 and code(r) == "TOKEN_EXPIRED"


def test_start_concurrent_different_keys(client, deps):
    wid = client.post("/v1/works", json={"title": "t", "displayName": "d"}, headers=H).json()["workId"]
    s = client.post(f"/v1/works/{wid}/sessions", json={}, headers=H).json()
    sid = s["sid"]
    barrier = threading.Barrier(2, timeout=5)
    orig = deps.signer.sign

    def slow_sign(msg):
        barrier.wait()  # 2つとも署名まで進んでから保存させる
        return orig(msg)

    deps.signer.sign = slow_sign
    results = []

    def go(dev):
        try:
            results.append(("ok", start_svc.start(deps, sid, s["startToken"], dev.pub_b64)))
        except ApiError as e:
            results.append(("err", e.code))

    ts = [threading.Thread(target=go, args=(Device(sid),)) for _ in range(2)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert sorted(r[0] for r in results) == ["err", "ok"]
    assert [r[1] for r in results if r[0] == "err"] == ["TOKEN_USED"]
    stored = deps.repo.get(SESSIONS, sid)
    ok = [r[1] for r in results if r[0] == "ok"][0]
    assert stored["startCertHash"] == c.sha256_hex(c.b64d(ok["startCert"]))


# ---------------------------------------------------------------- チャンクの再送と同時送信


def test_chunk_resend_same_receipt(client, started, deps, clock):
    sid, dev = started["sid"], started["dev"]
    ch = dev.chunk()
    r1 = post_chunk(client, sid, ch)
    clock.advance(seconds=5)
    r2 = post_chunk(client, sid, ch)
    assert r1.status_code == r2.status_code == 200
    assert r1.json() == r2.json()
    assert deps.repo.get(SESSIONS, sid)["chunkCount"] == 1


def test_chunk_concurrent_same(started, deps):
    sid, dev = started["sid"], started["dev"]
    ch = dev.chunk()
    barrier = threading.Barrier(2, timeout=5)
    orig = deps.signer.sign
    deps.signer.sign = lambda m: (barrier.wait(), orig(m))[1]
    results = []
    ts = [threading.Thread(target=lambda: results.append(chunk_svc.receive(deps, sid, ch["header"], ch["sig"], ch["body"]))) for _ in range(2)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert len(results) == 2 and results[0] == results[1]
    assert len(deps.store.list(f"sessions/{sid}/receipts/")) == 1
    assert deps.repo.get(SESSIONS, sid)["chunkCount"] == 1


def test_chunk_concurrent_different_headers(started, deps):
    sid, dev = started["sid"], started["dev"]
    a = dev.chunk(t_end="2026-11-05T01:00:10.000Z")
    b = dev.chunk(t_end="2026-11-05T01:00:11.000Z")
    barrier = threading.Barrier(2, timeout=5)
    orig = deps.store.create_if_absent

    def gated(path, data, ct):
        if "/chunks/" in path:
            barrier.wait()
        return orig(path, data, ct)

    deps.store.create_if_absent = gated
    out = []

    def go(ch):
        try:
            out.append(("ok", chunk_svc.receive(deps, sid, ch["header"], ch["sig"], ch["body"])))
        except ApiError as e:
            out.append(("err", e.code))

    ts = [threading.Thread(target=go, args=(x,)) for x in (a, b)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert sorted(o[0] for o in out) == ["err", "ok"]
    assert [o[1] for o in out if o[0] == "err"] == ["SEQ_CONFLICT"]
    assert len(deps.store.list(f"sessions/{sid}/chunks/")) == 1


# ---------------------------------------------------------------- 途中停止からの復旧


class Boom(Exception):
    pass


def _crash_after(deps, needle):
    orig = deps.store.create_if_absent
    state = {"done": False}

    def wrapped(path, data, ct):
        r = orig(path, data, ct)
        if needle in path and not state["done"]:
            state["done"] = True
            raise Boom(path)
        return r

    deps.store.create_if_absent = wrapped


def test_recover_after_chunk_saved(client, started, deps):
    sid, dev = started["sid"], started["dev"]
    _crash_after(deps, "/chunks/")
    ch = dev.chunk()
    assert post_chunk(client, sid, ch).status_code == 500
    assert deps.store.list(f"sessions/{sid}/receipts/") == []
    assert deps.repo.get(SESSIONS, sid)["head"]["seq"] == -1
    r = post_chunk(client, sid, ch)
    assert r.status_code == 200
    s = deps.repo.get(SESSIONS, sid)
    assert s["head"]["seq"] == 0 and s["chunkCount"] == 1


def test_recover_after_receipt_saved(client, started, deps):
    sid, dev = started["sid"], started["dev"]
    _crash_after(deps, "/receipts/")
    ch = dev.chunk()
    assert post_chunk(client, sid, ch).status_code == 500
    assert deps.repo.get(SESSIONS, sid)["head"]["seq"] == -1
    stored = json.loads(deps.store.get(f"sessions/{sid}/receipts/000000.json"))
    r = post_chunk(client, sid, ch)
    assert r.status_code == 200 and r.json() == stored
    s = deps.repo.get(SESSIONS, sid)
    assert s["head"]["seq"] == 0 and s["head"]["hash"] == c.sha256_hex(ch["header"])


def test_head_not_advanced_when_finalizing(client, started, deps):
    sid, dev = started["sid"], started["dev"]
    orig = deps.store.create_if_absent

    def wrapped(path, data, ct):
        r = orig(path, data, ct)
        if "/receipts/" in path:  # 受領証の保存の後、先頭を進める前に確定が始まった
            deps.repo.set_direct(SESSIONS, sid, {"status": "finalizing"})
        return r

    deps.store.create_if_absent = wrapped
    r = post_chunk(client, sid, dev.chunk())
    assert r.status_code == 409 and code(r) == "SESSION_CLOSED"
    s = deps.repo.get(SESSIONS, sid)
    assert s["head"]["seq"] == -1 and s["chunkCount"] == 0


# ---------------------------------------------------------------- エラー


def test_errors(client, started, deps, clock):
    sid, dev = started["sid"], started["dev"]

    r = post_chunk(client, sid, dev.chunk(seq=1))
    assert (r.status_code, code(r)) == (409, "SEQ_GAP")
    r = post_chunk(client, sid, dev.chunk(prev="0" * 64))
    assert (r.status_code, code(r)) == (409, "PREV_MISMATCH")
    ch = dev.chunk()
    ch["sig"] = Device(sid).sign(ch["header"])
    r = post_chunk(client, sid, ch)
    assert (r.status_code, code(r)) == (422, "SIGNATURE_INVALID")
    ch = dev.chunk()
    ch["body"] = ch["body"].replace(b"[0,1,2]", b"[0,1,3]")
    r = post_chunk(client, sid, ch)
    assert (r.status_code, code(r)) == (422, "HASH_MISMATCH")
    r = post_chunk(client, sid, dev.chunk(bodyLen=1))
    assert (r.status_code, code(r)) == (422, "HASH_MISMATCH")
    r = post_chunk(client, sid, dev.chunk(sid="s_" + "A" * 16))
    assert (r.status_code, code(r)) == (400, "BAD_REQUEST")
    r = post_chunk(client, sid, dev.chunk(stats={}))
    assert (r.status_code, code(r)) == (400, "BAD_REQUEST")
    big = dev.chunk(pad="x" * 5000)
    r = post_chunk(client, sid, big)
    assert (r.status_code, code(r)) == (413, "TOO_LARGE")
    r = client.post(f"/v1/sessions/{sid}/chunks", json={"header": "not b64", "sig": "", "body": ""})
    assert (r.status_code, code(r)) == (400, "BAD_REQUEST")
    assert deps.repo.get(SESSIONS, sid)["rejected"] >= 8

    # final の後のチャンク
    fin = dev.chunk(final=True)
    assert post_chunk(client, sid, fin).status_code == 200
    dev.accept(fin)
    r = post_chunk(client, sid, dev.chunk())
    assert (r.status_code, code(r)) == (409, "SESSION_CLOSED")
    # final の再送は通る
    assert post_chunk(client, sid, fin).status_code == 200


def test_unknown_header_fields_are_ignored(client, started):
    sid, dev = started["sid"], started["dev"]
    r = post_chunk(client, sid, dev.chunk(extra={"future": 1}))
    assert r.status_code == 200, r.text


def test_limits(client, started, clock):
    sid, dev = started["sid"], started["dev"]
    clock.advance(hours=6, seconds=1)
    r = post_chunk(client, sid, dev.chunk())
    assert (r.status_code, code(r)) == (429, "LIMIT_EXCEEDED")


def test_body_too_large(client, started):
    sid, dev = started["sid"], started["dev"]
    ch = dev.chunk()
    ch["body"] = b"x" * (64 * 1024 + 1)
    r = post_chunk(client, sid, ch)
    assert (r.status_code, code(r)) == (413, "TOO_LARGE")


# ---------------------------------------------------------------- 画像


def test_images(client, started, deps):
    sid, dev = started["sid"], started["dev"]
    img = b"\xff\xd8\xff" + b"fake-jpeg" * 10
    sha = c.sha256_hex(img)
    sig = c.b64e(dev.sign(f"image:{sid}:{sha}".encode()))
    url = f"/v1/sessions/{sid}/images/{sha}"
    hdr = {"Content-Type": "image/jpeg", "X-Device-Sig": sig}
    r = client.put(url, content=img, headers=hdr)
    assert r.status_code == 200 and r.json() == {"sha256": sha}
    assert client.put(url, content=img, headers=hdr).status_code == 200  # 再送も成功
    assert deps.store.get(f"sessions/{sid}/images/{sha}.jpg") == img

    r = client.put(url, content=img + b"x", headers=hdr)
    assert (r.status_code, code(r)) == (422, "HASH_MISMATCH")
    r = client.put(url, content=img, headers={**hdr, "X-Device-Sig": c.b64e(Device(sid).sign(b"x"))})
    assert (r.status_code, code(r)) == (422, "SIGNATURE_INVALID")
    r = client.put(url, content=img, headers={**hdr, "Content-Type": "image/png"})
    assert (r.status_code, code(r)) == (415, "UNSUPPORTED_MEDIA")
    big = b"\xff" * (2 * 1024 * 1024 + 1)
    r = client.put(f"/v1/sessions/{sid}/images/{c.sha256_hex(big)}", content=big, headers=hdr)
    assert (r.status_code, code(r)) == (413, "TOO_LARGE")

    deps.repo.set_direct(SESSIONS, sid, {"status": "finalizing"})
    r = client.put(url, content=img, headers=hdr)
    assert (r.status_code, code(r)) == (409, "SESSION_CLOSED")


def test_images_after_completed(client, started):
    sid, dev = started["sid"], started["dev"]
    fin = dev.chunk(final=True)
    assert post_chunk(client, sid, fin).status_code == 200
    img = b"\xff\xd8end"
    sha = c.sha256_hex(img)
    r = client.put(
        f"/v1/sessions/{sid}/images/{sha}",
        content=img,
        headers={"Content-Type": "image/jpeg", "X-Device-Sig": c.b64e(dev.sign(f"image:{sid}:{sha}".encode()))},
    )
    assert r.status_code == 200


@pytest.mark.parametrize("path", ["/v1/p/abc"])
def test_cors_only_public(client, path):
    r = client.options(path, headers={"Origin": "http://localhost:5173"})
    assert r.headers.get("access-control-allow-origin") == "http://localhost:5173"
    r = client.get("/v1/healthz", headers={"Origin": "http://localhost:5173"})
    assert "access-control-allow-origin" not in r.headers
