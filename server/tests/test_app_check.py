"""App Check（T12）。記録を作る要求で、本物のアプリのトークンを確かめる。"""

from __future__ import annotations

import dataclasses
import json

import pytest

from app.core import canonical as c
from app.repo.base import SESSIONS

from conftest import H, Device


class FakeAppCheck:
    """Firebase の App Check の代わり。good-* は通し、同じトークンの2回目は already_consumed にする。"""

    def __init__(self):
        self.used: set[str] = set()

    def __call__(self, token: str) -> dict:
        if not token.startswith("good-"):
            raise ValueError("invalid token")
        consumed = token in self.used
        self.used.add(token)
        return {"app_id": "1:ios:app", "already_consumed": consumed}


@pytest.fixture
def required(deps):
    deps.settings = dataclasses.replace(deps.settings, app_check="required")
    deps.app_check = FakeAppCheck()
    return deps


def new_work(client):
    return client.post("/v1/works", json={"title": "t", "displayName": "d"}, headers=H).json()["workId"]


def code(r):
    return r.json()["error"]["code"]


def test_off_by_default(client, deps):
    wid = new_work(client)
    r = client.post(f"/v1/works/{wid}/sessions", json={}, headers=H)
    assert r.status_code == 201
    s = r.json()
    dev = Device(s["sid"])
    start = client.post(f"/v1/sessions/{s['sid']}/start", json={"startToken": s["startToken"], "devicePubKey": dev.pub_b64}).json()
    assert json.loads(c.b64d(start["startCert"]))["checked"] == ["startToken"]
    assert deps.repo.get(SESSIONS, s["sid"])["appCheckVerifiedAt"] is None


def test_required_rejects_missing_and_invalid(client, required):
    wid = new_work(client)
    r = client.post(f"/v1/works/{wid}/sessions", json={}, headers=H)
    assert (r.status_code, code(r)) == (401, "APP_CHECK_FAILED")
    r = client.post(f"/v1/works/{wid}/sessions", json={}, headers={**H, "X-Firebase-AppCheck": "bad-token"})
    assert (r.status_code, code(r)) == (401, "APP_CHECK_FAILED")


def test_required_accepts_once_and_marks_start_cert(client, required):
    wid = new_work(client)
    r = client.post(f"/v1/works/{wid}/sessions", json={}, headers={**H, "X-Firebase-AppCheck": "good-1"})
    assert r.status_code == 201, r.text
    s = r.json()
    assert required.repo.get(SESSIONS, s["sid"])["appCheckVerifiedAt"]
    dev = Device(s["sid"])
    start = client.post(f"/v1/sessions/{s['sid']}/start", json={"startToken": s["startToken"], "devicePubKey": dev.pub_b64})
    assert start.status_code == 200
    assert json.loads(c.b64d(start.json()["startCert"]))["checked"] == ["startToken", "appCheck"]

    # 同じトークンの2回目は使用済みで断る
    wid2 = new_work(client)
    r = client.post(f"/v1/works/{wid2}/sessions", json={}, headers={**H, "X-Firebase-AppCheck": "good-1"})
    assert (r.status_code, code(r)) == (401, "APP_CHECK_FAILED")


def test_owner_checked_before_consuming_token(client, required):
    wid = new_work(client)
    r = client.post(f"/v1/works/{wid}/sessions", json={}, headers={"X-Dev-Uid": "someone-else", "X-Firebase-AppCheck": "good-2"})
    assert r.status_code == 403
    assert "good-2" not in required.app_check.used  # 所有者でなければトークンを使い切らない
