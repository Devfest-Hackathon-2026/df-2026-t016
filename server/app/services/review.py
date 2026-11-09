"""公開する途中画像から、Gemini に見せる組を選ぶ。"""

from __future__ import annotations

import io
import json
from dataclasses import dataclass
from datetime import datetime
from functools import lru_cache

import cv2
import numpy as np
from PIL import Image, ImageOps

from ..core import canonical as c
from ..store.base import Store
from . import paths
from .whole import REASON_CHANGED, compare, load_params

MAX_PAIRS = 2
MAX_PAIR_CHECKS = 12


@dataclass(frozen=True)
class ReviewPair:
    before: bytes
    after: bytes
    start: datetime
    end: datetime
    max_gap_sec: float
    from_index: int
    to_index: int


def _crop(data: bytes, rect: dict) -> Image.Image | None:
    try:
        with Image.open(io.BytesIO(data)) as src:
            im = ImageOps.exif_transpose(src)
            w, h = im.size
            x, y, rw, rh = (rect[k] for k in ("x", "y", "w", "h"))
            x0, y0 = max(0, round(x * w)), max(0, round(y * h))
            x1, y1 = min(w, round((x + rw) * w)), min(h, round((y + rh) * h))
            if x1 - x0 < 20 or y1 - y0 < 20:
                return None
            return im.crop((x0 + 2, y0 + 2, x1 - 2, y1 - 2)).convert("RGB")
    except (OSError, ValueError):
        return None


def _jpeg(im: Image.Image) -> bytes:
    out = io.BytesIO()
    im.save(out, format="JPEG", quality=95)
    return out.getvalue()


def review_pairs(store: Store, bundle: dict, manifest: dict) -> list[ReviewPair]:
    whole = manifest.get("whole")
    if not whole or not whole["shown"] or not whole["links"]:
        return []

    sessions = manifest["sessions"] if manifest["v"] == 2 else [manifest]
    records = bundle["sessions"] if bundle["v"] == 2 else [bundle]
    times = []
    for record in records:
        receipts = [json.loads(c.b64d(ch["receipt"])) for ch in record["chunks"]]
        times.append({r["seq"]: datetime.fromisoformat(r["receivedAt"].replace("Z", "+00:00")) for r in receipts})

    items = whole["items"]
    candidates = []
    for link in whole["links"]:
        a, b = items[link["from"]], items[link["to"]]
        session = a.get("session", 0)
        if (session != b.get("session", 0) or not a["received"] or not b["received"]
                or not a.get("canvas") or not b.get("canvas")):
            continue
        start, end = times[session].get(a["seq"]), times[session].get(b["seq"])
        if start is None or end is None or end < start:
            continue
        kept = link["kept"] if link["kept"] is not None else 1.0
        candidates.append((link["reason"] != REASON_CHANGED, kept, link["from"], link["to"], start, end))

    @lru_cache(maxsize=4)
    def load(index: int) -> Image.Image | None:
        item = items[index]
        sid = sessions[item.get("session", 0)]["sid"]
        data = store.get(paths.image(sid, item["sha256"]))
        if data is None or c.sha256_hex(data) != item["sha256"]:
            return None
        return _crop(data, item["canvas"])

    pairs = []
    for check_reverse, _, i, j, start, end in sorted(candidates)[:MAX_PAIR_CHECKS]:
        before, after = load(i), load(j)
        if before is None or after is None:
            continue
        if check_reverse:
            # 後の画像を基準にすると、新しく現れた部分も比較に入る。
            a = cv2.cvtColor(np.asarray(before), cv2.COLOR_RGB2GRAY)
            b = cv2.cvtColor(np.asarray(after), cv2.COLOR_RGB2GRAY)
            if compare(b, a, load_params())["reason"] != REASON_CHANGED:
                continue
        a, b = items[i], items[j]
        gaps = sessions[a.get("session", 0)]["received"]["gaps"]
        max_gap_sec = max((g["sec"] for g in gaps if a["seq"] <= g["after"] < b["seq"]), default=0.0)
        pairs.append(ReviewPair(_jpeg(before), _jpeg(after), start, end, max_gap_sec, from_index=i, to_index=j))
        if len(pairs) == MAX_PAIRS:
            break
    return pairs
