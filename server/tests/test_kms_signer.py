"""KmsSigner が digest を渡し、DER をそのまま返すこと（KMS の代わりに LocalSigner の鍵で答える）。"""

from __future__ import annotations

import hashlib
from types import SimpleNamespace

import google_crc32c
import pytest

from app.core.crypto import LocalSigner, verify_kms_sig
from app.signer.kms import KmsSigner

from conftest import kms_test_pem


class FakeKms:
    def __init__(self, tamper=False):
        self._local = LocalSigner(kms_test_pem())
        self.requests = []
        self.tamper = tamper

    def get_public_key(self, request):
        return SimpleNamespace(pem=self._local.public_key_pem())

    def asymmetric_sign(self, request):
        self.requests.append(request)
        sig = self._local.sign_digest(request["digest"]["sha256"])
        crc = google_crc32c.value(sig) + (1 if self.tamper else 0)
        return SimpleNamespace(signature=sig, signature_crc32c=crc, verified_digest_crc32c=True)


def test_kms_signer_signs_digest():
    fake = FakeKms()
    s = KmsSigner("projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1", client=fake)
    msg = b'{"v":1}'
    der = s.sign(msg)
    assert fake.requests[0]["digest"]["sha256"] == hashlib.sha256(msg).digest()
    assert verify_kms_sig(s.public_key_pem(), der, msg)
    assert s.key_version().endswith("/cryptoKeyVersions/1")


def test_kms_signer_rejects_bad_checksum():
    s = KmsSigner("v", client=FakeKms(tamper=True))
    with pytest.raises(RuntimeError):
        s.sign(b"x")
