"""T08 の完了条件（PNG・確定・証拠一式・削除・補足説明）。"""

from __future__ import annotations

import json
import sys
import threading
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

from app.core import canonical as c
from app.core.crypto import verify_device_sig, verify_kms_sig
from app.repo.base import REVIEW_VERSION, SESSIONS, WORKS
from app.services import finalize as fin

from conftest import H, VECTORS, as_json

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "fixtures"))
import generate as g  # noqa: E402

PEM = VECTORS["kmsKey"]["publicPem"]
LINES = g.strokes(seed=7, n=26)
CANVAS = g.canvas(LINES)
PNG_A = g.png(CANVAS)
PNG_B = g.png(g.canvas(LINES + g.strokes(seed=11, n=3)))
START_JPG = g.jpeg(g.screen(g.canvas([])))
END_JPG = g.jpeg(g.screen(CANVAS))


def schema(name):
    return Draft202012Validator(json.loads((ROOT / f"shared/schemas/{name}.schema.json").read_text(encoding="utf-8")))


def code(r):
    return r.json()["error"]["code"]


def put_image(client, dev, data):
    sha = c.sha256_hex(data)
    r = client.put(
        f"/v1/sessions/{dev.sid}/images/{sha}",
        content=data,
        headers={"Content-Type": "image/jpeg", "X-Device-Sig": c.b64e(dev.sign(f"image:{dev.sid}:{sha}".encode()))},
    )
    assert r.status_code == 200, r.text
    return sha


def send(client, dev, ch):
    r = client.post(f"/v1/sessions/{dev.sid}/chunks", json=as_json(ch))
    assert r.status_code == 200, r.text
    dev.accept(ch)
    return r


def record(client, started, n=3, final=True, clock=None, gap_after=None):
    dev = started["dev"]
    s_sha = put_image(client, dev, START_JPG)
    e_sha = put_image(client, dev, END_JPG) if final else None
    for i in range(n):
        if clock is not None:
            clock.advance(seconds=45 if gap_after is not None and i == gap_after + 1 else 5)
        images = {"start": s_sha} if i == 0 else None
        is_final = final and i == n - 1
        if is_final:
            images = {"end": e_sha}
        send(client, dev, dev.chunk(final=is_final, images=images))


def put_png(client, wid, data):
    return client.put(f"/v1/works/{wid}/png", content=data, headers={**H, "Content-Type": "image/png"})


def do_finalize(client, wid, **kw):
    return client.post(f"/v1/works/{wid}/finalize", json={"declarationAccepted": True, **kw}, headers=H)


# ---------------------------------------------------------------- 正常系


