"""Cloud KMS で署名する（設計書6章）。KMS には SHA-256 の digest を渡し、DER の署名を受け取る。"""

from __future__ import annotations

from ..core.crypto import Signer


class KmsSigner(Signer):
    def __init__(self, key_version: str, client=None):
        if not key_version:
            raise ValueError("KMS_KEY_VERSION is required")
        if client is None:
            from google.cloud import kms

            client = kms.KeyManagementServiceClient()
        self._client = client
        self._name = key_version
        # 公開鍵は起動時に1回だけ取る
        self._pem = client.get_public_key(request={"name": key_version}).pem

    def sign_digest(self, digest: bytes) -> bytes:
        import google_crc32c

        if len(digest) != 32:
            raise ValueError("digest must be 32 bytes")
        crc = google_crc32c.value(digest)
        resp = self._client.asymmetric_sign(
            request={"name": self._name, "digest": {"sha256": digest}, "digest_crc32c": crc}
        )
        if not resp.verified_digest_crc32c:
            raise RuntimeError("KMS did not verify the digest checksum")
        if google_crc32c.value(resp.signature) != int(resp.signature_crc32c):
            raise RuntimeError("KMS signature checksum mismatch")
        return bytes(resp.signature)

    def public_key_pem(self) -> str:
        return self._pem

    def key_version(self) -> str:
        return self._name
