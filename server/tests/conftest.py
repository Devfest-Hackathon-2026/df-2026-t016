"""受付API のテストの共通部分。memory 版・local 版・LocalSigner を使う。"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from app.auth import DevAuth
from app.config import Settings
from app.core import canonical as c
from app.core.crypto import LocalSigner, der_to_rs
from app.deps import Deps
from app.main import create_app
from app.repo.memory import MemoryRepo
from app.store.local import LocalStore

ROOT = Path(__file__).resolve().parents[2]
VECTORS = json.loads((ROOT / "shared/vectors/signing.json").read_text(encoding="utf-8"))


def kms_test_pem() -> str:
    key = ec.derive_private_key(int(VECTORS["kmsKey"]["privateHex"], 16), ec.SECP256R1())
    return key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode("ascii")


class Clock:
    def __init__(self):
        self.now = datetime(2026, 11, 5, 1, 0, 0, tzinfo=timezone.utc)

    def __call__(self):
        return self.now

    def advance(self, **kw):
        self.now += timedelta(**kw)


class Device:
    """録画拡張の役。メモリ上の P-256 の鍵でヘッダと画像に署名する。"""

    def __init__(self, sid: str):
        self.sid = sid
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.pub_b64 = c.b64e(
            self.key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
        )
        self.prev: str | None = None
        self.seq = 0

    def sign(self, msg: bytes) -> bytes:
        return der_to_rs(self.key.sign(msg, ec.ECDSA(hashes.SHA256())))

    def set_start(self, start_cert_b64: str) -> None:
        self.prev = c.sha256_hex(c.b64d(start_cert_b64))

    def chunk(self, final=False, seq=None, prev=None, images=None, t_end="2026-11-05T01:00:10.000Z", **override):
        body_obj = {"v": 1, "frames": [0, 1, 2], "tiles": c.b64e(bytes(96))}
        body = c.dumps_bytes(body_obj)
        header_obj = {
            "v": 1,
            "sid": self.sid,
            "seq": self.seq if seq is None else seq,
            "prev": self.prev if prev is None else prev,
            "tStart": "2026-11-05T01:00:00.000Z",
            "tEnd": t_end,
            "body": c.sha256_hex(body),
            "bodyLen": len(body),
            "stats": {"fps": 10, "changedTiles": 3, "resend": False, "memMB": 30, "degraded": False},
            "final": final,
        }
        if images:
            header_obj["images"] = images
        header_obj.update(override)
        header = c.dumps_bytes(header_obj)
        return {"header": header, "sig": self.sign(header), "body": body}

    def accept(self, chunk: dict) -> None:
        """送ったチャンクが受け取られた前提で、次の prev と seq に進める。"""
        self.prev = c.sha256_hex(chunk["header"])
        self.seq += 1


def as_json(chunk: dict) -> dict:
    return {k: c.b64e(v) for k, v in chunk.items()}


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def deps(tmp_path, clock):
    signer = LocalSigner(kms_test_pem(), "test/1")
    return Deps(
        settings=Settings(),
        signer=signer,
        store=LocalStore(tmp_path / "store"),
        repo=MemoryRepo(),
        auth=DevAuth(),
        clock=clock,
    )


@pytest.fixture
def client(deps):
    return TestClient(create_app(deps), raise_server_exceptions=False)


UID = "user-a"
H = {"X-Dev-Uid": UID}


@pytest.fixture
def started(client):
    """作品を作り、セッションを開始したところ。(workId, sid, device, startCert, sig) を返す。"""
    r = client.post("/v1/works", json={"title": "テスト", "displayName": "描き手"}, headers=H)
    assert r.status_code == 201, r.text
    wid = r.json()["workId"]
    r = client.post(f"/v1/works/{wid}/sessions", json={}, headers=H)
    assert r.status_code == 201, r.text
    sid, token = r.json()["sid"], r.json()["startToken"]
    dev = Device(sid)
    r = client.post(f"/v1/sessions/{sid}/start", json={"startToken": token, "devicePubKey": dev.pub_b64})
    assert r.status_code == 200, r.text
    dev.set_start(r.json()["startCert"])
    return {"wid": wid, "sid": sid, "token": token, "dev": dev, "start": r.json()}
