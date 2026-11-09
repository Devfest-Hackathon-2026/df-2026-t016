"""確定（#10、設計書9章、tasks/T08）。

A. 固定する（トランザクション）: 使う値をすべて決めて保存し、作品とセッションを finalizing にする
B. 作る（やり直してよい）: A で決めた値だけを使って照合・確定記録・証拠一式・注意点を作る
C. 公開する（トランザクション）: 公開 ID を有効にし、作品を finalized にする
途中で止まっても、同じ要求が重なっても、呼び直せば同じ結果になる。
"""

from __future__ import annotations

import json
import logging
import re

from ..core import canonical as c
from ..core import text
from ..deps import Deps
from ..errors import ApiError
from ..repo.base import REVIEW_VERSION, SESSIONS, review_explanation, work_sids
from . import paths
from .match import match_images
from .whole import judge_whole
from .png import png_path
from .review import review_pairs

log = logging.getLogger("trace-api")

RULES = "2026-11-08.1"  # T13 で全体画像を入れた版（共通仕様2章）
DECLARATION_VERSION = 1
DECLARATION_TEXT = "この作品は手描きで制作しました（AI による生成・補助は使っていません）。"
# 【11/8】版2: AI の使い方を3つから選び、詳細は任意で書く（共通仕様2章）
DECLARATION_TEXTS = {
    "none": "この作品は AI を使用していません。",
    "partial": "この作品は AI を部分的に使用しています。",
    "major": "この作品は AI を大部分で使用しています。",
}
MAX_DETAIL = 400
GAP_SEC = 30


def bundle_path(work_id: str) -> str:
    return f"works/{work_id}/bundle.json"


def explanation_path(work_id: str) -> str:
    return f"works/{work_id}/review-v{REVIEW_VERSION}/explanation.json"


def _json(deps: Deps, path: str) -> dict | None:
    raw = deps.store.get(path)
    return json.loads(raw) if raw is not None else None


def manifest_of(bundle: dict) -> dict:
    return json.loads(c.b64d(bundle["manifest"]["bytes"]))


def _result(work: dict, manifest: dict) -> dict:
    ex = review_explanation(work)
    return {
        "publicId": work["publicId"],
        "manifest": manifest,
        "explanation": {"text": ex["text"], "included": bool(ex.get("included"))} if ex else None,
    }


# ---------------------------------------------------------------- 入口


def _clean_detail(s: str) -> str:
    """改行は \\n にそろえ、改行とタブ以外の制御文字と書式文字を消して、前後の空白を取る（core/text.py）。"""
    return text.clean(s, multiline=True)


def make_declaration(declaration_accepted: bool, declaration: dict | None, accepted_at: str) -> dict:
    """確定記録に入れる作者の申告。【11/8】declaration（版2）があればそれを、無ければ版1（チェック）を使う。"""
    if declaration is not None:
        ai_use = declaration.get("aiUse")
        if ai_use not in DECLARATION_TEXTS:
            raise ApiError("BAD_REQUEST", "declaration.aiUse must be none, partial or major")
        detail = _clean_detail(str(declaration.get("detail") or ""))
        if len(detail) > MAX_DETAIL:
            raise ApiError("BAD_REQUEST", f"declaration.detail must be at most {MAX_DETAIL} characters")
        return {"version": 2, "aiUse": ai_use, "text": DECLARATION_TEXTS[ai_use], "detail": detail, "acceptedAt": accepted_at}
    if declaration_accepted is True:
        return {"version": DECLARATION_VERSION, "text": DECLARATION_TEXT, "acceptedAt": accepted_at}
    raise ApiError("DECLARATION_REQUIRED", "作者の申告を選んでください")


