"""shared/vectors/signing.json を作る。

    python shared/vectors/generate_vectors.py

- ここで使う鍵はテスト専用。本番では使わない。
- 秘密鍵は固定値、ECDSA は RFC 6979（決定的）にしているので、何度動かしても同じファイルになる。
  Swift やブラウザの署名は乱数が入って毎回変わるが、検証が通ればよい。
- server/app/core を import せず、cryptography を直接使う（実装を確かめる側の値にするため）。
"""

from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import (
    Prehashed,
    decode_dss_signature,
    encode_dss_signature,
)

OUT = Path(__file__).with_name("signing.json")
N_ORDER = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

SID = "s_TestSession00001"
WORK_ID = "w_TestWork00000001"


def dumps(obj) -> bytes:
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def fixed_key(label: str) -> ec.EllipticCurvePrivateKey:
    d = int.from_bytes(hashlib.sha256(label.encode()).digest(), "big") % N_ORDER
    assert d != 0
    return ec.derive_private_key(d, ec.SECP256R1())


def det_ecdsa() -> ec.ECDSA:
    return ec.ECDSA(hashes.SHA256(), deterministic_signing=True)


def to_rs(der: bytes) -> bytes:
    r, s = decode_dss_signature(der)
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def tiles_bytes(indices: list[int]) -> bytes:
    """タイル番号 i = y*32 + x を byte[i/8] の第 (7 - i%8) ビットに立てる。"""
    buf = bytearray(96)
    for i in indices:
        buf[i // 8] |= 1 << (7 - i % 8)
    return bytes(buf)


def der_cases() -> list[dict]:
    def h(label: str) -> int:
        return int.from_bytes(hashlib.sha256(label.encode()).digest(), "big")

    cases = [
        # r・s とも最上位ビットが1 → DER では先頭に 0x00 が付いて33バイト
        ("r,s ともに先頭 0x00 付きの33バイト", h("r1") | (1 << 255), h("s1") | (1 << 255)),
        # r の最上位バイトが 0 → DER の r は31バイト。r‖s では左を 0x00 で埋める
        ("r が31バイト（r‖s で 0x00 埋め）、s は33バイト", h("r2") >> 9 | (1 << 246), h("s2") | (1 << 255)),
        # s の上位2バイトが 0 → DER の s は30バイト
        ("r は32バイト、s が30バイト", (h("r3") >> 1) | (1 << 254), h("s3") >> 17 | (1 << 238)),
    ]
    out = []
    for note, r, s in cases:
        r %= N_ORDER
        s %= N_ORDER
        der = encode_dss_signature(r, s)
        out.append({"note": note, "der": b64(der), "rs": b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))})
    return out


def main() -> None:
    device = fixed_key("drawtrace-test-device-key-v1")
    kms = fixed_key("drawtrace-test-kms-key-v1")

    device_pub = device.public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )
    kms_pub_pem = kms.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    ).decode("ascii")

    # 開始証（KMS 役が DER で署名。KMS と同じく digest に署名する）
    start_obj = {
        "v": 1,
        "type": "start",
        "sid": SID,
        "workId": WORK_ID,
        "devicePubKey": b64(device_pub),
        "checked": ["startToken"],
        "issuedAt": "2026-11-05T01:00:00.000Z",
    }
    start_bytes = dumps(start_obj)
    start_sig = kms.sign(hashlib.sha256(start_bytes).digest(), ec.ECDSA(Prehashed(hashes.SHA256()), deterministic_signing=True))

    # チャンクの本文
    tile_idx = [0, 33, 100, 767]
    body_obj = {"v": 1, "frames": [0, 0, 3, 1, 0], "tiles": b64(tiles_bytes(tile_idx))}
    body_bytes = dumps(body_obj)

    # チャンクのヘッダ（seq=0 の prev は開始証のバイト列のハッシュ）
    start_image_hash = sha(b"drawtrace-test-start-image")
    header_obj = {
        "v": 1,
        "sid": SID,
        "seq": 0,
        "prev": sha(start_bytes),
        "tStart": "2026-11-05T01:00:01.000Z",
        "tEnd": "2026-11-05T01:00:11.000Z",
        "body": sha(body_bytes),
        "bodyLen": len(body_bytes),
        "images": {"start": start_image_hash},
        "stats": {"fps": 10, "changedTiles": len(tile_idx), "resend": False, "memMB": 31, "degraded": False},
        "final": False,
    }
    header_bytes = dumps(header_obj)
    device_sig = to_rs(device.sign(header_bytes, det_ecdsa()))

    image_msg = f"image:{SID}:{start_image_hash}".encode("utf-8")
    image_sig = to_rs(device.sign(image_msg, det_ecdsa()))

    # 受領証
    receipt_obj = {
        "v": 1,
        "type": "receipt",
        "sid": SID,
        "seq": 0,
        "header": sha(header_bytes),
        "receivedAt": "2026-11-05T01:00:11.234Z",
    }
    receipt_bytes = dumps(receipt_obj)
    receipt_sig = kms.sign(hashlib.sha256(receipt_bytes).digest(), ec.ECDSA(Prehashed(hashes.SHA256()), deterministic_signing=True))

    # 正準 JSON（日本語とスラッシュを含む。Swift の sortedKeys・withoutEscapingSlashes と同じになること）
    canon_obj = {"b": "手描き/テスト", "a": [1, 2, {"z": True, "y": None}], "c": "a\"b\\c"}

    vectors = {
        "_note": "テスト専用の鍵とデータ。本番では使わない。generate_vectors.py で作る。",
        "deviceKey": {
            "privateHex": device.private_numbers().private_value.to_bytes(32, "big").hex(),
            "publicX963": b64(device_pub),
        },
        "canonical": {"obj": canon_obj, "bytes": b64(dumps(canon_obj))},
        "startCert": {
            "obj": start_obj,
            "bytes": b64(start_bytes),
            "sha256": sha(start_bytes),
            "sig": b64(start_sig),
        },
        "body": {
            "obj": body_obj,
            "bytes": b64(body_bytes),
            "sha256": sha(body_bytes),
            "tilesSet": tile_idx,
        },
        "header": {
            "obj": header_obj,
            "bytes": b64(header_bytes),
            "sha256": sha(header_bytes),
        },
        "deviceSig": {"of": "header.bytes", "sig": b64(device_sig)},
        "imageSig": {"message": image_msg.decode("utf-8"), "sig": b64(image_sig)},
        "receipt": {
            "obj": receipt_obj,
            "bytes": b64(receipt_bytes),
            "sig": b64(receipt_sig),
        },
        "kmsKey": {
            "privateHex": kms.private_numbers().private_value.to_bytes(32, "big").hex(),
            "publicPem": kms_pub_pem,
            "keyVersion": "test/1",
        },
        "derToRs": der_cases(),
    }
    OUT.write_text(json.dumps(vectors, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
