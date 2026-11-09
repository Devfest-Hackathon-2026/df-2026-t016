"""T14 の受付API（1つの作品に複数の記録）。"""

from __future__ import annotations

import json
from pathlib import Path

from jsonschema import Draft202012Validator

from app.core import canonical as c
from app.core.crypto import verify_device_sig, verify_kms_sig
from app.repo.base import MAX_SESSIONS_PER_WORK, SESSIONS, WORKS

from conftest import H, VECTORS, Device, as_json
from test_api_whole import jpeg, png_final, put_image

ROOT = Path(__file__).resolve().parents[2]
PEM = VECTORS["kmsKey"]["publicPem"]


def schema(name):
    return Draft202012Validator(json.loads((ROOT / f"shared/schemas/{name}.schema.json").read_text(encoding="utf-8")))


def code(r):
    return r.json()["error"]["code"]


def new_work(client) -> str:
    r = client.post("/v1/works", json={"title": "何日かに分けて", "displayName": "描き手"}, headers=H)
    assert r.status_code == 201, r.text
    return r.json()["workId"]


def new_record(client, wid) -> Device:
    """記録を作って開始する。"""
    r = client.post(f"/v1/works/{wid}/sessions", json={}, headers=H)
    assert r.status_code == 201, r.text
    s = r.json()
    dev = Device(s["sid"])
    r = client.post(f"/v1/sessions/{dev.sid}/start", json={"startToken": s["startToken"], "devicePubKey": dev.pub_b64})
    assert r.status_code == 200, r.text
    dev.set_start(r.json()["startCert"])
    return dev


def send_whole(client, dev, names, final=True, start=False, clock=None):
    """チャンクごとに1枚ずつ全体画像を入れる。start なら最初を開始画面、final なら最後を終了画面にもする。"""
    for i, name in enumerate(names):
        if clock is not None:
            clock.advance(seconds=5)
        data = jpeg(name)
        r, sha = put_image(client, dev, data)
        assert r.status_code == 200, r.text
        images = {"whole": sha}
        if start and i == 0:
            images["start"] = sha
        is_final = final and i == len(names) - 1
        if is_final:
            images["end"] = sha
        ch = dev.chunk(final=is_final, images=images)
        r = client.post(f"/v1/sessions/{dev.sid}/chunks", json=as_json(ch))
        assert r.status_code == 200, r.text
        dev.accept(ch)


def work(client, wid) -> dict:
    return client.get(f"/v1/works/{wid}", headers=H).json()


def finalize(client, wid, **kw):
    return client.post(f"/v1/works/{wid}/finalize", json={"declarationAccepted": True, **kw}, headers=H)


# ---------------------------------------------------------------- 記録を足す


def test_stop_saves_only_that_record_and_add_next(client, clock):
    wid = new_work(client)
    d1 = new_record(client, wid)
    assert work(client, wid)["status"] == "recording"
    send_whole(client, d1, ["step0", "step1", "step2"], start=True, clock=clock)
    w = work(client, wid)
    # 停止（最終チャンク）では、その記録だけが終わる。作品は提出されない
    assert w["status"] == "recorded" and w["publicId"] is None
    assert [s["status"] for s in w["sessions"]] == ["completed"] and w["session"]["sid"] == d1.sid

    clock.advance(hours=20)  # 次の日に続きを描く
    d2 = new_record(client, wid)
    w = work(client, wid)
    assert w["status"] == "recording"
    assert [s["sid"] for s in w["sessions"]] == [d1.sid, d2.sid] and w["session"]["sid"] == d2.sid
    send_whole(client, d2, ["step3", "step4", "step5"], clock=clock)
    w = work(client, wid)
    assert w["status"] == "recorded"
    assert [(s["status"], s["chunkCount"], s["final"]) for s in w["sessions"]] == [("completed", 3, True), ("completed", 3, True)]
    # 一覧にも記録が並ぶ
    listed = client.get("/v1/works", headers=H).json()["works"][0]
    assert [s["sid"] for s in listed["sessions"]] == [d1.sid, d2.sid]


def test_unstarted_record_is_replaced(client, deps):
    wid = new_work(client)
    d1 = new_record(client, wid)
    send_whole(client, d1, ["step0"])
    a = client.post(f"/v1/works/{wid}/sessions", json={}, headers=H).json()
    b = client.post(f"/v1/works/{wid}/sessions", json={}, headers=H).json()
    assert deps.repo.get(SESSIONS, a["sid"]) is None  # 未開始のものは置き換える
    w = work(client, wid)
    assert [s["sid"] for s in w["sessions"]] == [d1.sid, b["sid"]]
    assert w["sessions"][1]["status"] == "created" and w["status"] == "recorded"