def finalize(
    deps: Deps,
    uid: str,
    work_id: str,
    declaration_accepted: bool,
    use_end_image: bool = True,
    show_whole: bool = True,
    declaration: dict | None = None,
) -> dict:
    now = deps.clock()
    proposal = {
        "publicId": c.new_public_id(),
        "createdAt": c.iso_ms(now),
        "acceptedAt": c.iso_ms(now),
        # 【11/8】申告も段階A で固定する（確定の途中で呼び直したときは、固定した申告を使う）
        "declaration": make_declaration(declaration_accepted, declaration, c.iso_ms(now)),
        "useEndImage": bool(use_end_image),
        "showWhole": bool(show_whole),
    }
    state, work = deps.repo.finalize_fix(work_id, uid, now, proposal)  # 段階A
    if state == "finalized":
        bundle = _json(deps, bundle_path(work_id))
        assert bundle is not None
        return _result(work, manifest_of(bundle))
    f = work["finalize"]
    bundle = build(deps, work_id, work, f)  # 段階B
    ex = _json(deps, explanation_path(work_id))
    manifest = manifest_of(bundle)
    explanation = {**ex, "included": True} if ex else None
    work = deps.repo.finalize_publish(work_id, f["publicId"], c.iso_ms(deps.clock()), manifest["match"], explanation)  # 段階C
    return _result(work, manifest)


# ---------------------------------------------------------------- 段階B


def build(deps: Deps, work_id: str, work: dict, f: dict) -> dict:
    bundle = _json(deps, bundle_path(work_id))
    if bundle is None:
        bundle = _make_bundle(deps, work_id, work, f)
    _ensure_explanation(deps, work_id, bundle)
    return bundle


def fixed_sessions(work: dict, f: dict) -> list[dict]:
    """段階A で固定した記録（開始した順）。【T14】T14 より前に段階A を済ませた作品は1つにして返す。"""
    if "sessions" in f:
        return f["sessions"]
    return [{"sid": work["sid"], "result": f["sessionResult"], "range": f["range"], "rejected": int(f.get("rejected", 0))}]


def _read_session(deps: Deps, fs: dict) -> dict:
    """1つの記録の開始証・チャンク・受領証を、固定した範囲だけ読む（1件でも欠けたら止める。finalizing のまま再実行できる）。"""
    sid, rng = fs["sid"], fs["range"]
    start = _json(deps, paths.start(sid))
    if start is None:
        raise RuntimeError(f"start.json of {sid} is missing")
    chunks, headers, receipts = [], [], []
    for seq in range(rng["lastSeq"] + 1):
        ch = _json(deps, paths.chunk(sid, seq))
        rec = _json(deps, paths.receipt(sid, seq))
        if ch is None or rec is None:
            raise RuntimeError(f"chunk or receipt {sid}/{seq} is missing")
        hb = c.b64d(ch["header"])
        chunks.append({"header": ch["header"], "sig": ch["sig"], "body": ch["body"], "receipt": rec["receipt"], "receiptSig": rec["sig"]})
        headers.append((c.sha256_hex(hb), json.loads(hb)))
        receipts.append(json.loads(c.b64d(rec["receipt"])))
    if headers and headers[-1][0] != rng["lastHash"]:
        raise RuntimeError(f"last header hash of {sid} does not match the fixed range")
    times = [r["receivedAt"] for r in receipts]
    gaps = []
    for i in range(1, len(receipts)):
        sec = (_t(times[i]) - _t(times[i - 1])).total_seconds()
        if sec > GAP_SEC:
            gaps.append({"after": receipts[i - 1]["seq"], "sec": round(sec, 3)})
    return {
        "sid": sid,
        "start": start,
        "chunks": chunks,
        "headers": headers,
        "manifest": {
            "sid": sid,
            "status": fs["result"],
            "chunks": {
                "count": rng["count"],
                "first": headers[0][0] if headers else None,
                "last": headers[-1][0] if headers else None,
            },
            "received": {"first": times[0] if times else None, "last": times[-1] if times else None, "gaps": gaps},
        },
    }


