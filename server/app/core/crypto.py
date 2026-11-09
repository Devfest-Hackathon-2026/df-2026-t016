"""署名の取り決め（設計書6章、tasks/00_共通仕様.md 3章）。

- 端末署名: P-256、r‖s の64バイト。署名対象のバイト列をそのまま渡し、中で SHA-256 する
- KMS 署名: DER。KMS には SHA-256(バイト列) を digest として渡す
  LocalSigner も同じく digest に署名して、KmsSigner と挙動をそろえる
"""

from __future__ import annotations

import hashlib
from abc import ABC, abstractmethod

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import (
    Prehashed,
    decode_dss_signature,
    encode_dss_signature,
)

from .canonical import b64d

_CURVE = ec.SECP256R1()
_N = 32  # P-256 の r・s のバイト数


# ---------------------------------------------------------------- r‖s ⇔ DER


def der_to_rs(der: bytes) -> bytes:
    """DER の ECDSA 署名を、r‖s の64バイトにする。"""
    r, s = decode_dss_signature(der)
    if not (0 < r < 2 ** (8 * _N) and 0 < s < 2 ** (8 * _N)):
        raise ValueError("r or s out of range")
    return r.to_bytes(_N, "big") + s.to_bytes(_N, "big")


def rs_to_der(rs: bytes) -> bytes:
    """r‖s の64バイトを DER にする。"""
    if len(rs) != 2 * _N:
        raise ValueError("r||s must be 64 bytes")
    r = int.from_bytes(rs[:_N], "big")
    s = int.from_bytes(rs[_N:], "big")
    return encode_dss_signature(r, s)


# ---------------------------------------------------------------- 端末署名


def load_device_key(pub_x963_b64: str) -> ec.EllipticCurvePublicKey:
    """x9.63 形式（65バイト、先頭 0x04）の base64 から公開鍵を読む。"""
    raw = b64d(pub_x963_b64)
    if len(raw) != 65 or raw[0] != 0x04:
        raise ValueError("device public key must be 65-byte x9.63 (0x04||X||Y)")
    return ec.EllipticCurvePublicKey.from_encoded_point(_CURVE, raw)


def verify_device_sig(pub_x963_b64: str, sig_rs_b64: str, message: bytes) -> bool:
    """端末署名（r‖s）を検証する。鍵・署名の形式の誤りも False を返す。"""
    try:
        key = load_device_key(pub_x963_b64)
        der = rs_to_der(b64d(sig_rs_b64))
        key.verify(der, message, ec.ECDSA(hashes.SHA256()))
        return True
    except (InvalidSignature, ValueError):
        return False


# ---------------------------------------------------------------- KMS 署名


def verify_kms_sig(public_key_pem: str, sig_der: bytes, message: bytes) -> bool:
    """KMS（または LocalSigner）の DER 署名を、PEM（SPKI）の公開鍵で検証する。"""
    try:
        key = serialization.load_pem_public_key(public_key_pem.encode("ascii"))
        if not isinstance(key, ec.EllipticCurvePublicKey):
            return False
        key.verify(sig_der, message, ec.ECDSA(hashes.SHA256()))
        return True
    except (InvalidSignature, ValueError):
        return False


class Signer(ABC):
    """開始証・受領証・確定記録に署名する役。"""

    def sign(self, message: bytes) -> bytes:
        """message の SHA-256 の digest に署名し、DER を返す。"""
        return self.sign_digest(hashlib.sha256(message).digest())

    @abstractmethod
    def sign_digest(self, digest: bytes) -> bytes:
        """SHA-256 の digest（32バイト）に署名し、DER を返す。"""

    @abstractmethod
    def public_key_pem(self) -> str: ...

    @abstractmethod
    def key_version(self) -> str: ...


class LocalSigner(Signer):
    """PEM の秘密鍵で署名する。ローカル開発と試験データ用（本番は KmsSigner）。"""

    def __init__(self, private_key_pem: str, key_version: str = "local/1"):
        key = serialization.load_pem_private_key(private_key_pem.encode("ascii"), password=None)
        if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != _CURVE.name:
            raise ValueError("LocalSigner needs a P-256 private key")
        self._key = key
        self._version = key_version

    def sign_digest(self, digest: bytes) -> bytes:
        if len(digest) != 32:
            raise ValueError("digest must be 32 bytes")
        return self._key.sign(digest, ec.ECDSA(Prehashed(hashes.SHA256())))

    def public_key_pem(self) -> str:
        return (
            self._key.public_key()
            .public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
            .decode("ascii")
        )

    def key_version(self) -> str:
        return self._version
