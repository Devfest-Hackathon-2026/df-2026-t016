"""web/public/fixtures（T06）を、T09 の検証手順を Python で書いたもので確かめる。

expected.json は T09 の verifyBundle の答えになるので、ここで同じ手順から出し直して一致を見る。
problems の detail は人が読むための文で、比べない（seq と kind だけ比べる）。
"""

from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path

import pytest

from app.core import canonical as c
from app.core.crypto import verify_device_sig, verify_kms_sig

ROOT = Path(__file__).resolve().parents[2]
FIX = ROOT / "web/public/fixtures"
VECTORS = json.loads((ROOT / "shared/vectors/signing.json").read_text(encoding="utf-8"))
NAMES = [x["name"] for x in json.loads((FIX / "index.json").read_text(encoding="utf-8"))["fixtures"]]

ORDER = {"missing": 1, "signature": 2, "key": 2, "hash": 3, "image": 3, "chain": 4, "count": 5, "gap": 5}
STATUS = {1: "incomplete", 2: "signature_mismatch", 3: "content_mismatch", 4: "chain_broken", 5: "manifest_mismatch"}


def t(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def sessions_of(b: dict) -> list[dict]:
    """証拠一式の記録（【T14】v:1 は1つ）。"""
    return b["sessions"] if b["v"] == 2 else [{"start": b["start"], "chunks": b["chunks"]}]


def manifest_sessions(m: dict) -> list[dict]:
    return m["sessions"] if m["v"] == 2 else [{k: m[k] for k in ("sid", "status", "chunks", "received")}]


def reference_verify(d: Path) -> dict:
    b = json.loads((d / "bundle.json").read_text(encoding="utf-8"))
    multi = b["v"] == 2
    pem = b["kms"]["publicKeyPem"]
    problems: list[tuple] = []

    def add(seq, kind, session=None):
        key = (session if multi else None, seq, kind) if multi else (seq, kind)
        if key not in problems:
            problems.append(key)

    if pem != VECTORS["kmsKey"]["publicPem"]:
        add(None, "key")
    mb = c.b64d(b["manifest"]["bytes"])
    if not verify_kms_sig(pem, c.b64d(b["manifest"]["sig"]), mb):
        add(None, "signature")
    m = json.loads(mb)
    bss, mss = sessions_of(b), manifest_sessions(m)
    if multi and len(bss) != len(mss):
        add(None, "count")

    active, from_headers, recv = [], [], []
    for si, bs in enumerate(bss):
        sb = c.b64d(bs["start"]["bytes"])
        if not verify_kms_sig(pem, c.b64d(bs["start"]["sig"]), sb):
            add(None, "signature", si)
        s = json.loads(sb)
        ms = mss[si] if si < len(mss) else None
        if multi and ms and s["sid"] != ms["sid"]:
            add(None, "count", si)
        prev, prev_seq, times = c.sha256_hex(sb), -1, []
        for ch in bs["chunks"]:
            hb, body = c.b64d(ch["header"]), c.b64d(ch["body"])
            rec_b = c.b64d(ch["receipt"])
            rec = json.loads(rec_b)
            try:
                h = json.loads(hb)
                seq = h["seq"]
            except ValueError:
                h, seq = {}, rec["seq"]
            if not verify_device_sig(s["devicePubKey"], ch["sig"], hb):
                add(seq, "signature", si)
            if not verify_kms_sig(pem, c.b64d(ch["receiptSig"]), rec_b) or rec["header"] != c.sha256_hex(hb):
                add(seq, "signature", si)
            if rec["seq"] != seq or h.get("prev") != prev or seq != prev_seq + 1:
                add(seq, "chain", si)
            if c.sha256_hex(body) != h.get("body") or len(body) != h.get("bodyLen"):
                add(seq, "hash", si)
            prev, prev_seq = c.sha256_hex(hb), seq
            times.append((seq, t(rec["receivedAt"])))
            active.append(sum(json.loads(body)["frames"]) > 0)
            if "whole" in (h.get("images") or {}):
                from_headers.append((si, seq, h["images"]["whole"]))
        recv.append(times)
        if ms is None:
            add(None, "count", si)
            continue
        heads = [c.sha256_hex(c.b64d(ch["header"])) for ch in bs["chunks"]]
        mc = ms["chunks"]
        if len(heads) != mc["count"] or (heads and (heads[0] != mc["first"] or heads[-1] != mc["last"])):
            add(None, "count", si)
        gaps = []
        for (_, a), (_, z) in zip(times, times[1:]):
            sec = (z - a).total_seconds()
            if sec > 30:
                gaps.append(round(sec, 3))
        if gaps != [g["sec"] for g in ms["received"]["gaps"]]:
            add(None, "gap", si)

    images = {}
    for k in ("start", "end"):
        want = m["images"][k]
        if want is None:
            images[k] = "none"
            continue
        f = b["files"][k]
        if f is None or not (d / f).exists():
            images[k] = "missing"
            add(None, "missing")
        elif c.sha256_hex((d / f).read_bytes()) != want:
            images[k] = "mismatch"
            add(None, "image")
        else:
            images[k] = "ok"

    # 途中の全体画像（T13）: ヘッダの並びと確定記録の items、載せる設定なら画像のハッシュ（【T14】記録の順・seq の順）
    wm = m.get("whole")
    listed = [(it.get("session", 0), it["seq"], it["sha256"]) for it in wm["items"]] if wm else []
    if from_headers != listed:
        add(None, "count")
    whole_status = {}
    if wm:
        for i, it in enumerate(wm["items"]):
            key = (it.get("session", 0), it["seq"])
            if not wm["shown"]:
                whole_status[key] = "hidden"
            elif not it["received"]:
                whole_status[key] = "none"
            else:
                f = (b["files"].get("whole") or [None] * len(wm["items"]))[i]
                if f is None or not (d / f).exists():
                    whole_status[key] = "missing"
                    add(it["seq"], "missing", it.get("session", 0))
                elif c.sha256_hex((d / f).read_bytes()) != it["sha256"]:
                    whole_status[key] = "mismatch"
                    add(it["seq"], "image", it.get("session", 0))
                else:
                    whole_status[key] = "ok"

    status = STATUS[min(ORDER[p[-1]] for p in problems)] if problems else "ok"
    return {"status": status, "problems": problems, "images": images, "active": active, "manifest": m, "whole": whole_status,
            "sessions": mss, "bundle_sessions": bss}


@pytest.mark.parametrize("name", NAMES)
def test_expected_matches_reference(name):
    d = FIX / name
    exp = json.loads((d / "expected.json").read_text(encoding="utf-8"))
    got = reference_verify(d)
    m = got["manifest"]
    multi = m["v"] == 2
    assert exp["integrity"]["status"] == got["status"]
    if multi:
        assert [(p.get("session"), p.get("seq"), p["kind"]) for p in exp["integrity"]["problems"]] == got["problems"]
    else:
        assert [(p.get("seq"), p["kind"]) for p in exp["integrity"]["problems"]] == got["problems"]
    assert exp["images"] == got["images"]
    assert exp["reception"]["activeChunks"] == got["active"]
    stats = [json.loads(c.b64d(ch["header"])).get("stats", {}) for bs in got["bundle_sessions"] for ch in bs["chunks"]]
    assert exp["reception"]["editorMs"] == sum(s["editorMs"] for s in stats)
    assert exp["reception"]["activeMs"] == sum(s["activeMs"] for s in stats)
    mss = got["sessions"]
    if multi:
        # 【T14】まとめた値と、記録ごとの値
        assert exp["reception"]["status"] == ("completed" if all(x["status"] == "completed" for x in mss) else "aborted")
        assert exp["reception"]["gaps"] == [{"session": i, **g} for i, x in enumerate(mss) for g in x["received"]["gaps"]]
        assert [(x["sid"], x["status"], x["gaps"]) for x in exp["reception"]["sessions"]] == [
            (x["sid"], x["status"], x["received"]["gaps"]) for x in mss
        ]
    else:
        assert "sessions" not in exp["reception"]
        assert exp["reception"]["status"] == mss[0]["status"]
        assert exp["reception"]["gaps"] == mss[0]["received"]["gaps"]
    assert exp["match"] == m["match"]
    if m.get("whole"):
        assert {(it.get("session", 0), it["seq"]): it["status"] for it in exp["whole"]["items"]} == got["whole"]
        assert exp["whole"]["links"] == m["whole"]["links"] and exp["whole"]["toPng"] == m["whole"]["toPng"]
    else:
        assert exp["whole"] is None


def test_all_seventeen_cases():
    # 【11/8】multi_declared（作者の申告の版2）を足した
    assert NAMES == [
        "normal", "gap", "missing_chunk", "tampered_header", "tampered_body",
        "truncated", "aborted", "other_png", "similar_png", "no_end_image",
        "whole_normal", "whole_switched", "whole_tampered", "whole_hidden",
        "multi_session", "multi_declared", "multi_tampered",
    ]
    want = {
        "normal": "ok", "gap": "ok", "missing_chunk": "chain_broken", "tampered_header": "signature_mismatch",
        "tampered_body": "content_mismatch", "truncated": "manifest_mismatch", "aborted": "ok",
        "other_png": "ok", "similar_png": "ok", "no_end_image": "ok",
        "whole_normal": "ok", "whole_switched": "ok", "whole_tampered": "content_mismatch", "whole_hidden": "ok",
        "multi_session": "ok", "multi_declared": "ok", "multi_tampered": "signature_mismatch",
    }
    for n in NAMES:
        assert json.loads((FIX / n / "expected.json").read_text(encoding="utf-8"))["integrity"]["status"] == want[n]


def test_normal_all_signatures_pass():
    """完了条件: normal を T01 の crypto.py で検証すると、すべての署名が通る。"""
    b = json.loads((FIX / "normal/bundle.json").read_text(encoding="utf-8"))
    pem = b["kms"]["publicKeyPem"]
    start = json.loads(c.b64d(b["start"]["bytes"]))
    assert verify_kms_sig(pem, c.b64d(b["manifest"]["sig"]), c.b64d(b["manifest"]["bytes"]))
    assert verify_kms_sig(pem, c.b64d(b["start"]["sig"]), c.b64d(b["start"]["bytes"]))
    for ch in b["chunks"]:
        assert verify_device_sig(start["devicePubKey"], ch["sig"], c.b64d(ch["header"]))
        assert verify_kms_sig(pem, c.b64d(ch["receiptSig"]), c.b64d(ch["receipt"]))


def test_scenarios():
    def m(n):
        b = json.loads((FIX / n / "bundle.json").read_text(encoding="utf-8"))
        return json.loads(c.b64d(b["manifest"]["bytes"])), b

    gap, _ = m("gap")
    assert [g["after"] for g in gap["received"]["gaps"]] == [60] and 64 < gap["received"]["gaps"][0]["sec"] < 66
    ab, abb = m("aborted")
    assert ab["status"] == "aborted" and not any(json.loads(c.b64d(x["header"]))["final"] for x in abb["chunks"])
    ne, neb = m("no_end_image")
    assert ne["images"]["end"] is None and neb["files"]["end"] is None and not (FIX / "no_end_image/end.jpg").exists()
    assert "終了画面がない" in json.loads((FIX / "no_end_image/expected.json").read_text(encoding="utf-8"))["unverified"]
    for n, same in (("normal", True), ("other_png", False), ("similar_png", False)):
        mm, _ = m(n)
        assert (c.sha256_hex((FIX / n / "original.png").read_bytes()) == mm["png"]["sha256"]) is same
    assert m("other_png")[0]["match"]["result"] == "mismatch"
    assert m("similar_png")[0]["match"]["result"] == "match"


def test_schema_and_size():
    from jsonschema import Draft202012Validator

    sch = lambda n: Draft202012Validator(json.loads((ROOT / f"shared/schemas/{n}.schema.json").read_text(encoding="utf-8")))
    for n in NAMES:
        b = json.loads((FIX / n / "bundle.json").read_text(encoding="utf-8"))
        assert not list(sch("bundle").iter_errors(b)), n
        assert not list(sch("manifest").iter_errors(json.loads(c.b64d(b["manifest"]["bytes"])))), n
        for bs in sessions_of(b):
            assert not list(sch("start").iter_errors(json.loads(c.b64d(bs["start"]["bytes"])))), n
    total = sum(p.stat().st_size for p in FIX.rglob("*") if p.is_file())
    assert total < 8 * 1024 * 1024  # T13 で 5MB から 8MB に上げた


def test_multi_session_scenario():
    """【T14】記録ごとに別の端末の鍵・別の連鎖。全体画像は記録をまたいで並ぶ。"""
    b = json.loads((FIX / "multi_session/bundle.json").read_text(encoding="utf-8"))
    m = json.loads(c.b64d(b["manifest"]["bytes"]))
    assert b["v"] == 2 and m["v"] == 2 and len(b["sessions"]) == len(m["sessions"]) == 3
    keys = {json.loads(c.b64d(bs["start"]["bytes"]))["devicePubKey"] for bs in b["sessions"]}
    assert len(keys) == 3
    assert [x["status"] for x in m["sessions"]] == ["completed", "aborted", "completed"]
    assert [len(x["received"]["gaps"]) for x in m["sessions"]] == [0, 1, 0]
    assert [(it["session"], it["seq"]) for it in m["whole"]["items"]] == [(0, 9), (0, 29), (1, 0), (1, 20), (2, 10), (2, 29)]
    assert all(x["result"] == "linked" for x in m["whole"]["links"])
