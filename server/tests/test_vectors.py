"""shared/vectors/signing.json の全項目を、server/app/core で検証する。"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path

import pytest

from app.core import canonical as c
from app.core import crypto

from conftest import kms_test_pem

ROOT = Path(__file__).resolve().parents[2]
V = json.loads((ROOT / "shared/vectors/signing.json").read_text(encoding="utf-8"))
SWIFT = ROOT / "shared/vectors/swift_signature.json"


# ---------------------------------------------------------------- canonical


def test_dumps_bytes_matches_vectors():
    for key in ("canonical", "startCert", "body", "header", "receipt"):
        assert c.dumps_bytes(V[key]["obj"]) == c.b64d(V[key]["bytes"]), key


def test_dumps_bytes_rules():
    b = c.dumps_bytes({"b": "手/描", "a": 1})
    assert b == '{"a":1,"b":"手/描"}'.encode("utf-8")


def test_sha256_hex():
    for key in ("startCert", "body", "header"):
        assert c.sha256_hex(c.b64d(V[key]["bytes"])) == V[key]["sha256"]
    assert re.fullmatch(r"[0-9a-f]{64}", c.sha256_hex(b""))


def test_b64_roundtrip_and_strict():
    for b in (b"", b"\x00", b"\xff\xfe", bytes(range(256))):
        assert c.b64d(c.b64e(b)) == b
    with pytest.raises(ValueError):
        c.b64d("abc")  # パディングの誤り
    with pytest.raises(ValueError):
        c.b64d("ab-_")  # base64url の文字は標準 base64 では不正
    with pytest.raises(ValueError):
        c.b64d("あいう")


def test_ids():
    assert re.fullmatch(r"w_[A-Za-z0-9_-]{16}", c.new_work_id())
    assert re.fullmatch(r"s_[A-Za-z0-9_-]{16}", c.new_sid())
    assert re.fullmatch(r"[A-Za-z0-9_-]{22}", c.new_public_id())
    assert re.fullmatch(r"[A-Za-z0-9_-]{43}", c.new_start_token())
    assert c.new_sid() != c.new_sid()


def test_iso_ms():
    dt = datetime(2026, 11, 5, 1, 2, 3, 456789, tzinfo=timezone.utc)
    assert c.iso_ms(dt) == "2026-11-05T01:02:03.456Z"
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z", c.iso_ms())
    with pytest.raises(ValueError):
        c.iso_ms(datetime(2026, 11, 5))


def test_tiles_bit_order():
    tiles = c.b64d(V["body"]["obj"]["tiles"])
    assert len(tiles) == 96
    on = [i for i in range(768) if tiles[i // 8] >> (7 - i % 8) & 1]
    assert on == V["body"]["tilesSet"]


def test_chain_header_prev_is_start_cert_hash():
    assert V["header"]["obj"]["prev"] == V["startCert"]["sha256"]
    assert V["header"]["obj"]["body"] == V["body"]["sha256"]
    assert V["header"]["obj"]["bodyLen"] == len(c.b64d(V["body"]["bytes"]))
    assert V["receipt"]["obj"]["header"] == V["header"]["sha256"]


# ---------------------------------------------------------------- 端末署名


def test_device_sig_header():
    pub = V["deviceKey"]["publicX963"]
    header = c.b64d(V["header"]["bytes"])
    assert crypto.verify_device_sig(pub, V["deviceSig"]["sig"], header)
    assert not crypto.verify_device_sig(pub, V["deviceSig"]["sig"], header + b" ")


def test_device_sig_image():
    pub = V["deviceKey"]["publicX963"]
    msg = V["imageSig"]["message"]
    sid = V["header"]["obj"]["sid"]
    assert re.fullmatch(rf"image:{sid}:[0-9a-f]{{64}}", msg)
    assert crypto.verify_device_sig(pub, V["imageSig"]["sig"], msg.encode("utf-8"))
    assert not crypto.verify_device_sig(pub, V["imageSig"]["sig"], c.b64d(V["header"]["bytes"]))


def test_device_sig_rejects_bad_inputs():
    pub = V["deviceKey"]["publicX963"]
    header = c.b64d(V["header"]["bytes"])
    sig = c.b64d(V["deviceSig"]["sig"])
    # DER を渡しても通らない（r‖s だけを受け付ける）
    assert not crypto.verify_device_sig(pub, c.b64e(crypto.rs_to_der(sig)), header)
    assert not crypto.verify_device_sig(pub, c.b64e(sig[:63]), header)
    assert not crypto.verify_device_sig(pub, "not base64", header)
    flipped = bytearray(sig)
    flipped[10] ^= 1
    assert not crypto.verify_device_sig(pub, c.b64e(bytes(flipped)), header)
    # 圧縮形式（33バイト）の公開鍵は受け付けない
    raw = c.b64d(pub)
    compressed = bytes([2 + (raw[64] & 1)]) + raw[1:33]
    assert not crypto.verify_device_sig(c.b64e(compressed), V["deviceSig"]["sig"], header)


def test_device_key_pair_matches():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    d = int(V["deviceKey"]["privateHex"], 16)
    key = ec.derive_private_key(d, ec.SECP256R1())
    raw = key.public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )
    assert c.b64e(raw) == V["deviceKey"]["publicX963"]
    assert V["startCert"]["obj"]["devicePubKey"] == V["deviceKey"]["publicX963"]


# ---------------------------------------------------------------- KMS 役の署名


def test_start_cert_and_receipt_sig():
    pem = V["kmsKey"]["publicPem"]
    for key in ("startCert", "receipt"):
        msg = c.b64d(V[key]["bytes"])
        assert crypto.verify_kms_sig(pem, c.b64d(V[key]["sig"]), msg), key
        assert not crypto.verify_kms_sig(pem, c.b64d(V[key]["sig"]), msg + b"x"), key


def test_local_signer():
    signer = crypto.LocalSigner(kms_test_pem(), V["kmsKey"]["keyVersion"])
    assert signer.public_key_pem() == V["kmsKey"]["publicPem"]
    assert signer.key_version() == "test/1"
    msg = c.b64d(V["startCert"]["bytes"])
    der = signer.sign(msg)
    assert crypto.verify_kms_sig(V["kmsKey"]["publicPem"], der, msg)
    # KMS と同じく digest に署名している: sign(msg) と sign_digest(sha256(msg)) は同じ意味
    import hashlib

    der2 = signer.sign_digest(hashlib.sha256(msg).digest())
    assert crypto.verify_kms_sig(V["kmsKey"]["publicPem"], der2, msg)
    with pytest.raises(ValueError):
        signer.sign_digest(b"short")


def test_kms_sig_also_verifies_as_rs_with_device_style_api():
    """ブラウザは KMS の DER を r‖s に変えて検証する。その経路と同じことを確かめる。"""
    from cryptography.hazmat.primitives import serialization

    pub = serialization.load_pem_public_key(V["kmsKey"]["publicPem"].encode())
    raw = pub.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    rs = crypto.der_to_rs(c.b64d(V["startCert"]["sig"]))
    assert crypto.verify_device_sig(c.b64e(raw), c.b64e(rs), c.b64d(V["startCert"]["bytes"]))


# ---------------------------------------------------------------- DER ⇔ r‖s


@pytest.mark.parametrize("case", V["derToRs"], ids=[x["note"] for x in V["derToRs"]])
def test_der_rs_conversion(case):
    der = c.b64d(case["der"])
    rs = c.b64d(case["rs"])
    assert len(rs) == 64
    assert crypto.der_to_rs(der) == rs
    assert crypto.rs_to_der(rs) == der


def test_rs_to_der_rejects_wrong_length():
    with pytest.raises(ValueError):
        crypto.rs_to_der(b"\x01" * 63)


# ---------------------------------------------------------------- Swift の署名（T03 で置く）


@pytest.mark.skipif(not SWIFT.exists(), reason="swift_signature.json は T03 で置く")
def test_swift_signature():
    s = json.loads(SWIFT.read_text(encoding="utf-8"))
    header = c.b64d(s.get("header", V["header"]["bytes"]))
    assert crypto.verify_device_sig(s["publicX963"], s["sig"], header)
