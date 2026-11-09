"""PNG の受け取り（#9）。ハッシュ名で保存し、古いものは作品の削除まで消さない。"""

from __future__ import annotations

import io

from PIL import Image

from ..core import canonical as c
from ..deps import Deps
from ..errors import ApiError
from . import works as works_svc

MAX_PNG = 30 * 1024 * 1024
THUMB_LONG = 1024


def png_path(work_id: str, sha: str) -> str:
    return f"works/{work_id}/png/{sha}.png"


def thumb_path(work_id: str, sha: str) -> str:
    return f"works/{work_id}/png/{sha}.thumb.jpg"


def check_open(deps: Deps, uid: str, work_id: str) -> dict:
    """受け取る前に確かめる: 所有者で、確定の途中・確定済みでないこと。"""
    w = works_svc.get_owned(deps, uid, work_id)
    if w.get("status") in ("finalizing", "finalized"):
        raise ApiError("ALREADY_FINALIZED", "work is finalized")
    return w


def make_thumb(im: Image.Image) -> bytes:
    if im.mode in ("RGBA", "LA", "P"):
        rgba = im.convert("RGBA")
        bg = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
        im = Image.alpha_composite(bg, rgba)
    im = im.convert("RGB")
    im.thumbnail((THUMB_LONG, THUMB_LONG), Image.LANCZOS)
    b = io.BytesIO()
    im.save(b, "JPEG", quality=85, optimize=True)
    return b.getvalue()


def receive(deps: Deps, uid: str, work_id: str, content_type: str, data: bytes) -> dict:
    check_open(deps, uid, work_id)
    if len(data) > MAX_PNG:
        raise ApiError("TOO_LARGE", "PNG exceeds 30MB")
    if content_type.split(";")[0].strip().lower() != "image/png":
        raise ApiError("UNSUPPORTED_MEDIA", "Content-Type must be image/png")
    try:
        im = Image.open(io.BytesIO(data))
        if im.format != "PNG":
            raise ValueError
        im.load()
    except Exception:
        raise ApiError("UNSUPPORTED_MEDIA", "not a PNG image")
    sha = c.sha256_hex(data)
    deps.store.create_if_absent(png_path(work_id, sha), data, "image/png")
    if not deps.store.exists(thumb_path(work_id, sha)):
        deps.store.create_if_absent(thumb_path(work_id, sha), make_thumb(im), "image/jpeg")
    png = {"sha256": sha, "width": im.width, "height": im.height}
    deps.repo.set_png(work_id, png)  # 中で確定の途中でないことを確かめ直す
    return png
