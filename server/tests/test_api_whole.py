"""T13 の受付API（全体画像つきの確定・載せない設定・画像の枚数の上限）。"""

from __future__ import annotations

import json
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import SimpleNamespace

import cv2
import numpy as np
import pytest
from google import genai

from app.core import canonical as c
from app.core.crypto import verify_kms_sig
from app.repo.base import SESSIONS
from app.services.gemini import GeminiExplainer

from conftest import H, VECTORS, as_json

VEC = Path(__file__).resolve().parents[2] / "shared/vectors/whole_canvas"
PEM = VECTORS["kmsKey"]["publicPem"]


def jpeg(name: str) -> bytes:
    g = cv2.imdecode(np.frombuffer((VEC / f"{name}.png").read_bytes(), np.uint8), cv2.IMREAD_GRAYSCALE)
    return cv2.imencode(".jpg", g, [cv2.IMWRITE_JPEG_QUALITY, 70])[1].tobytes()


def put_image(client, dev, data):
    sha = c.sha256_hex(data)
    return client.put(
        f"/v1/sessions/{dev.sid}/images/{sha}",
        content=data,
        headers={"Content-Type": "image/jpeg", "X-Device-Sig": c.b64e(dev.sign(f"image:{dev.sid}:{sha}".encode()))},
    ), sha


def record_with_whole(client, started, names, upload_missing=None, clock=None, interval=5, between_chunks=0):
    """全体画像付きのチャンクを順に送り、最後を final にする。"""
    dev = started["dev"]

    def send(ch):
        r = client.post(f"/v1/sessions/{dev.sid}/chunks", json=as_json(ch))
        assert r.status_code == 200, r.text
        dev.accept(ch)

    for i, name in enumerate(names):
        if i and clock is not None:
            for _ in range(between_chunks):
                clock.advance(seconds=interval)
                send(dev.chunk())
            clock.advance(seconds=interval)
        data = jpeg(name)
        sha = c.sha256_hex(data)
        if i != upload_missing:
            assert put_image(client, dev, data)[0].status_code == 200
        send(dev.chunk(final=(i == len(names) - 1), images={"whole": sha}))


def png_final() -> bytes:
    return (VEC / "png_final.png").read_bytes()


def finalize(client, wid, **kw):
    r = client.post(f"/v1/works/{wid}/finalize", json={"declarationAccepted": True, **kw}, headers=H)
    assert r.status_code == 200, r.text
    return r.json()


STEPS = [f"step{i}" for i in range(6)]


def test_finalize_with_whole(client, started):
    wid = started["wid"]
    record_with_whole(client, started, STEPS)
    assert client.put(f"/v1/works/{wid}/png", content=png_final(), headers={**H, "Content-Type": "image/png"}).status_code == 200
    out = finalize(client, wid)
    m = out["manifest"]
    assert m["rules"] == "2026-11-08.1"
    w = m["whole"]
    assert w["shown"] is True and [it["seq"] for it in w["items"]] == list(range(6))
    assert all(l["result"] == "linked" for l in w["links"]), w["links"]
    assert w["toPng"]["result"] == "linked"
    b = client.get(f"/v1/p/{out['publicId']}").json()
    assert verify_kms_sig(PEM, c.b64d(b["manifest"]["sig"]), c.b64d(b["manifest"]["bytes"]))
    assert b["files"]["whole"] == [f"whole-{i}.jpg" for i in range(6)]
    got = client.get(f"/v1/p/{out['publicId']}/files/whole-2.jpg")
    assert got.status_code == 200 and c.sha256_hex(got.content) == w["items"][2]["sha256"]
    assert client.get(f"/v1/p/{out['publicId']}/files/whole-6.jpg").status_code == 404
    assert client.get(f"/v1/p/{out['publicId']}/files/whole-01.jpg").status_code == 404


def test_show_whole_false(client, started):
    wid = started["wid"]
    record_with_whole(client, started, STEPS[:3])
    out = finalize(client, wid, showWhole=False)
    assert out["manifest"]["whole"]["shown"] is False
    pid = out["publicId"]
    assert client.get(f"/v1/p/{pid}").json()["files"]["whole"] is None
    assert client.get(f"/v1/p/{pid}/files/whole-0.jpg").status_code == 404


@pytest.mark.parametrize("shown,interval,between_chunks,expected_gap", [
    (True, 5, 0, 0), (False, 5, 0, 0), (True, 31, 0, 31), (True, 5, 24, 0),
])
def test_review_pairs_include_long_intervals_and_receipt_gaps(client, started, deps, clock, shown, interval, between_chunks, expected_gap):
    seen = []

    def explain(pairs):
        seen.extend(pairs)
        return {"text": "", "model": "fake-model"}

    deps.explainer = explain
    record_with_whole(client, started, ["step2", "other"], clock=clock, interval=interval, between_chunks=between_chunks)
    out = finalize(client, started["wid"], showWhole=shown)
    assert out["manifest"]["whole"]["links"][0]["result"] == "unconfirmed"
    assert len(seen) == int(shown)
    if seen:
        pair = seen[0]
        assert (pair.end - pair.start).total_seconds() == interval * (between_chunks + 1)
        assert pair.max_gap_sec == expected_gap
        assert pair.before.startswith(b"\xff\xd8") and pair.after.startswith(b"\xff\xd8")
        assert pair.before != jpeg("step2") and pair.after != jpeg("other")
    assert client.get(f"/v1/p/{out['publicId']}").json()["explanation"] == {"text": "", "model": "fake-model"}


