"""作者が書く文字から、見え方を偽れる文字を消す（core/text.py）。"""

from __future__ import annotations

from app.core.text import clean
from app.services.finalize import make_declaration

from conftest import H

RLO = "‮"  # 右から左に並べる
ZWSP = "​"  # 幅の無い空白
TAG_A = "\U000e0041"  # タグ文字（見えない英字）


def test_clean_removes_bidi_zero_width_and_tags():
    assert clean(f"Alice{RLO}ecilA") == "AliceecilA"
    assert clean(f"a{ZWSP}b{TAG_A}c⁦d⁩") == "abcd"
    assert clean("a\nb\tc\x07") == "abc"  # 1行の欄では改行・タブも消す


def test_clean_keeps_normal_text_and_emoji():
    s = "春の庭 🌸 ｲﾗｽﾄ 👩‍🎨 ありがとう"
    assert clean(s) == s


def test_clean_multiline_keeps_newlines_and_tabs():
    assert clean(f" 下描き\r\n線画 {RLO}色\t塗り ", multiline=True) == "下描き\n線画\n色\t塗り"


def test_create_work_cleans_title_and_display_name(client):
    r = client.post("/v1/works", json={"title": f"庭{RLO}の絵", "displayName": f"N{ZWSP}さん"}, headers=H)
    assert r.status_code == 201
    w = client.get(f"/v1/works/{r.json()['workId']}", headers=H).json()
    assert (w["title"], w["displayName"]) == ("庭の絵", "Nさん")


def test_only_invisible_characters_is_rejected(client):
    r = client.post("/v1/works", json={"title": f"{RLO}{ZWSP}", "displayName": "d"}, headers=H)
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "BAD_REQUEST"
    r = client.put("/v1/me", json={"displayName": " ⁦ "}, headers=H)
    assert r.status_code == 400


def test_put_me_cleans_display_name(client):
    r = client.put("/v1/me", json={"displayName": f"サンプル作者{RLO}"}, headers=H)
    assert r.status_code == 200
    assert client.get("/v1/me", headers=H).json()["displayName"] == "サンプル作者"


def test_declaration_detail_is_cleaned():
    d = make_declaration(False, {"aiUse": "none", "detail": f"線画は手で{RLO}描いた\r\n色も"}, "2026-11-08T00:00:00.000Z")
    assert d["detail"] == "線画は手で描いた\n色も"