def _make_bundle(deps: Deps, work_id: str, work: dict, f: dict) -> dict:
    # 2〜3. 記録ごとにチャンクと受領証を読み、件数・受信を出す（【T14】開始した順にすべて）
    fixed = fixed_sessions(work, f)
    ss = [_read_session(deps, x) for x in fixed]

    # 画像: 開始画面は1回目の記録、終了画面は最後の記録（最終チャンクがあるときだけ）
    def image_if_stored(sid: str, sha: str | None) -> str | None:
        return sha if sha and deps.store.exists(paths.image(sid, sha)) else None

    first, last = ss[0], ss[-1]
    start_sha = next((h["images"]["start"] for _, h in first["headers"] if "start" in (h.get("images") or {})), None)
    last_header = last["headers"][-1][1] if last["headers"] else {}
    end_sha = (last_header.get("images") or {}).get("end") if last_header.get("final") else None
    images = {"start": image_if_stored(first["sid"], start_sha), "end": image_if_stored(last["sid"], end_sha)}

    # 4. 外観照合（A で固定した PNG だけを使う）
    png = f.get("png")
    if not f.get("useEndImage", True):
        match = {"result": "unverified", "score": None, "reason": "作者が終了画面を照合に使わないことを選んだ"}
    else:
        end_bytes = deps.store.get(paths.image(last["sid"], images["end"])) if images["end"] else None
        png_bytes = deps.store.get(png_path(work_id, png["sha256"])) if png else None
        s = deps.settings
        match = match_images(end_bytes, png_bytes, threshold=s.match_threshold, min_screen=s.match_min_screen, min_png=s.match_min_png)

    # 全体画像（T13）: 記録の順・seq の順に、ヘッダの images.whole を集める（【T14】記録をまたぐ隣どうしも比べる）
    whole_items = []
    for i, x in enumerate(ss):
        for _, h in x["headers"]:
            sha = (h.get("images") or {}).get("whole")
            if sha:
                whole_items.append({"session": i, "seq": h["seq"], "sha256": sha, "jpeg": deps.store.get(paths.image(x["sid"], sha))})
    png_for_whole = deps.store.get(png_path(work_id, png["sha256"])) if png else None
    whole = judge_whole(whole_items, png_for_whole, f.get("showWhole", True))

    # 5. 確定記録（【T14】v:2。記録ごとの項目は sessions に入れる）
    manifest = {
        "v": 2,
        "type": "manifest",
        "rules": RULES,
        "workId": work_id,
        "title": work["title"],
        "displayName": work["displayName"],
        "sessions": [x["manifest"] for x in ss],
        "images": images,
        "png": png,
        "match": match,
        # 【11/8】段階A で固定した申告。それより前に固定した作品は版1
        "declaration": f.get("declaration") or {"version": DECLARATION_VERSION, "text": DECLARATION_TEXT, "acceptedAt": f["acceptedAt"]},
        "whole": whole,
        "rejected": sum(int(x.get("rejected", 0)) for x in fixed),
        "createdAt": f["createdAt"],
    }
    mb = c.dumps_bytes(manifest)

    # 6. 証拠一式（無いときだけ作る。重なったら先に保存されたものを使う）
    bundle = {
        "v": 2,
        "manifest": {"bytes": c.b64e(mb), "sig": c.b64e(deps.signer.sign(mb))},
        "sessions": [{"start": {"bytes": x["start"]["startCert"], "sig": x["start"]["sig"]}, "chunks": x["chunks"]} for x in ss],
        "files": {
            "start": "start.jpg" if images["start"] else None,
            "end": "end.jpg" if images["end"] else None,
            "png": "png.jpg" if png else None,
            "whole": (
                [f"whole-{i}.jpg" if it["received"] else None for i, it in enumerate(whole["items"])]
                if whole and whole["shown"]
                else None
            ),
        },
        "kms": {"publicKeyPem": deps.signer.public_key_pem(), "keyVersion": deps.signer.key_version()},
        "explanation": None,
    }
    if not deps.store.create_if_absent(bundle_path(work_id), c.dumps_bytes(bundle), "application/json"):
        stored = _json(deps, bundle_path(work_id))
        assert stored is not None
        return stored
    return bundle