def test_finalize_happy_path(client, started, deps):
    wid = started["wid"]
    record(client, started)
    assert put_png(client, wid, PNG_A).status_code == 200
    r = do_finalize(client, wid)
    assert r.status_code == 200, r.text
    out = r.json()
    pid, m = out["publicId"], out["manifest"]
    assert out["explanation"] is None  # explainer が無い

    pub = client.get(f"/v1/p/{pid}")
    assert pub.status_code == 200 and pub.headers["cache-control"] == "no-store"
    b = pub.json()
    assert not list(schema("bundle").iter_errors(b))
    mb = c.b64d(b["manifest"]["bytes"])
    assert json.loads(mb) == m
    assert not list(schema("manifest").iter_errors(m))
    assert verify_kms_sig(PEM, c.b64d(b["manifest"]["sig"]), mb)
    # 【T14】v:2。記録が1回なら sessions は1つ
    assert m["v"] == 2 and b["v"] == 2 and len(m["sessions"]) == 1 and len(b["sessions"]) == 1
    bs, ms = b["sessions"][0], m["sessions"][0]
    assert ms["sid"] == started["sid"]
    assert verify_kms_sig(PEM, c.b64d(bs["start"]["sig"]), c.b64d(bs["start"]["bytes"]))
    seqs = [json.loads(c.b64d(ch["header"]))["seq"] for ch in bs["chunks"]]
    assert seqs == [0, 1, 2]
    heads = [c.sha256_hex(c.b64d(ch["header"])) for ch in bs["chunks"]]
    assert ms["chunks"] == {"count": 3, "first": heads[0], "last": heads[-1]}
    dev_pub = json.loads(c.b64d(bs["start"]["bytes"]))["devicePubKey"]
    for ch in bs["chunks"]:
        assert verify_device_sig(dev_pub, ch["sig"], c.b64d(ch["header"]))
        assert verify_kms_sig(PEM, c.b64d(ch["receiptSig"]), c.b64d(ch["receipt"]))
    assert ms["status"] == "completed" and m["rules"] == "2026-11-08.1"
    assert m["images"] == {"start": c.sha256_hex(START_JPG), "end": c.sha256_hex(END_JPG)}
    assert m["png"] == {"sha256": c.sha256_hex(PNG_A), "width": 1600, "height": 1200}
    assert m["match"]["result"] == "match"
    assert b["files"] == {"start": "start.jpg", "end": "end.jpg", "png": "png.jpg", "whole": None}
    assert b["kms"]["keyVersion"] == "test/1"

    # 画像の配布
    assert client.get(f"/v1/p/{pid}/files/start.jpg").content == START_JPG
    assert client.get(f"/v1/p/{pid}/files/end.jpg").content == END_JPG
    thumb = client.get(f"/v1/p/{pid}/files/png.jpg")
    assert thumb.status_code == 200 and thumb.headers["content-type"] == "image/jpeg"
    assert client.get(f"/v1/p/{pid}/files/other.jpg").status_code == 404

    w = client.get(f"/v1/works/{wid}", headers=H).json()
    assert w["status"] == "finalized" and w["publicId"] == pid and w["match"]["result"] == "match"
    assert deps.repo.get(SESSIONS, started["sid"])["status"] == "finalized"

    # 再送には保存済みの結果
    again = do_finalize(client, wid)
    assert again.status_code == 200 and again.json() == out


def test_declaration_required_and_not_started(client, deps):
    wid = client.post("/v1/works", json={"title": "t", "displayName": "d"}, headers=H).json()["workId"]
    r = client.post(f"/v1/works/{wid}/finalize", json={"declarationAccepted": False}, headers=H)
    assert (r.status_code, code(r)) == (400, "DECLARATION_REQUIRED")
    r = do_finalize(client, wid)
    assert (r.status_code, code(r)) == (404, "NOT_FOUND")
    client.post(f"/v1/works/{wid}/sessions", json={}, headers=H)
    r = do_finalize(client, wid)
    assert (r.status_code, code(r)) == (404, "NOT_FOUND")
    r = client.post(f"/v1/works/{wid}/finalize", json={"declarationAccepted": True}, headers={"X-Dev-Uid": "someone"})
    assert r.status_code == 403


# ---------------------------------------------------------------- 異常終了


def test_aborted_after_60_seconds(client, started, clock):
    wid = started["wid"]
    record(client, started, n=2, final=False)
    clock.advance(seconds=59)
    r = do_finalize(client, wid)
    assert (r.status_code, code(r)) == (409, "STILL_RECORDING")
    assert r.json()["error"]["retryAfterSec"] == 1
    clock.advance(seconds=1)
    r = do_finalize(client, wid)
    assert r.status_code == 200, r.text
    m = r.json()["manifest"]["sessions"][0]
    assert m["status"] == "aborted" and m["chunks"]["count"] == 2
    m = r.json()["manifest"]
    assert m["images"]["end"] is None and m["match"]["result"] == "unverified"


def test_aborted_with_no_chunks_counts_from_start(client, started, clock):
    clock.advance(seconds=30)
    r = do_finalize(client, started["wid"])
    assert code(r) == "STILL_RECORDING" and r.json()["error"]["retryAfterSec"] == 30
    clock.advance(seconds=30)
    r = do_finalize(client, started["wid"])
    assert r.status_code == 200, r.text
    m = r.json()["manifest"]
    ms = m["sessions"][0]
    assert ms["status"] == "aborted"
    assert ms["chunks"] == {"count": 0, "first": None, "last": None}
    assert ms["received"] == {"first": None, "last": None, "gaps": []}
    assert not list(schema("manifest").iter_errors(m))


