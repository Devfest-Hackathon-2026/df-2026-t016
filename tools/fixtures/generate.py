"""検証ページ（T09）用の試験データを作る（tasks/T06）。

    python tools/fixtures/generate.py --out web/public/fixtures

- 署名は server/app/core を使う。鍵は shared/vectors/signing.json のテスト用の鍵（本番では使わない）
- ECDSA は RFC 6979（決定的）、乱数は種を固定しているので、同じ環境なら何度動かしても同じファイルになる
  （JPEG・PNG のバイト列は Pillow の版で変わりうるので、requirements.txt で版を固定している）
- expected.json は T09 の VerifyResult の形。問題（problems）の決め方は README.md に書いた
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import random
import shutil
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import Prehashed
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server"))

from app.core import canonical as c  # noqa: E402
from app.core.crypto import der_to_rs  # noqa: E402
from app.services.whole import judge_whole  # noqa: E402

import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location("whole_vectors_generate", ROOT / "tools/whole_vectors/generate.py")
wv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wv)  # 全体画像の画面は共通の試験画像と同じ作り方（T13）

VECTORS = json.loads((ROOT / "shared/vectors/signing.json").read_text(encoding="utf-8"))
DEVICE = ec.derive_private_key(int(VECTORS["deviceKey"]["privateHex"], 16), ec.SECP256R1())
DEVICE_PUB = VECTORS["deviceKey"]["publicX963"]
KMS = ec.derive_private_key(int(VECTORS["kmsKey"]["privateHex"], 16), ec.SECP256R1())
KMS_PUB_PEM = VECTORS["kmsKey"]["publicPem"]

RULES = "2026-11-05.1"
DECLARATION = "この作品は手描きで制作しました（AI による生成・補助は使っていません）。"
DECLARED_DETAIL = "背景の雲の形の案出しに画像生成 AI を使いました。\n線画・塗り・人物は手描きです。"
T0 = datetime(2026, 11, 5, 1, 0, 0, tzinfo=timezone.utc)
N_CHUNKS = 120
INTERVAL = 5  # 秒
FRAMES_PER_CHUNK = 10  # 2fps × 5秒
ACTIVE = [(8, 35), (44, 80), (88, 116)]  # 線を描いている区間（seq の範囲、両端を含む）

CANVAS = (1600, 1200)
SCREEN = (1024, 768)
BAR_TOP, BAR_LEFT = 56, 72

RULES_WHOLE = "2026-11-08.1"
WHOLE_SEQS = [10, 30, 50, 70, 90, 110]
WHOLE_LINES = [6, 10, 14, 18, 22, 26]  # それぞれの時点で描けている線の本数（最後は PNG と同じ絵）
WHOLE_QUALITY = 60
UNVERIFIED_WHOLE_HIDDEN = "途中の全体画像は公開されていないため、画像のハッシュは確かめていません"
UNVERIFIED_START = "開始画面がない"
UNVERIFIED_END = "終了画面がない"


# ---------------------------------------------------------------- 署名


def kms_sign(msg: bytes) -> bytes:
    digest = hashlib.sha256(msg).digest()
    return KMS.sign(digest, ec.ECDSA(Prehashed(hashes.SHA256()), deterministic_signing=True))


def device_sign(msg: bytes) -> bytes:
    return der_to_rs(DEVICE.sign(msg, ec.ECDSA(hashes.SHA256(), deterministic_signing=True)))


def fixed_id(prefix: str, name: str) -> str:
    raw = hashlib.sha256(f"fixture:{prefix}:{name}".encode()).digest()[:12]
    return prefix + base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def at(seconds: float) -> datetime:
    return T0 + timedelta(seconds=seconds)


# ---------------------------------------------------------------- 画像


def strokes(seed: int, n: int) -> list[list[tuple[int, int]]]:
    rnd = random.Random(seed)
    out = []
    for _ in range(n):
        x, y = rnd.randint(150, CANVAS[0] - 150), rnd.randint(150, CANVAS[1] - 150)
        pts = [(x, y)]
        for _ in range(rnd.randint(3, 7)):
            x = min(max(x + rnd.randint(-160, 160), 40), CANVAS[0] - 40)
            y = min(max(y + rnd.randint(-120, 120), 40), CANVAS[1] - 40)
            pts.append((x, y))
        out.append(pts)
    return out


def canvas(lines: list[list[tuple[int, int]]], color=(30, 30, 30)) -> Image.Image:
    im = Image.new("RGB", CANVAS, "white")
    d = ImageDraw.Draw(im)
    for pts in lines:
        d.line(pts, fill=color, width=9, joint="curve")
    return im


def screen(cv: Image.Image) -> Image.Image:
    """「アプリの画面風」: 上と左に灰色の帯、残りにキャンバスを縮小して置く。"""
    im = Image.new("RGB", SCREEN, (72, 72, 76))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, SCREEN[0], BAR_TOP], fill=(150, 150, 155))
    d.rectangle([0, BAR_TOP, BAR_LEFT, SCREEN[1]], fill=(120, 120, 125))
    area = (SCREEN[0] - BAR_LEFT - 24, SCREEN[1] - BAR_TOP - 24)
    scale = min(area[0] / CANVAS[0], area[1] / CANVAS[1])
    small = cv.resize((round(CANVAS[0] * scale), round(CANVAS[1] * scale)), Image.LANCZOS)
    im.paste(small, (BAR_LEFT + (area[0] - small.width) // 2 + 12, BAR_TOP + (area[1] - small.height) // 2 + 12))
    return im


def jpeg(im: Image.Image, quality=70) -> bytes:
    b = io.BytesIO()
    im.save(b, "JPEG", quality=quality, optimize=True)
    return b.getvalue()


def png(im: Image.Image) -> bytes:
    b = io.BytesIO()
    im.convert("L").save(b, "PNG", optimize=True)
    return b.getvalue()


def thumb(im: Image.Image) -> bytes:
    t = im.copy()
    t.thumbnail((1024, 1024), Image.LANCZOS)
    return jpeg(t, 75)


# ---------------------------------------------------------------- 記録


def is_active(seq: int) -> bool:
    return any(a <= seq <= b for a, b in ACTIVE)


def body_for(seq: int, rnd: random.Random) -> bytes:
    if is_active(seq):
        frames = [rnd.choice([0, 1, 2, 3, 4, 6, 9]) for _ in range(FRAMES_PER_CHUNK)]
        frames[0] = rnd.randint(1, 8)  # 区間の中は必ず変化あり
        tiles = bytearray(96)
        for _ in range(rnd.randint(2, 12)):
            i = rnd.randrange(768)
            tiles[i // 8] |= 1 << (7 - i % 8)
    else:
        frames = [0] * FRAMES_PER_CHUNK
        tiles = bytearray(96)
    return c.dumps_bytes({"v": 1, "frames": frames, "tiles": c.b64e(bytes(tiles))})


def whole_jpeg(cv, quality=WHOLE_QUALITY) -> bytes:
    import cv2
    import numpy as np

    g = wv.screen(np.asarray(cv)[:, :, ::-1].copy(), 0.8)
    ok, buf = cv2.imencode(".jpg", g, [cv2.IMWRITE_JPEG_QUALITY, quality])
    assert ok
    return buf.tobytes()


def build(name: str, *, aborted=False, gap_after: int | None = None, end_image=True, png_variant="same", match=None,
          whole: str | None = None):
    """正しい記録一式を作る。壊す操作は呼び出し側で後から行う。"""
    rnd = random.Random(f"fixture:{name}")
    work_id, sid = fixed_id("w_", name), fixed_id("s_", name)

    lines = strokes(seed=7, n=26)
    final_cv = canvas(lines)
    start_img = jpeg(screen(canvas([])))
    end_img = jpeg(screen(final_cv)) if end_image else None
    submitted_png = png(final_cv)

    if png_variant == "other":
        local_cv = canvas(strokes(seed=99, n=18), color=(20, 60, 140))
        local_png, thumb_img = png(local_cv), thumb(local_cv)
    elif png_variant == "similar":
        local_cv = canvas(lines + strokes(seed=11, n=3))
        local_png, thumb_img = png(local_cv), thumb(final_cv)
    else:
        local_png, thumb_img = submitted_png, thumb(final_cv)

    start_obj = {
        "v": 1, "type": "start", "sid": sid, "workId": work_id, "devicePubKey": DEVICE_PUB,
        "checked": ["startToken"], "issuedAt": c.iso_ms(T0),
    }
    start_bytes = c.dumps_bytes(start_obj)
    prev = c.sha256_hex(start_bytes)

    # 途中の全体画像（T13）。switched は4枚目（seq 70）だけ別の絵
    whole_imgs: dict[int, bytes] = {}
    if whole:
        for seq, k in zip(WHOLE_SEQS, WHOLE_LINES):
            cv = canvas(strokes(seed=99, n=18)) if whole == "switched" and seq == 70 else canvas(lines[:k])
            whole_imgs[seq] = whole_jpeg(cv)

    chunks, received = [], []
    shift = 0.0
    for seq in range(N_CHUNKS):
        final = (seq == N_CHUNKS - 1) and not aborted
        body = body_for(seq, rnd)
        header = {
            "v": 1, "sid": sid, "seq": seq, "prev": prev,
            "tStart": c.iso_ms(at(INTERVAL * seq)), "tEnd": c.iso_ms(at(INTERVAL * (seq + 1))),
            "body": c.sha256_hex(body), "bodyLen": len(body),
            "stats": {"fps": 2, "changedTiles": sum(bin(x).count("1") for x in c.b64d(json.loads(body)["tiles"])),
                      "resend": False, "memMB": 28 + seq % 5, "degraded": False,
                      # 【11/6】編集画面だった時間（ずっと編集画面）と、小さな変化があった時間（変化のあった処理1回 = 0.5秒）
                      "editorMs": INTERVAL * 1000,
                      "activeMs": 500 * sum(1 for f in json.loads(body)["frames"] if f > 0)},
            "final": final,
        }
        if seq == 0:
            header["images"] = {"start": c.sha256_hex(start_img)}
        if final and end_img is not None:
            header["images"] = {"end": c.sha256_hex(end_img)}
        if seq in whole_imgs:
            header["images"] = {"whole": c.sha256_hex(whole_imgs[seq])}
        hb = c.dumps_bytes(header)
        if gap_after is not None and seq == gap_after + 1:
            shift += 60.0
        t_recv = at(INTERVAL * (seq + 1) + shift + rnd.randint(40, 400) / 1000)
        rec = c.dumps_bytes({"v": 1, "type": "receipt", "sid": sid, "seq": seq, "header": c.sha256_hex(hb),
                             "receivedAt": c.iso_ms(t_recv)})
        chunks.append({
            "header": c.b64e(hb), "sig": c.b64e(device_sign(hb)), "body": c.b64e(body),
            "receipt": c.b64e(rec), "receiptSig": c.b64e(kms_sign(rec)),
        })
        received.append(t_recv)
        prev = c.sha256_hex(hb)

    gaps = []
    for i in range(1, len(received)):
        sec = (received[i] - received[i - 1]).total_seconds()
        if sec > 30:
            gaps.append({"after": i - 1, "sec": round(sec, 3)})

    whole_m = None
    if whole:
        items = [{"seq": q, "sha256": c.sha256_hex(b), "jpeg": b} for q, b in sorted(whole_imgs.items())]
        whole_m = judge_whole(items, submitted_png, shown=(whole != "hidden"))

    accepted = received[-1] + timedelta(minutes=2)
    match = match or {"result": "match", "score": 0.94, "reason": None}
    manifest = {
        "v": 1, "type": "manifest", "rules": RULES_WHOLE if whole else RULES, "workId": work_id,
        "title": f"試験データ（{name}）", "displayName": "試験の描き手", "sid": sid,
        "status": "aborted" if aborted else "completed",
        "chunks": {"count": len(chunks), "first": c.sha256_hex(c.b64d(chunks[0]["header"])),
                   "last": c.sha256_hex(c.b64d(chunks[-1]["header"]))},
        "received": {"first": c.iso_ms(received[0]), "last": c.iso_ms(received[-1]), "gaps": gaps},
        "images": {"start": c.sha256_hex(start_img), "end": c.sha256_hex(end_img) if end_img else None},
        "png": {"sha256": c.sha256_hex(submitted_png), "width": CANVAS[0], "height": CANVAS[1]},
        "match": match,
        "declaration": {"version": 1, "text": DECLARATION, "acceptedAt": c.iso_ms(accepted)},
        "rejected": 0,
        "createdAt": c.iso_ms(accepted + timedelta(seconds=3)),
    }
    if whole:
        manifest["whole"] = whole_m
    mb = c.dumps_bytes(manifest)
    bundle = {
        "v": 1,
        "manifest": {"bytes": c.b64e(mb), "sig": c.b64e(kms_sign(mb))},
        "start": {"bytes": c.b64e(start_bytes), "sig": c.b64e(kms_sign(start_bytes))},
        "chunks": chunks,
        "files": {"start": "start.jpg", "end": "end.jpg" if end_img else None, "png": "png.jpg"},
        "kms": {"publicKeyPem": KMS_PUB_PEM, "keyVersion": "fixture"},
        "explanation": None,
    }
    files = {"start.jpg": start_img, "png.jpg": thumb_img, "original.png": local_png}
    if end_img:
        files["end.jpg"] = end_img
    if whole and whole_m["shown"]:
        bundle["files"]["whole"] = [f"whole-{i}.jpg" for i in range(len(WHOLE_SEQS))]
        for i, q in enumerate(WHOLE_SEQS):
            files[f"whole-{i}.jpg"] = whole_imgs[q]
    elif whole:
        bundle["files"]["whole"] = None
    return bundle, manifest, files


# ---------------------------------------------------------------- 期待する結果（T09 の VerifyResult）


def expected(bundle: dict, manifest: dict, problems: list[dict], whole_status: dict[int, str] | None = None) -> dict:
    order = {"missing": 1, "signature": 2, "key": 2, "hash": 3, "image": 3, "chain": 4, "count": 5, "gap": 5}
    names = {1: "incomplete", 2: "signature_mismatch", 3: "content_mismatch", 4: "chain_broken", 5: "manifest_mismatch"}
    status = names[min(order[p["kind"]] for p in problems)] if problems else "ok"
    active = [sum(json.loads(c.b64d(ch["body"]))["frames"]) > 0 for ch in bundle["chunks"]]
    imgs = {k: ("none" if manifest["images"][k] is None else "ok") for k in ("start", "end")}
    unverified = []
    if manifest["images"]["start"] is None:
        unverified.append(UNVERIFIED_START)
    if manifest["images"]["end"] is None:
        unverified.append(UNVERIFIED_END)
    whole = None
    wm = manifest.get("whole")
    if wm:
        recs = [json.loads(c.b64d(ch["receipt"])) for ch in bundle["chunks"]]
        recv = {r["seq"]: r["receivedAt"] for r in recs}
        t0 = datetime.fromisoformat(manifest["received"]["first"].replace("Z", "+00:00"))

        def minutes(seq):  # 受信開始からの分（JS の Math.round と同じ丸め）
            ms = round((datetime.fromisoformat(recv[seq].replace("Z", "+00:00")) - t0).total_seconds() * 1000)
            return (ms + 30000) // 60000

        st = whole_status or {}
        items = []
        for it in wm["items"]:
            item_status = "hidden" if not wm["shown"] else ("none" if not it["received"] else st.get(it["seq"], "ok"))
            items.append({"seq": it["seq"], "minutes": minutes(it["seq"]), "status": item_status})
        whole = {"shown": wm["shown"], "items": items, "links": wm["links"], "toPng": wm["toPng"]}
        missing = sum(1 for it in wm["items"] if not it["received"])
        if missing:
            unverified.append(f"途中の全体画像のうち{missing}枚が届いていない")
        if not wm["shown"]:
            unverified.append(UNVERIFIED_WHOLE_HIDDEN)
    return {
        "integrity": {"status": status, "problems": problems},
        "reception": {"status": manifest["status"], "first": manifest["received"]["first"],
                      "last": manifest["received"]["last"], "gaps": manifest["received"]["gaps"],
                      "activeChunks": active,
                      "editorMs": sum(json.loads(c.b64d(ch["header"]))["stats"]["editorMs"] for ch in bundle["chunks"]),
                      "activeMs": sum(json.loads(c.b64d(ch["header"]))["stats"]["activeMs"] for ch in bundle["chunks"])},
        "images": imgs,
        "match": manifest["match"],
        "declaration": {"text": manifest["declaration"]["text"], "acceptedAt": manifest["declaration"]["acceptedAt"]},
        "unverified": unverified,
        "whole": whole,
    }


# ---------------------------------------------------------------- 【T14】記録が複数（確定記録・証拠一式 v:2）

MULTI_N = 30  # 1回の記録のチャンク数
# 記録ごとの (開始の時刻（T0 からの秒）, 全体画像を入れる seq と線の本数, 正常終了か, 受信の空きを入れる seq)
MULTI_RECORDS = [
    (0, [(9, 6), (29, 12)], True, None),
    (86400, [(0, 12), (20, 18)], False, 15),  # 次の日。異常終了（最終チャンクなし）、seq 15 の後に約65秒の空き
    (90000, [(10, 22), (29, 26)], True, None),  # 同じ日の夜。最後は PNG と同じ絵
]


def device_key_for(name: str, i: int):
    """記録ごとの端末の鍵（実機と同じく録画のたびに別の鍵。試験データでは決まった値から作る）。"""
    k = int.from_bytes(hashlib.sha256(f"fixture-device:{name}:{i}".encode()).digest(), "big") % (2**255) + 1
    return ec.derive_private_key(k, ec.SECP256R1())


def build_multi(name: str):
    """3回の記録を1つの作品にまとめた証拠一式（v:2）。壊す操作は呼び出し側で後から行う。"""
    rnd = random.Random(f"fixture:{name}")
    work_id = fixed_id("w_", name)
    lines = strokes(seed=7, n=26)
    final_cv = canvas(lines)
    start_img = jpeg(screen(canvas([])))
    end_img = jpeg(screen(final_cv))
    submitted_png = png(final_cv)
    files = {"start.jpg": start_img, "end.jpg": end_img, "png.jpg": thumb(final_cv), "original.png": submitted_png}

    sessions_b, sessions_m, whole_items = [], [], []
    for si, (offset, wholes, completed, gap_after) in enumerate(MULTI_RECORDS):
        key = device_key_for(name, si)
        pub = c.b64e(key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint))
        sid = fixed_id("s_", f"{name}:{si}")
        t_start = T0 + timedelta(seconds=offset)
        start_bytes = c.dumps_bytes({"v": 1, "type": "start", "sid": sid, "workId": work_id, "devicePubKey": pub,
                                     "checked": ["startToken"], "issuedAt": c.iso_ms(t_start)})
        prev = c.sha256_hex(start_bytes)
        wimgs = {seq: whole_jpeg(canvas(lines[:k])) for seq, k in wholes}
        chunks, received, shift = [], [], 0.0
        for seq in range(MULTI_N):
            final = completed and seq == MULTI_N - 1
            body = body_for(seq, rnd)
            frames = json.loads(body)["frames"]
            header = {
                "v": 1, "sid": sid, "seq": seq, "prev": prev,
                "tStart": c.iso_ms(t_start + timedelta(seconds=INTERVAL * seq)),
                "tEnd": c.iso_ms(t_start + timedelta(seconds=INTERVAL * (seq + 1))),
                "body": c.sha256_hex(body), "bodyLen": len(body),
                "stats": {"fps": 2, "changedTiles": sum(bin(x).count("1") for x in c.b64d(json.loads(body)["tiles"])),
                          "resend": False, "memMB": 28, "degraded": False,
                          "editorMs": INTERVAL * 1000, "activeMs": 500 * sum(1 for f in frames if f > 0)},
                "final": final,
            }
            images = {}
            if si == 0 and seq == 0:
                images["start"] = c.sha256_hex(start_img)
            if seq in wimgs:
                images["whole"] = c.sha256_hex(wimgs[seq])
            if final and si == len(MULTI_RECORDS) - 1:
                images["end"] = c.sha256_hex(end_img)
            if images:
                header["images"] = images
            hb = c.dumps_bytes(header)
            if gap_after is not None and seq == gap_after + 1:
                shift += 60.0
            t_recv = t_start + timedelta(seconds=INTERVAL * (seq + 1) + shift + rnd.randint(40, 400) / 1000)
            rec = c.dumps_bytes({"v": 1, "type": "receipt", "sid": sid, "seq": seq, "header": c.sha256_hex(hb),
                                 "receivedAt": c.iso_ms(t_recv)})
            sig = der_to_rs(key.sign(hb, ec.ECDSA(hashes.SHA256(), deterministic_signing=True)))
            chunks.append({"header": c.b64e(hb), "sig": c.b64e(sig), "body": c.b64e(body),
                           "receipt": c.b64e(rec), "receiptSig": c.b64e(kms_sign(rec))})
            received.append(t_recv)
            prev = c.sha256_hex(hb)
        gaps = []
        for i in range(1, len(received)):
            sec = (received[i] - received[i - 1]).total_seconds()
            if sec > 30:
                gaps.append({"after": i - 1, "sec": round(sec, 3)})
        sessions_b.append({"start": {"bytes": c.b64e(start_bytes), "sig": c.b64e(kms_sign(start_bytes))}, "chunks": chunks})
        sessions_m.append({
            "sid": sid, "status": "completed" if completed else "aborted",
            "chunks": {"count": len(chunks), "first": c.sha256_hex(c.b64d(chunks[0]["header"])),
                       "last": c.sha256_hex(c.b64d(chunks[-1]["header"]))},
            "received": {"first": c.iso_ms(received[0]), "last": c.iso_ms(received[-1]), "gaps": gaps},
        })
        for seq, _ in wholes:
            whole_items.append({"session": si, "seq": seq, "sha256": c.sha256_hex(wimgs[seq]), "jpeg": wimgs[seq]})

    whole_m = judge_whole(whole_items, submitted_png, shown=True)
    last_recv = datetime.fromisoformat(sessions_m[-1]["received"]["last"].replace("Z", "+00:00"))
    accepted = last_recv + timedelta(minutes=2)
    manifest = {
        "v": 2, "type": "manifest", "rules": RULES_WHOLE, "workId": work_id,
        "title": f"試験データ（{name}）", "displayName": "試験の描き手",
        "sessions": sessions_m,
        "images": {"start": c.sha256_hex(start_img), "end": c.sha256_hex(end_img)},
        "png": {"sha256": c.sha256_hex(submitted_png), "width": CANVAS[0], "height": CANVAS[1]},
        "match": {"result": "match", "score": 0.94, "reason": None},
        "declaration": (
            # 【11/8】作者の申告の版2（AI の使い方を選び、詳細を書く）
            {"version": 2, "aiUse": "partial", "text": "この作品は AI を部分的に使用しています。",
             "detail": DECLARED_DETAIL, "acceptedAt": c.iso_ms(accepted)}
            if name == "multi_declared"
            else {"version": 1, "text": DECLARATION, "acceptedAt": c.iso_ms(accepted)}
        ),
        "whole": whole_m,
        "rejected": 0,
        "createdAt": c.iso_ms(accepted + timedelta(seconds=3)),
    }
    mb = c.dumps_bytes(manifest)
    bundle = {
        "v": 2,
        "manifest": {"bytes": c.b64e(mb), "sig": c.b64e(kms_sign(mb))},
        "sessions": sessions_b,
        "files": {"start": "start.jpg", "end": "end.jpg", "png": "png.jpg",
                  "whole": [f"whole-{i}.jpg" for i in range(len(whole_items))]},
        "kms": {"publicKeyPem": KMS_PUB_PEM, "keyVersion": "fixture"},
        "explanation": None,
    }
    for i, it in enumerate(whole_items):
        files[f"whole-{i}.jpg"] = it["jpeg"]
    return bundle, manifest, files


def expected_multi(bundle: dict, manifest: dict, problems: list[dict]) -> dict:
    """v:2 の期待する結果（web/src/verify/verify.ts の v:2 の形）。"""
    order = {"missing": 1, "signature": 2, "key": 2, "hash": 3, "image": 3, "chain": 4, "count": 5, "gap": 5}
    names = {1: "incomplete", 2: "signature_mismatch", 3: "content_mismatch", 4: "chain_broken", 5: "manifest_mismatch"}
    status = names[min(order[p["kind"]] for p in problems)] if problems else "ok"
    per = []
    recv = []
    for bs, ms in zip(bundle["sessions"], manifest["sessions"]):
        heads = [json.loads(c.b64d(ch["header"])) for ch in bs["chunks"]]
        per.append({
            "sid": ms["sid"], "status": ms["status"], "first": ms["received"]["first"], "last": ms["received"]["last"],
            "gaps": ms["received"]["gaps"],
            "activeChunks": [sum(json.loads(c.b64d(ch["body"]))["frames"]) > 0 for ch in bs["chunks"]],
            "editorMs": sum(h["stats"]["editorMs"] for h in heads),
            "activeMs": sum(h["stats"]["activeMs"] for h in heads),
        })
        recv.append({json.loads(c.b64d(ch["receipt"]))["seq"]: json.loads(c.b64d(ch["receipt"]))["receivedAt"] for ch in bs["chunks"]})
    wm = manifest["whole"]

    def minutes(session, seq):
        t0 = datetime.fromisoformat(manifest["sessions"][session]["received"]["first"].replace("Z", "+00:00"))
        ms = round((datetime.fromisoformat(recv[session][seq].replace("Z", "+00:00")) - t0).total_seconds() * 1000)
        return (ms + 30000) // 60000

    whole = {
        "shown": wm["shown"],
        "items": [{"session": it["session"], "seq": it["seq"], "minutes": minutes(it["session"], it["seq"]), "status": "ok"} for it in wm["items"]],
        "links": wm["links"], "toPng": wm["toPng"],
    }
    return {
        "integrity": {"status": status, "problems": problems},
        "reception": {
            "status": "completed" if all(x["status"] == "completed" for x in manifest["sessions"]) else "aborted",
            "first": manifest["sessions"][0]["received"]["first"], "last": manifest["sessions"][-1]["received"]["last"],
            "gaps": [{"session": i, **g} for i, x in enumerate(manifest["sessions"]) for g in x["received"]["gaps"]],
            "activeChunks": [a for x in per for a in x["activeChunks"]],
            "editorMs": sum(x["editorMs"] for x in per), "activeMs": sum(x["activeMs"] for x in per),
            "sessions": per,
        },
        "images": {"start": "ok", "end": "ok"},
        "match": manifest["match"],
        "declaration": {"text": manifest["declaration"]["text"], "acceptedAt": manifest["declaration"]["acceptedAt"]},
        "unverified": [],
        "whole": whole,
    }


# ---------------------------------------------------------------- 10種類


def tamper_header(ch: dict) -> None:
    hb = bytearray(c.b64d(ch["header"]))
    i = hb.index(b'"tEnd":"') + len(b'"tEnd":"2026-11-05T01:0')
    hb[i] = ord("9") if hb[i] != ord("9") else ord("8")  # 分の1桁目を変える（JSON の形は保つ）
    ch["header"] = c.b64e(bytes(hb))


def tamper_body(ch: dict) -> None:
    bb = bytearray(c.b64d(ch["body"]))
    start = bb.index(b'"frames":[') + len(b'"frames":[')
    for i in range(start, bb.index(b"]", start)):
        if ord("1") <= bb[i] <= ord("8"):
            bb[i] += 1  # 数字を1文字だけ別の数字に（長さは同じ）
            break
    else:
        raise RuntimeError("no digit to change")
    ch["body"] = c.b64e(bytes(bb))


CASES = {
    "normal": "正常。整合性は一致、正常終了、外観は一致",
    "gap": "seq 60 と 61 の受信時刻の間が約65秒あく。受信の空きが1か所（理由は書かない）",
    "missing_chunk": "seq 40 のチャンクを抜いた。seq 41 でつながりが切れ、件数も合わない",
    "tampered_header": "seq 30 のヘッダの1バイトを変えた（署名はそのまま）。署名の不一致",
    "tampered_body": "seq 50 の本文の frames の数字を1文字変えた（ヘッダと署名はそのまま）。内容の不一致",
    "truncated": "最後の2件を消した（確定記録の件数・末尾はそのまま）。確定記録との不一致",
    "aborted": "最終チャンクがない異常終了。終了画面もなく、外観は未確認",
    "other_png": "手元の PNG（original.png）が別の絵。確定記録の PNG のハッシュは元の絵。外観は不一致",
    "similar_png": "手元の PNG に数本の線を足した。外観は一致だが、ハッシュは不一致",
    "no_end_image": "終了画面がない。整合性は一致、外観は未確認",
    "whole_normal": "normal に、描き進めた全体画像を6枚（seq 10・30・50・70・90・110）入れた。つながりはすべて確認、PNG へも確認",
    "whole_switched": "whole_normal の4枚目（seq 70）だけ別の絵。その前後の2か所が確認できず（別の絵とは出さない）。整合性は一致",
    "whole_tampered": "whole_normal の whole-2.jpg を、見た目が同じで中身の違う画像（品質を変えて保存し直した）に差し替えた。内容の不一致",
    "whole_hidden": "whole_normal を載せない設定にした（files.whole は null、画像は置かない）。整合性は一致",
    "multi_session": "【T14】3回の記録（2回目は次の日で異常終了・受信の空き1か所、3回目は同じ日の夜）。証拠一式 v:2。整合性は一致、全体画像は記録をまたいでつながりを確認",
    "multi_declared": "【11/8】multi_session と同じ記録で、作者の申告が版2（AI を部分的に使用、詳細あり）。整合性は一致",
    "multi_tampered": "multi_session の2回目の記録の seq 12 のヘッダの1バイトを変えた。署名の不一致（2回目の記録のチャンク12）",
}


def make(name: str):
    unverified_match = {"result": "unverified", "score": None, "reason": "終了画面がないため照合していません"}
    if name == "gap":
        bundle, manifest, files = build(name, gap_after=60)
        problems = []
    elif name == "missing_chunk":
        bundle, manifest, files = build(name)
        del bundle["chunks"][40]
        problems = [
            {"seq": 41, "kind": "chain", "detail": "前のチャンクとつながらない（seq 40 がない）"},
            {"kind": "count", "detail": "件数が確定記録と合わない（119件、確定記録は120件）"},
        ]
    elif name == "tampered_header":
        bundle, manifest, files = build(name)
        tamper_header(bundle["chunks"][30])
        problems = [
            {"seq": 30, "kind": "signature", "detail": "端末署名が合わない"},
            {"seq": 31, "kind": "chain", "detail": "前のチャンクのヘッダとつながらない"},
        ]
    elif name == "tampered_body":
        bundle, manifest, files = build(name)
        tamper_body(bundle["chunks"][50])
        problems = [{"seq": 50, "kind": "hash", "detail": "本文のハッシュがヘッダと合わない"}]
    elif name == "truncated":
        bundle, manifest, files = build(name)
        del bundle["chunks"][-2:]
        problems = [{"kind": "count", "detail": "件数と末尾が確定記録と合わない（118件、確定記録は120件）"}]
    elif name == "aborted":
        bundle, manifest, files = build(name, aborted=True, end_image=False, match=unverified_match)
        problems = []
    elif name == "other_png":
        bundle, manifest, files = build(
            name, png_variant="other",
            match={"result": "mismatch", "score": 0.11, "reason": "提出画像が終了画面と外観で一致しません"},
        )
        problems = []
    elif name == "similar_png":
        bundle, manifest, files = build(name, png_variant="similar")
        problems = []
    elif name == "no_end_image":
        bundle, manifest, files = build(name, end_image=False, match=unverified_match)
        problems = []
    elif name.startswith("multi_"):
        bundle, manifest, files = build_multi(name)
        links = [l["result"] for l in manifest["whole"]["links"]] + [manifest["whole"]["toPng"]["result"]]
        if links != ["linked"] * 6:
            raise SystemExit(f"{name}: links {links}")
        problems = []
        if name == "multi_tampered":
            tamper_header(bundle["sessions"][1]["chunks"][12])
            problems = [
                {"session": 1, "seq": 12, "kind": "signature", "detail": "端末署名が合わない"},
                {"session": 1, "seq": 13, "kind": "chain", "detail": "前のチャンクのヘッダとつながらない"},
            ]
        return bundle, expected_multi(bundle, manifest, problems), files
    elif name.startswith("whole_"):
        mode = {"whole_normal": "normal", "whole_switched": "switched", "whole_tampered": "normal", "whole_hidden": "hidden"}[name]
        bundle, manifest, files = build(name, whole=mode)
        problems, wst = [], None
        links = [l["result"] for l in manifest["whole"]["links"]] + [manifest["whole"]["toPng"]["result"]]
        want = ["linked"] * 6
        if mode == "switched":
            want[2] = want[3] = "unconfirmed"
        if links != want:
            raise SystemExit(f"{name}: links {links} != {want}")
        if name == "whole_tampered":
            import cv2
            import numpy as np

            g = cv2.imdecode(np.frombuffer(files["whole-2.jpg"], np.uint8), cv2.IMREAD_GRAYSCALE)
            files["whole-2.jpg"] = cv2.imencode(".jpg", g, [cv2.IMWRITE_JPEG_QUALITY, 85])[1].tobytes()
            problems = [{"seq": 50, "kind": "image", "detail": "全体画像のハッシュが合わない"}]
            wst = {50: "mismatch"}
        return bundle, expected(bundle, manifest, problems, wst), files
    else:
        bundle, manifest, files = build(name)
        problems = []
    return bundle, expected(bundle, manifest, problems), files


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "web/public/fixtures"))
    ap.add_argument("--only", nargs="*", help="この名前だけを作り直す（ほかのフォルダと index.json の項目はそのまま）")
    args = ap.parse_args()
    out = Path(args.out)
    if args.only:
        return write_only(out, args.only)
    # フォルダは消さず、中のファイルだけを入れ替える（OneDrive などがフォルダをつかんでいても動くように）
    out.mkdir(parents=True, exist_ok=True)
    for p in out.iterdir():
        if p.is_dir():
            for f in p.iterdir():
                f.unlink()
            if p.name not in CASES:
                shutil.rmtree(p, ignore_errors=True)
        elif p.name != ".gitkeep":
            p.unlink()

    index = []
    for name, note in CASES.items():
        bundle, exp, files = make(name)
        d = out / name
        d.mkdir(exist_ok=True)
        (d / "bundle.json").write_text(json.dumps(bundle, ensure_ascii=False, indent=1) + "\n", encoding="utf-8", newline="\n")
        (d / "expected.json").write_text(json.dumps(exp, ensure_ascii=False, indent=1) + "\n", encoding="utf-8", newline="\n")
        for fn, data in files.items():
            (d / fn).write_bytes(data)
        index.append({"name": name, "description": note, "integrity": exp["integrity"]["status"]})
    (out / "index.json").write_text(json.dumps({"fixtures": index}, ensure_ascii=False, indent=1) + "\n",
                                    encoding="utf-8", newline="\n")
    total = sum(p.stat().st_size for p in out.rglob("*") if p.is_file())
    print(f"wrote {len(index)} fixtures to {out} ({total / 1e6:.2f} MB)")


def write_only(out: Path, names: list[str]) -> None:
    """指定した試験データだけを作り直す（JPEG・PNG は Pillow の版で変わりうるので、ほかは触らない）。"""
    index_path = out / "index.json"
    old = {x["name"]: x for x in json.loads(index_path.read_text(encoding="utf-8"))["fixtures"]} if index_path.exists() else {}
    for name in names:
        if name not in CASES:
            raise SystemExit(f"unknown fixture {name}")
        bundle, exp, files = make(name)
        d = out / name
        d.mkdir(parents=True, exist_ok=True)
        for f in d.iterdir():
            f.unlink()
        (d / "bundle.json").write_text(json.dumps(bundle, ensure_ascii=False, indent=1) + "\n", encoding="utf-8", newline="\n")
        (d / "expected.json").write_text(json.dumps(exp, ensure_ascii=False, indent=1) + "\n", encoding="utf-8", newline="\n")
        for fn, data in files.items():
            (d / fn).write_bytes(data)
        old[name] = {"name": name, "description": CASES[name], "integrity": exp["integrity"]["status"]}
    index = [old[n] for n in CASES if n in old]
    index_path.write_text(json.dumps({"fixtures": index}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {names} ({len(index)} fixtures in index.json)")


if __name__ == "__main__":
    main()