def _ensure_explanation(deps: Deps, work_id: str, bundle: dict) -> None:
    # 7. 注意点（失敗しても確定は続ける）
    if deps.explainer is None or deps.store.exists(explanation_path(work_id)):
        return
    try:
        ex = deps.explainer(review_pairs(deps.store, bundle, manifest_of(bundle)))
        doc = {"text": str(ex["text"]), "model": str(ex["model"])}
        if ex.get("links"):
            doc["links"] = ex["links"]
    except Exception:
        log.warning("explanation failed", exc_info=True)
        return
    deps.store.create_if_absent(explanation_path(work_id), c.dumps_bytes(doc), "application/json")


def _t(s: str):
    from datetime import datetime

    return datetime.fromisoformat(s.replace("Z", "+00:00"))


# ---------------------------------------------------------------- 公開（#13・#14）


def public_bundle(deps: Deps, public_id: str) -> tuple[dict, dict]:
    """(作品, 証拠一式) を返す。注意点は載せる設定のときだけ差し込む。"""
    from ..repo.base import PUBLICS, WORKS

    pub = deps.repo.get(PUBLICS, public_id)
    w = deps.repo.get(WORKS, pub["workId"]) if pub else None
    if w is None or w.get("status") != "finalized":
        raise ApiError("NOT_FOUND", "記録が見つからないか、削除されました")
    bundle = _json(deps, bundle_path(pub["workId"]))
    if bundle is None:
        raise ApiError("NOT_FOUND", "bundle not found")
    ex = review_explanation(w, include_empty=True)
    bundle["explanation"] = {"text": ex["text"], "model": ex["model"]} if ex and ex.get("included") else None
    if bundle["explanation"] is not None and ex.get("links"):
        bundle["explanation"]["links"] = ex["links"]
    return w, bundle


def manifest_sids(m: dict) -> list[str]:
    """確定記録の記録の sid（v:1 は1つ）。"""
    return [x["sid"] for x in m["sessions"]] if m.get("v") == 2 else [m["sid"]]


def public_file(deps: Deps, public_id: str, name: str) -> bytes:
    w, bundle = public_bundle(deps, public_id)
    m = manifest_of(bundle)
    sids = manifest_sids(m)
    if name in ("start.jpg", "end.jpg"):
        # 開始画面は1回目の記録、終了画面は最後の記録（【T14】）
        sha = m["images"]["start" if name == "start.jpg" else "end"]
        path = paths.image(sids[0] if name == "start.jpg" else sids[-1], sha) if sha else None
    elif name == "png.jpg":
        path = f"works/{m['workId']}/png/{m['png']['sha256']}.thumb.jpg" if m.get("png") else None
    elif re.fullmatch(r"whole-(0|[1-9][0-9]*)\.jpg", name):
        # 載せる設定で、届いている画像だけを返す（T13）
        i = int(name[6:-4])
        wh = m.get("whole")
        it = wh["items"][i] if wh and wh["shown"] and i < len(wh["items"]) else None
        path = paths.image(sids[it.get("session", 0)], it["sha256"]) if it and it["received"] else None
    else:
        path = None
    data = deps.store.get(path) if path else None
    if data is None:
        raise ApiError("NOT_FOUND", "file not found")
    return data


def delete(deps: Deps, uid: str, work_id: str) -> None:
    w = deps.repo.delete_work(work_id, uid)  # 先に Firestore を消す（公開リンクはすぐ 404 になる）
    deps.store.delete_prefix(f"works/{work_id}/")
    for sid in work_sids(w):  # 【T14】すべての記録
        deps.store.delete_prefix(f"sessions/{sid}/")


def session_of(deps: Deps, sid: str) -> dict | None:
    return deps.repo.get(SESSIONS, sid)