# ---------------------------------------------------------------- 途中停止からの再開


class Boom(Exception):
    pass


def _crash_once_after(deps, needle):
    orig = deps.store.create_if_absent
    state = {"done": False}

    def wrapped(path, data, ct):
        r = orig(path, data, ct)
        if needle in path and not state["done"]:
            state["done"] = True
            raise Boom(path)
        return r

    deps.store.create_if_absent = wrapped


@pytest.mark.parametrize("where", ["sign", "bundle", "explanation"])
def test_resume_after_crash(client, started, deps, where):
    wid = started["wid"]
    record(client, started)
    put_png(client, wid, PNG_A)
    deps.explainer = lambda m: {"text": "説明", "model": "fake"}
    if where == "sign":
        orig = deps.signer.sign
        state = {"n": 0}

        def flaky(msg):
            state["n"] += 1
            if state["n"] == 1:
                raise Boom("sign")
            return orig(msg)

        deps.signer.sign = flaky
    else:
        _crash_once_after(deps, f"/{where}.json")
    r1 = do_finalize(client, wid)
    assert r1.status_code == 500
    assert deps.repo.get(WORKS, wid)["status"] == "finalizing"
    pid = deps.repo.get(WORKS, wid)["finalize"]["publicId"]
    assert client.get(f"/v1/p/{pid}").status_code == 404  # まだ公開していない
    r2 = do_finalize(client, wid)
    assert r2.status_code == 200, r2.text
    assert r2.json()["publicId"] == pid
    assert len([n for n in deps.store.list(f"works/{wid}/") if n.endswith("bundle.json")]) == 1
    assert client.get(f"/v1/p/{pid}").status_code == 200


