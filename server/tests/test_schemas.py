"""shared/schemas/ の JSON Schema が、テストベクタと見本を通し、誤りを弾くことを確かめる。"""

from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[2]
SCHEMAS = ROOT / "shared/schemas"
V = json.loads((ROOT / "shared/vectors/signing.json").read_text(encoding="utf-8"))

H = "0" * 64
T = "2026-11-05T01:00:00.000Z"


def validator(name: str) -> Draft202012Validator:
    schema = json.loads((SCHEMAS / f"{name}.schema.json").read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema)


def ok(name, obj):
    errors = list(validator(name).iter_errors(obj))
    assert not errors, [e.message for e in errors]


def ng(name, obj):
    assert list(validator(name).iter_errors(obj)), f"{name} は弾くべき: {obj}"


MANIFEST = {
    "v": 1,
    "type": "manifest",
    "rules": "2026-11-05.1",
    "workId": V["startCert"]["obj"]["workId"],
    "title": "テスト",
    "displayName": "描き手",
    "sid": V["startCert"]["obj"]["sid"],
    "status": "completed",
    "chunks": {"count": 420, "first": H, "last": H},
    "received": {"first": T, "last": T, "gaps": [{"after": 120, "sec": 45}]},
    "images": {"start": H, "end": None},
    "png": {"sha256": H, "width": 3000, "height": 2000},
    "match": {"result": "match", "score": 0.91, "reason": None},
    "declaration": {
        "version": 1,
        "text": "この作品は手描きで制作しました（AI による生成・補助は使っていません）。",
        "acceptedAt": T,
    },
    "rejected": 0,
    "createdAt": T,
}

BUNDLE = {
    "v": 1,
    "manifest": {"bytes": V["startCert"]["bytes"], "sig": V["startCert"]["sig"]},
    "start": {"bytes": V["startCert"]["bytes"], "sig": V["startCert"]["sig"]},
    "chunks": [
        {
            "header": V["header"]["bytes"],
            "sig": V["deviceSig"]["sig"],
            "body": V["body"]["bytes"],
            "receipt": V["receipt"]["bytes"],
            "receiptSig": V["receipt"]["sig"],
        }
    ],
    "files": {"start": "start.jpg", "end": None, "png": "png.jpg"},
    "kms": {"publicKeyPem": V["kmsKey"]["publicPem"], "keyVersion": "test/1"},
    "explanation": None,
}


def test_vectors_pass():
    ok("start", V["startCert"]["obj"])
    ok("header", V["header"]["obj"])
    ok("body", V["body"]["obj"])
    ok("receipt", V["receipt"]["obj"])
    ok("manifest", MANIFEST)
    ok("bundle", BUNDLE)


def test_header_rules():
    h = V["header"]["obj"]
    ok("header", {**h, "unknownField": 1})  # 未知のフィールドは拒否しない
    no_images = {k: v for k, v in h.items() if k != "images"}
    ok("header", no_images)
    ok("header", {**h, "images": {"start": H, "end": H}, "final": True})
    ng("header", {**h, "images": {}})
    ng("header", {**h, "images": {"middle": H}})
    ng("header", {**h, "seq": -1})
    ng("header", {**h, "prev": H.upper().replace("0", "A")})
    ng("header", {**h, "tStart": "2026-11-05T01:00:00Z"})  # ミリ秒なし
    ng("header", {**h, "sid": "s_short"})
    for key in ("v", "sid", "seq", "prev", "tStart", "tEnd", "body", "bodyLen", "stats", "final"):
        ng("header", {k: v for k, v in h.items() if k != key})
    stats = {k: v for k, v in h["stats"].items() if k != "degraded"}
    ng("header", {**h, "stats": stats})


def test_body_rules():
    b = V["body"]["obj"]
    ng("body", {**b, "frames": [769]})
    ng("body", {**b, "frames": [0] * 601})
    ok("body", {**b, "frames": []})
    ng("body", {**b, "tiles": b["tiles"][:-4]})


def test_start_rules():
    s = V["startCert"]["obj"]
    ok("start", {**s, "checked": ["startToken", "appCheck"]})
    ng("start", {**s, "checked": []})
    ng("start", {**s, "uid": "x"})  # uid は公開物に入れない
    ng("start", {**s, "devicePubKey": s["devicePubKey"][:-4]})


def test_manifest_rules():
    ok("manifest", {**MANIFEST, "png": None, "match": {"result": "unverified", "score": None, "reason": "PNG なし"}})
    ok(
        "manifest",
        {
            **MANIFEST,
            "status": "aborted",
            "chunks": {"count": 0, "first": None, "last": None},
            "received": {"first": None, "last": None, "gaps": []},
            "images": {"start": None, "end": None},
        },
    )
    ng("manifest", {**MANIFEST, "status": "recording"})
    ng("manifest", {**MANIFEST, "received": {**MANIFEST["received"], "gaps": [{"after": 1, "sec": 30}]}})
    decl = copy.deepcopy(MANIFEST["declaration"])
    decl["text"] = "別の文言"
    ng("manifest", {**MANIFEST, "declaration": decl})