def test_cannot_add_while_recording(client, clock):
    wid = new_work(client)
    d1 = new_record(client, wid)
    send_whole(client, d1, ["step0"], final=False)
    clock.advance(seconds=20)
    r = client.post(f"/v1/works/{wid}/sessions", json={}, headers=H)
    assert (r.status_code, code(r)) == (409, "SESSION_EXISTS")
    assert r.json()["error"]["retryAfterSec"] == 40
    # 60秒たてば止まったとみなし、次の記録を作れる。古い記録は閉じない（確定の前なら残りを送れる）
    clock.advance(seconds=40)
    d2 = new_record(client, wid)
    assert work(client, wid)["status"] == "recording"
    ch = d1.chunk(final=True)
    assert client.post(f"/v1/sessions/{d1.sid}/chunks", json=as_json(ch)).status_code == 200
    d1.accept(ch)
    # 古い記録の最終チャンクでは、作品の状態は変えない（いちばん新しい記録はまだ録画中）
    w = work(client, wid)
    assert w["status"] == "recording" and [s["status"] for s in w["sessions"]] == ["completed", "recording"]
    assert w["session"]["sid"] == d2.sid


def test_record_limit(client, deps):
    wid = new_work(client)
    for _ in range(MAX_SESSIONS_PER_WORK):
        d = new_record(client, wid)
        ch = d.chunk(final=True)
        assert client.post(f"/v1/sessions/{d.sid}/chunks", json=as_json(ch)).status_code == 200
    r = client.post(f"/v1/works/{wid}/sessions", json={}, headers=H)
    assert (r.status_code, code(r)) == (429, "LIMIT_EXCEEDED")
    assert len(deps.repo.get(WORKS, wid)["sids"]) == MAX_SESSIONS_PER_WORK


# ---------------------------------------------------------------- 提出（確定）


def test_finalize_two_records(client, clock, deps):
    wid = new_work(client)
    d1 = new_record(client, wid)
    send_whole(client, d1, ["step0", "step1", "step2"], start=True, clock=clock)
    clock.advance(hours=3)
    d2 = new_record(client, wid)
    send_whole(client, d2, ["step3", "step4", "step5"], clock=clock)
    assert client.put(f"/v1/works/{wid}/png", content=png_final(), headers={**H, "Content-Type": "image/png"}).status_code == 200
    r = finalize(client, wid)
    assert r.status_code == 200, r.text
    out = r.json()
    m = out["manifest"]
    assert not list(schema("manifest").iter_errors(m))
    assert m["v"] == 2 and [s["sid"] for s in m["sessions"]] == [d1.sid, d2.sid]
    assert [s["status"] for s in m["sessions"]] == ["completed", "completed"]
    assert [s["chunks"]["count"] for s in m["sessions"]] == [3, 3]
    # 開始画面は1回目、終了画面は最後の記録
    assert m["images"] == {"start": c.sha256_hex(jpeg("step0")), "end": c.sha256_hex(jpeg("step5"))}
    assert m["match"]["result"] != "unverified" or m["match"]["reason"]
    # 全体画像は記録をまたいで並べ、記録の間の組も比べる
    wh = m["whole"]
    assert [(it["session"], it["seq"]) for it in wh["items"]] == [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2)]
    assert len(wh["links"]) == 5 and all(x["result"] == "linked" for x in wh["links"]), wh["links"]

    b = client.get(f"/v1/p/{out['publicId']}").json()
    assert not list(schema("bundle").iter_errors(b))
    assert b["v"] == 2 and len(b["sessions"]) == 2
    assert json.loads(c.b64d(b["manifest"]["bytes"])) == m
    for bs, ms in zip(b["sessions"], m["sessions"]):
        cert = json.loads(c.b64d(bs["start"]["bytes"]))
        assert cert["sid"] == ms["sid"] and verify_kms_sig(PEM, c.b64d(bs["start"]["sig"]), c.b64d(bs["start"]["bytes"]))
        heads = [c.sha256_hex(c.b64d(ch["header"])) for ch in bs["chunks"]]
        assert ms["chunks"] == {"count": 3, "first": heads[0], "last": heads[-1]}
        prev = c.sha256_hex(c.b64d(bs["start"]["bytes"]))
        for ch in bs["chunks"]:
            h = json.loads(c.b64d(ch["header"]))
            assert h["sid"] == ms["sid"] and h["prev"] == prev
            assert verify_device_sig(cert["devicePubKey"], ch["sig"], c.b64d(ch["header"]))
            prev = c.sha256_hex(c.b64d(ch["header"]))
    # ファイルは、それぞれの記録から返す
    pid = out["publicId"]
    assert client.get(f"/v1/p/{pid}/files/start.jpg").content == jpeg("step0")
    assert client.get(f"/v1/p/{pid}/files/end.jpg").content == jpeg("step5")
    assert client.get(f"/v1/p/{pid}/files/whole-4.jpg").content == jpeg("step4")
    assert [s["status"] for s in work(client, wid)["sessions"]] == ["finalized", "finalized"]
    assert deps.repo.get(SESSIONS, d1.sid)["status"] == "finalized"