def test_concurrent_finalize(started, client, deps):
    wid = started["wid"]
    record(client, started)
    put_png(client, wid, PNG_A)
    barrier = threading.Barrier(2, timeout=10)
    orig = deps.store.create_if_absent

    def gated(path, data, ct):
        if path.endswith("bundle.json"):
            barrier.wait()
        return orig(path, data, ct)

    deps.store.create_if_absent = gated
    out = []
    ts = [threading.Thread(target=lambda: out.append(fin.finalize(deps, "user-a", wid, True))) for _ in range(2)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert len(out) == 2
    assert out[0]["publicId"] == out[1]["publicId"]
    assert out[0]["manifest"] == out[1]["manifest"]
    assert [n for n in deps.store.list(f"works/{wid}/") if n.endswith("bundle.json")] == [f"works/{wid}/bundle.json"]


# ---------------------------------------------------------------- 範囲と PNG の固定


def _stop_after_fix(deps):
    """段階A の後、段階B の最初で1回止める。"""
    orig = fin.build
    state = {"done": False}

    def flaky(*a, **kw):
        if not state["done"]:
            state["done"] = True
            raise Boom("after A")
        return orig(*a, **kw)

    return flaky


def test_range_is_fixed(client, started, deps, clock, monkeypatch):
    wid, dev = started["wid"], started["dev"]
    record(client, started, n=2, final=False)
    clock.advance(seconds=61)
    monkeypatch.setattr(fin, "build", _stop_after_fix(deps))
    assert do_finalize(client, wid).status_code == 500  # 段階A だけ済んだ
    r = client.post(f"/v1/sessions/{dev.sid}/chunks", json=as_json(dev.chunk(final=True)))
    assert (r.status_code, code(r)) == (409, "SESSION_CLOSED")
    assert put_png(client, wid, PNG_B).json()["error"]["code"] == "ALREADY_FINALIZED"
    r = do_finalize(client, wid)
    assert r.status_code == 200
    assert r.json()["manifest"]["sessions"][0]["chunks"]["count"] == 2
    assert deps.repo.get(SESSIONS, dev.sid)["head"]["seq"] == 1


def test_png_before_fix_is_used_everywhere(client, started, deps):
    wid = started["wid"]
    record(client, started)
    assert put_png(client, wid, PNG_A).status_code == 200
    assert put_png(client, wid, PNG_B).status_code == 200  # 差し替え
    r = do_finalize(client, wid).json()
    sha_b = c.sha256_hex(PNG_B)
    assert r["manifest"]["png"]["sha256"] == sha_b
    thumb = client.get(f"/v1/p/{r['publicId']}/files/png.jpg").content
    assert thumb == deps.store.get(f"works/{wid}/png/{sha_b}.thumb.jpg")
    # 古い PNG は消していない
    assert deps.store.exists(f"works/{wid}/png/{c.sha256_hex(PNG_A)}.png")


def test_closed_after_finalize(client, started):
    wid, dev = started["wid"], started["dev"]
    record(client, started, n=2, final=True)
    assert do_finalize(client, wid).status_code == 200
    r = client.post(f"/v1/sessions/{dev.sid}/chunks", json=as_json(dev.chunk()))
    assert code(r) == "SESSION_CLOSED"
    img = b"\xff\xd8late"
    sha = c.sha256_hex(img)
    r = client.put(
        f"/v1/sessions/{dev.sid}/images/{sha}",
        content=img,
        headers={"Content-Type": "image/jpeg", "X-Device-Sig": c.b64e(dev.sign(f"image:{dev.sid}:{sha}".encode()))},
    )
    assert code(r) == "SESSION_CLOSED"
    assert code(put_png(client, wid, PNG_A)) == "ALREADY_FINALIZED"
    assert code(client.post(f"/v1/works/{wid}/sessions", json={}, headers=H)) == "ALREADY_FINALIZED"


def test_gaps(client, started, clock):
    record(client, started, n=3, clock=clock, gap_after=0)
    m = do_finalize(client, started["wid"]).json()["manifest"]
    assert m["sessions"][0]["received"]["gaps"] == [{"after": 0, "sec": 45.0}]


def test_use_end_image_false(client, started):
    record(client, started)
    put_png(client, started["wid"], PNG_A)
    m = do_finalize(client, started["wid"], useEndImage=False).json()["manifest"]
    assert m["match"] == {"result": "unverified", "score": None, "reason": "作者が終了画面を照合に使わないことを選んだ"}


# ---------------------------------------------------------------- PNG の誤り


def test_png_errors(client, started):
    wid = started["wid"]
    r = client.put(f"/v1/works/{wid}/png", content=b"not png", headers={**H, "Content-Type": "image/png"})
    assert (r.status_code, code(r)) == (415, "UNSUPPORTED_MEDIA")
    r = client.put(f"/v1/works/{wid}/png", content=END_JPG, headers={**H, "Content-Type": "image/png"})
    assert (r.status_code, code(r)) == (415, "UNSUPPORTED_MEDIA")
    r = client.put(f"/v1/works/{wid}/png", content=b"\x00" * (30 * 1024 * 1024 + 1), headers={**H, "Content-Type": "image/png"})
    assert (r.status_code, code(r)) == (413, "TOO_LARGE")
    r = client.put(f"/v1/works/{wid}/png", content=PNG_A, headers={"X-Dev-Uid": "other", "Content-Type": "image/png"})
    assert r.status_code == 403
    ok = put_png(client, wid, PNG_A).json()
    assert ok == {"sha256": c.sha256_hex(PNG_A), "width": 1600, "height": 1200}


# ---------------------------------------------------------------- 補足説明


def test_explanation_failure_does_not_block(client, started, deps):
    record(client, started)

    def boom(_):
        raise RuntimeError("gemini down")

    deps.explainer = boom
    r = do_finalize(client, started["wid"])
    assert r.status_code == 200 and r.json()["explanation"] is None
    assert client.get(f"/v1/p/{r.json()['publicId']}").json()["explanation"] is None


def test_explanation_toggle_keeps_bundle(client, started, deps):
    wid = started["wid"]
    record(client, started)
    seen = []
    deps.explainer = lambda m: (seen.append(m), {"text": "確認済みのことと未確認のこと", "model": "fake-model"})[1]
    r = do_finalize(client, wid).json()
    assert r["explanation"] == {"text": "確認済みのことと未確認のこと", "included": True}
    assert seen == [[]]  # 公開できる途中画像の組だけを渡す。作者の申告は渡さない
    pid = r["publicId"]
    before = deps.store.get(f"works/{wid}/bundle.json")
    assert client.get(f"/v1/p/{pid}").json()["explanation"] == {"text": "確認済みのことと未確認のこと", "model": "fake-model"}
    assert client.put(f"/v1/works/{wid}/explanation", json={"include": False}, headers=H).json() == {"included": False}
    assert client.get(f"/v1/p/{pid}").json()["explanation"] is None
    assert client.put(f"/v1/works/{wid}/explanation", json={"include": True}, headers=H).json() == {"included": True}
    assert client.get(f"/v1/p/{pid}").json()["explanation"]["text"]
    assert deps.store.get(f"works/{wid}/bundle.json") == before
    assert json.loads(before)["explanation"] is None


@pytest.mark.parametrize("note_text", ["新しい注意点", ""])
def test_refresh_older_review_preserves_opt_out_and_bundle(client, started, deps, note_text):
    wid = started["wid"]
    record(client, started)
    pid = do_finalize(client, wid).json()["publicId"]
    original = deps.store.get(fin.bundle_path(wid))
    previous = {"text": "以前の注意点", "model": "fake-model", "included": False}
    deps.repo.run_txn(lambda txn: txn.update(WORKS, wid, {
        "reviewVersion": REVIEW_VERSION - 1,
        "explanation": previous,
    }))

    assert client.get(f"/v1/works/{wid}", headers=H).json()["explanation"] is None
    note = {"text": note_text, "model": "fake-model"}
    assert deps.repo.replace_explanation(wid, pid, note)
    assert deps.repo.get(WORKS, wid)["reviewVersion"] == REVIEW_VERSION
    assert deps.repo.get(WORKS, wid)["explanation"] == {**note, "included": False}
    assert deps.repo.replace_explanation(wid, pid, {**note, "text": "再実行"})
    assert client.get(f"/v1/p/{pid}").json()["explanation"] is None
    if note_text:
        assert client.put(f"/v1/works/{wid}/explanation", json={"include": True}, headers=H).json() == {"included": True}
        assert client.get(f"/v1/p/{pid}").json()["explanation"] == note
    assert deps.store.get(fin.bundle_path(wid)) == original


def test_explanation_only_when_finalized(client, started):
    r = client.put(f"/v1/works/{started['wid']}/explanation", json={"include": True}, headers=H)
    assert r.status_code == 400


# ---------------------------------------------------------------- 削除


def test_delete(client, started, deps):
    wid, sid = started["wid"], started["sid"]
    record(client, started)
    put_png(client, wid, PNG_A)
    pid = do_finalize(client, wid).json()["publicId"]
    assert client.get(f"/v1/p/{pid}").status_code == 200
    r = client.delete(f"/v1/works/{wid}", headers=H)
    assert r.status_code == 204
    assert client.get(f"/v1/p/{pid}").status_code == 404
    assert client.get(f"/v1/p/{pid}/files/end.jpg").status_code == 404
    assert client.get(f"/v1/works/{wid}", headers=H).status_code == 404
    assert deps.store.list(f"works/{wid}/") == [] and deps.store.list(f"sessions/{sid}/") == []
    assert client.delete(f"/v1/works/{wid}", headers={"X-Dev-Uid": "other"}).status_code == 404


def test_delete_only_owner(client, started):
    assert client.delete(f"/v1/works/{started['wid']}", headers={"X-Dev-Uid": "other"}).status_code == 403


def test_public_unknown(client):
    assert client.get("/v1/p/doesnotexist0000000000").status_code == 404