def test_bundle_rules():
    ok("bundle", {**BUNDLE, "explanation": {"text": "説明", "model": "gemini"}})
    ng("bundle", {**BUNDLE, "files": {"start": "other.jpg", "end": None, "png": None}})
    bad = copy.deepcopy(BUNDLE)
    bad["chunks"][0]["sig"] = V["startCert"]["sig"]  # DER は r‖s の欄に入らない
    ng("bundle", bad)
    ng("bundle", {k: v for k, v in BUNDLE.items() if k != "explanation"})


@pytest.mark.parametrize("name", ["header", "body", "start", "receipt", "manifest", "bundle"])
def test_schema_is_valid_2020_12(name):
    validator(name)


# ---------------------------------------------------------------- 全体画像（T13 の「Tさん 0」）

WHOLE = {
    "shown": True,
    "items": [
        {"seq": 10, "sha256": H, "received": True, "canvas": {"x": 0.1, "y": 0.12, "w": 0.8, "h": 0.75}},
        {"seq": 30, "sha256": H, "received": False, "canvas": None},
    ],
    "links": [{"from": 0, "to": 1, "result": "unconfirmed", "kept": None, "reason": "画像が届いていない"}],
    "toPng": {"result": "linked", "kept": 0.97, "reason": None},
}


def test_header_images_whole():
    h = V["header"]["obj"]
    ok("header", {**h, "images": {"whole": H}})
    ok("header", {**h, "images": {"end": H, "whole": H}, "final": True})
    ng("header", {**h, "images": {"wholes": H}})


def test_manifest_whole():
    ok("manifest", MANIFEST)  # whole なし
    ok("manifest", {**MANIFEST, "whole": None})
    ok("manifest", {**MANIFEST, "whole": WHOLE})
    ok("manifest", {**MANIFEST, "whole": {**WHOLE, "toPng": None, "shown": False}})
    bad = copy.deepcopy(WHOLE)
    bad["links"][0]["result"] = "different"
    ng("manifest", {**MANIFEST, "whole": bad})
    ng("manifest", {**MANIFEST, "whole": {**WHOLE, "items": []}})
    bad = copy.deepcopy(WHOLE)
    bad["items"][0]["canvas"]["w"] = 1.2
    ng("manifest", {**MANIFEST, "whole": bad})


def test_bundle_files_whole():
    ok("bundle", BUNDLE)
    ok("bundle", {**BUNDLE, "files": {**BUNDLE["files"], "whole": None}})
    ok("bundle", {**BUNDLE, "files": {**BUNDLE["files"], "whole": ["whole-0.jpg", None]}})
    ng("bundle", {**BUNDLE, "files": {**BUNDLE["files"], "whole": ["whole-01.jpg"]}})
    ng("bundle", {**BUNDLE, "files": {**BUNDLE["files"], "whole": []}})


# ---------------------------------------------------------------- 記録が複数（T14、v:2）


def test_v2_manifest_and_bundle():
    b = json.loads((ROOT / "web/public/fixtures/multi_session/bundle.json").read_text(encoding="utf-8"))
    import base64

    m = json.loads(base64.b64decode(b["manifest"]["bytes"]))
    ok("bundle", b)
    ok("manifest", m)
    # v:1 の項目を v:2 に混ぜない・v:2 の項目を v:1 に混ぜない
    ng("manifest", {**m, "sid": m["sessions"][0]["sid"]})
    ng("manifest", {k: v for k, v in m.items() if k != "sessions"})
    ng("manifest", {**m, "v": 1})
    ng("manifest", {**m, "sessions": []})
    bad = copy.deepcopy(m)
    del bad["whole"]["items"][0]["session"]
    ng("manifest", bad)
    ng("manifest", {**MANIFEST, "sessions": m["sessions"]})
    ng("bundle", {**b, "start": b["sessions"][0]["start"]})
    ng("bundle", {k: v for k, v in b.items() if k != "sessions"})
    ng("bundle", {**BUNDLE, "v": 2})


def test_start_device_key_any_first_byte():
    """端末の公開鍵は 0x04 の後の X が何で始まってもよい（以前のパターンは X の先頭が 0x0? のときだけ通した）。"""
    s = json.loads(json.dumps(V["startCert"]["obj"]))
    for key in ("BHA4SWrZqegJ9FtxUJvWeZ08ZGbBLJF34KMsH+dGUfiX/o3SYDb7NiNs22Fe5FivinJFNbka0di+Rb6yCOgPoAU=",
                "BP" + "A" * 85 + "="):
        ok("start", {**s, "devicePubKey": key})
    ng("start", {**s, "devicePubKey": "BQ" + "A" * 85 + "="})
