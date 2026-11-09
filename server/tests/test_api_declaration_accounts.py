"""【11/8】作者の申告の版2（AI の使い方を選ぶ）と、アカウントの表（#15・#16）。"""

from __future__ import annotations

import json
from pathlib import Path

from jsonschema import Draft202012Validator

from app.repo.base import ACCOUNTS, WORKS
from app.services import finalize as fin

from conftest import H
from test_api_finalize import PNG_A, code, put_png, record

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = Draft202012Validator(json.loads((ROOT / "shared/schemas/manifest.schema.json").read_text(encoding="utf-8")))


def finalize_with(client, wid, body):
    return client.post(f"/v1/works/{wid}/finalize", json=body, headers=H)


def recorded(client, started):
    record(client, started)
    assert put_png(client, started["wid"], PNG_A).status_code == 200
    return started["wid"]


# ---------------------------------------------------------------- 作者の申告


def test_declaration_v2_goes_into_signed_manifest(client, started):
    wid = recorded(client, started)
    r = finalize_with(client, wid, {"declaration": {"aiUse": "partial", "detail": "  背景の一部に使いました\r\n人物は手描き  "}})
    assert r.status_code == 200, r.text
    d = r.json()["manifest"]["declaration"]
    assert d["version"] == 2 and d["aiUse"] == "partial"
    assert d["text"] == fin.DECLARATION_TEXTS["partial"]
    assert d["detail"] == "背景の一部に使いました\n人物は手描き"
    assert not list(MANIFEST.iter_errors(r.json()["manifest"]))
    # 公開した確定記録にも同じ申告が入っている
    pub = client.get(f"/v1/p/{r.json()['publicId']}").json()
    assert fin.manifest_of(pub)["declaration"] == d


def test_declaration_v2_without_detail(client, started):
    wid = recorded(client, started)
    r = finalize_with(client, wid, {"declaration": {"aiUse": "none"}})
    assert r.status_code == 200, r.text
    d = r.json()["manifest"]["declaration"]
    assert (d["version"], d["aiUse"], d["text"], d["detail"]) == (2, "none", "この作品は AI を使用していません。", "")


def test_declaration_v2_wins_over_v1(client, started):
    wid = recorded(client, started)
    r = finalize_with(client, wid, {"declarationAccepted": True, "declaration": {"aiUse": "major", "detail": ""}})
    assert r.status_code == 200, r.text
    assert r.json()["manifest"]["declaration"]["aiUse"] == "major"


def test_declaration_v1_still_accepted(client, started):
    # 前の版のアプリ（declarationAccepted だけを送る）
    wid = recorded(client, started)
    r = finalize_with(client, wid, {"declarationAccepted": True})
    assert r.status_code == 200, r.text
    d = r.json()["manifest"]["declaration"]
    assert d["version"] == 1 and d["text"] == fin.DECLARATION_TEXT and "aiUse" not in d


def test_declaration_v2_is_validated(client, started):
    wid = started["wid"]
    r = finalize_with(client, wid, {"declaration": {"aiUse": "some"}})
    assert (r.status_code, code(r)) == (400, "BAD_REQUEST")
    r = finalize_with(client, wid, {"declaration": {"aiUse": "none", "detail": "あ" * 401}})
    assert (r.status_code, code(r)) == (400, "BAD_REQUEST")
    r = finalize_with(client, wid, {})
    assert (r.status_code, code(r)) == (400, "DECLARATION_REQUIRED")


def test_detail_control_characters_are_removed():
    d = fin.make_declaration(False, {"aiUse": "none", "detail": "a\x00b\x1bc\td\n"}, "2026-11-08T00:00:00.000Z")
    assert d["detail"] == "abc\td"


# ---------------------------------------------------------------- アカウント


def test_me_before_and_after_creating_a_work(client, deps):
    r = client.get("/v1/me", headers=H)
    assert r.status_code == 200, r.text
    assert r.json() == {"uid": "user-a", "displayName": None, "createdAt": None, "workCount": 0, "workLimit": 20}

    wid = client.post("/v1/works", json={"title": "t", "displayName": "描き手"}, headers=H).json()["workId"]
    me = client.get("/v1/me", headers=H).json()
    assert me["displayName"] == "描き手" and me["workCount"] == 1 and me["createdAt"]
    # 作品は ownerUid でアカウントに紐付く
    account = deps.repo.get(ACCOUNTS, "user-a")
    assert account["uid"] == "user-a" and deps.repo.get(WORKS, wid)["ownerUid"] == account["uid"]


def test_put_me_creates_and_renames(client, deps, clock):
    r = client.put("/v1/me", json={"displayName": "はじめの名前"}, headers=H)
    assert r.status_code == 200 and r.json()["displayName"] == "はじめの名前"
    created = deps.repo.get(ACCOUNTS, "user-a")["createdAt"]
    clock.advance(seconds=10)
    r = client.put("/v1/me", json={"displayName": "つぎの名前"}, headers=H)
    assert r.json()["displayName"] == "つぎの名前"
    a = deps.repo.get(ACCOUNTS, "user-a")
    assert a["createdAt"] == created and a["updatedAt"] > created
    # 作品を作ると、使った表示名がアカウントにも入る
    client.post("/v1/works", json={"title": "t", "displayName": "作品の名前"}, headers=H)
    assert deps.repo.get(ACCOUNTS, "user-a")["displayName"] == "作品の名前"


def test_accounts_are_separate(client):
    client.put("/v1/me", json={"displayName": "A"}, headers=H)
    client.post("/v1/works", json={"title": "t", "displayName": "A"}, headers=H)
    other = {"X-Dev-Uid": "user-b"}
    me = client.get("/v1/me", headers=other).json()
    assert me["uid"] == "user-b" and me["displayName"] is None and me["workCount"] == 0
    assert client.get("/v1/works", headers=other).json()["works"] == []


def test_put_me_is_validated(client):
    assert code(client.put("/v1/me", json={"displayName": ""}, headers=H)) == "BAD_REQUEST"
    assert code(client.put("/v1/me", json={"displayName": "あ" * 51}, headers=H)) == "BAD_REQUEST"
    assert client.get("/v1/me").status_code == 401