def test_review_note_keeps_full_text_and_snapshot_pair(client, started, deps, clock, monkeypatch):
    change = "前の画像にある人物と背景の輪郭が消え、後の画像には異なる構図で描き込まれた人物が見えます。" * 3
    review = "人物の位置と背景が変わった区間を見返してください。"
    response = SimpleNamespace(text=json.dumps({"observations": [{"change": change, "review": review}]}))
    model = SimpleNamespace(generate_content=lambda **_: response)
    monkeypatch.setattr(genai, "Client", lambda **_: SimpleNamespace(models=model))
    deps.explainer = GeminiExplainer("test", "global", "fake-model")

    wid = started["wid"]
    record_with_whole(client, started, ["step2", "other"], clock=clock)
    out = finalize(client, wid)
    note = client.get(f"/v1/p/{out['publicId']}").json()["explanation"]
    assert note["text"].split("\n", 1)[1] == f"{change} {review}"
    assert note["links"] == [{"from": 0, "to": 1}]


def test_missing_and_switched(client, started):
    wid = started["wid"]
    record_with_whole(client, started, ["step0", "step1", "other", "step3"], upload_missing=1)
    w = finalize(client, wid)["manifest"]["whole"]
    assert [it["received"] for it in w["items"]] == [True, False, True, True]
    assert [l["reason"] for l in w["links"][:2]] == ["画像が届いていない", "画像が届いていない"]
    assert w["links"][2]["result"] == "unconfirmed"  # 別の絵 → step3
    assert w["toPng"] is None  # PNG なし
    b = client.get(f"/v1/p/{finalize(client, wid)['publicId']}").json()
    assert b["files"]["whole"] == ["whole-0.jpg", None, "whole-2.jpg", "whole-3.jpg"]


def test_no_whole_is_null(client, started):
    dev = started["dev"]
    ch = dev.chunk(final=True)
    client.post(f"/v1/sessions/{dev.sid}/chunks", json=as_json(ch))
    out = finalize(client, started["wid"])
    assert out["manifest"]["whole"] is None
    assert client.get(f"/v1/p/{out['publicId']}").json()["files"]["whole"] is None


def test_image_limit(client, started, deps):
    dev = started["dev"]
    deps.repo.set_direct(SESSIONS, dev.sid, {"imageCount": 149})
    r, sha = put_image(client, dev, b"\xff\xd8 image 150")
    assert r.status_code == 200
    assert deps.repo.get(SESSIONS, dev.sid)["imageCount"] == 150
    r, _ = put_image(client, dev, b"\xff\xd8 image 151")
    assert (r.status_code, r.json()["error"]["code"]) == (429, "LIMIT_EXCEEDED")
    r, _ = put_image(client, dev, b"\xff\xd8 image 150")  # 同じ画像の再送は成功
    assert r.status_code == 200
    assert deps.repo.get(SESSIONS, dev.sid)["imageCount"] == 150


def test_image_count_counts_new_only(client, started, deps):
    dev = started["dev"]
    put_image(client, dev, b"\xff\xd8 a")
    put_image(client, dev, b"\xff\xd8 a")
    put_image(client, dev, b"\xff\xd8 b")
    assert deps.repo.get(SESSIONS, dev.sid)["imageCount"] == 2
    assert json.loads(json.dumps(deps.repo.get(SESSIONS, dev.sid)))["imageCount"] == 2


@pytest.mark.parametrize("same_image", [False, True])
def test_image_limit_with_concurrent_requests(client, started, deps, monkeypatch, same_image):
    dev = started["dev"]
    deps.repo.set_direct(SESSIONS, dev.sid, {"imageCount": 149})
    exists = deps.store.exists
    barrier = threading.Barrier(2)

    def simultaneous_exists(path):
        found = exists(path)
        if path.startswith(f"sessions/{dev.sid}/images/"):
            barrier.wait(timeout=10)
        return found

    # 両方とも「まだ保存されていない」と確認した後で受付を進める。
    monkeypatch.setattr(deps.store, "exists", simultaneous_exists)
    first = b"\xff\xd8 concurrent a"
    second = first if same_image else b"\xff\xd8 concurrent b"
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(lambda data: put_image(client, dev, data)[0], [first, second]))
    assert sorted(r.status_code for r in responses) == ([200, 200] if same_image else [200, 429])
    assert deps.repo.get(SESSIONS, dev.sid)["imageCount"] == 150
    assert len(deps.store.list(f"sessions/{dev.sid}/images/")) == 1


@pytest.mark.parametrize("saved_before_failure", [False, True])
def test_image_upload_retry_after_storage_failure(client, started, deps, monkeypatch, saved_before_failure):
    dev = started["dev"]
    deps.repo.set_direct(SESSIONS, dev.sid, {"imageCount": 149})
    create = deps.store.create_if_absent

    def fail_save(path, data, content_type):
        if saved_before_failure:
            create(path, data, content_type)
        raise RuntimeError("image storage interrupted")

    monkeypatch.setattr(deps.store, "create_if_absent", fail_save)
    data = b"\xff\xd8 interrupted image"
    assert put_image(client, dev, data)[0].status_code == 500
    monkeypatch.setattr(deps.store, "create_if_absent", create)

    # 保存の前後どちらで失敗しても、同じ画像の再送は上限で拒否されない。
    assert put_image(client, dev, data)[0].status_code == 200
    assert deps.repo.get(SESSIONS, dev.sid)["imageCount"] == 150
    assert len(deps.store.list(f"sessions/{dev.sid}/images/")) == 1
    assert put_image(client, dev, b"\xff\xd8 another image")[0].status_code == 429
