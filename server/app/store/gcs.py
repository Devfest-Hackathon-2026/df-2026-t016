"""Cloud Storage 版。create_if_absent は if_generation_match=0 で書く。"""

from __future__ import annotations

from .base import Store


class GcsStore(Store):
    def __init__(self, bucket: str, client=None):
        if not bucket:
            raise ValueError("BUCKET is required")
        if client is None:
            from google.cloud import storage

            client = storage.Client()
        self._bucket = client.bucket(bucket)

    def put(self, path: str, data: bytes, content_type: str) -> None:
        self._bucket.blob(path).upload_from_string(data, content_type=content_type)

    def create_if_absent(self, path: str, data: bytes, content_type: str) -> bool:
        from google.api_core.exceptions import PreconditionFailed

        try:
            self._bucket.blob(path).upload_from_string(data, content_type=content_type, if_generation_match=0)
            return True
        except PreconditionFailed:
            return False

    def get(self, path: str) -> bytes | None:
        from google.api_core.exceptions import NotFound

        try:
            return self._bucket.blob(path).download_as_bytes()
        except NotFound:
            return None

    def exists(self, path: str) -> bool:
        return self._bucket.blob(path).exists()

    def list(self, prefix: str) -> list[str]:
        return sorted(b.name for b in self._bucket.list_blobs(prefix=prefix))

    def delete_prefix(self, prefix: str) -> int:
        blobs = list(self._bucket.list_blobs(prefix=prefix))
        for b in blobs:
            b.delete()
        return len(blobs)