def test_finalize_waits_for_any_recording(client, clock):
    wid = new_work(client)
    d1 = new_record(client, wid)
    send_whole(client, d1, ["step0"], final=False)
    clock.advance(seconds=61)
    d2 = new_record(client, wid)
    send_whole(client, d2, ["step1"], final=False)
    clock.advance(seconds=10)
    r = finalize(client, wid)
    assert (r.status_code, code(r)) == (409, "STILL_RECORDING") and r.json()["error"]["retryAfterSec"] == 50
    clock.advance(seconds=50)
    r = finalize(client, wid)
    assert r.status_code == 200, r.text
    m = r.json()["manifest"]
    assert [s["status"] for s in m["sessions"]] == ["aborted", "aborted"]
    assert m["images"]["end"] is None and m["match"]["result"] == "unverified"


def test_finalize_drops_unstarted_and_closes(client, deps):
    wid = new_work(client)
    d1 = new_record(client, wid)
    send_whole(client, d1, ["step0", "step1"])
    extra = client.post(f"/v1/works/{wid}/sessions", json={}, headers=H).json()
    r = finalize(client, wid)
    assert r.status_code == 200, r.text
    assert [s["sid"] for s in r.json()["manifest"]["sessions"]] == [d1.sid]
    assert deps.repo.get(SESSIONS, extra["sid"]) is None
    w = work(client, wid)
    assert [s["sid"] for s in w["sessions"]] == [d1.sid] and w["session"]["sid"] == d1.sid
    # 確定の後は、記録を作れず、開始もできない
    assert code(client.post(f"/v1/works/{wid}/sessions", json={}, headers=H)) == "ALREADY_FINALIZED"
    r = client.post(f"/v1/sessions/{extra['sid']}/start", json={"startToken": extra["startToken"], "devicePubKey": Device(extra["sid"]).pub_b64})
    assert r.status_code == 404


def test_start_refused_after_finalize(client, deps):
    wid = new_work(client)
    s = client.post(f"/v1/works/{wid}/sessions", json={}, headers=H).json()
    deps.repo.set_direct(WORKS, wid, {"status": "finalized"})
    r = client.post(f"/v1/sessions/{s['sid']}/start", json={"startToken": s["startToken"], "devicePubKey": Device(s["sid"]).pub_b64})
    assert (r.status_code, code(r)) == (409, "SESSION_CLOSED")


def test_finalize_no_started_record(client):
    wid = new_work(client)
    client.post(f"/v1/works/{wid}/sessions", json={}, headers=H)
    r = finalize(client, wid)
    assert (r.status_code, code(r)) == (404, "NOT_FOUND")


def test_delete_removes_all_records(client, deps):
    wid = new_work(client)
    d1 = new_record(client, wid)
    send_whole(client, d1, ["step0"])
    d2 = new_record(client, wid)
    send_whole(client, d2, ["step1"])
    assert finalize(client, wid).status_code == 200
    assert client.delete(f"/v1/works/{wid}", headers=H).status_code == 204
    for d in (d1, d2):
        assert deps.repo.get(SESSIONS, d.sid) is None
        assert deps.store.list(f"sessions/{d.sid}/") == []


# ---------------------------------------------------------------- T14 より前の作品


def test_work_before_t14(client, deps, started):
    """sids を持たない作品（T14 より前）も、sid から記録を読む。"""
    wid, dev = started["wid"], started["dev"]
    send_whole(client, dev, ["step0", "step1"])
    w = deps.repo.get(WORKS, wid)
    deps.repo.data[WORKS][wid] = {k: v for k, v in w.items() if k != "sids"}
    assert [s["sid"] for s in work(client, wid)["sessions"]] == [dev.sid]
    d2 = new_record(client, wid)
    assert deps.repo.get(WORKS, wid)["sids"] == [dev.sid, d2.sid]


def test_finalizing_before_t14_resumes(client, deps, started):
    """段階A だけを T14 より前の形（sessionResult・range）で済ませた作品も、続きから確定できる。"""
    wid, dev = started["wid"], started["dev"]
    send_whole(client, dev, ["step0", "step1"])
    s = deps.repo.get(SESSIONS, dev.sid)
    head = s["head"]
    deps.repo.set_direct(
        WORKS,
        wid,
        {
            "status": "finalizing",
            "finalize": {
                "publicId": "p" * 22,
                "createdAt": "2026-11-05T01:01:00.000Z",
                "acceptedAt": "2026-11-05T01:01:00.000Z",
                "useEndImage": True,
                "showWhole": True,
                "sessionResult": "completed",
                "range": {"count": head["seq"] + 1, "lastSeq": head["seq"], "lastHash": head["hash"]},
                "png": None,
                "rejected": 0,
            },
        },
    )
    deps.repo.set_direct(SESSIONS, dev.sid, {"status": "finalizing"})
    r = finalize(client, wid)
    assert r.status_code == 200, r.text
    m = r.json()["manifest"]
    assert r.json()["publicId"] == "p" * 22 and m["v"] == 2
    assert [(s["sid"], s["status"], s["chunks"]["count"]) for s in m["sessions"]] == [(dev.sid, "completed", 2)]
