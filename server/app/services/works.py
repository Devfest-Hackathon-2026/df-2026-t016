"""作品とセッションの作成（#2〜#5）。"""

from __future__ import annotations

from datetime import timedelta

from ..core import canonical as c
from ..deps import Deps
from ..errors import ApiError
from ..repo.base import WORKS, review_explanation

START_TOKEN_TTL = timedelta(minutes=10)


def _session_summary(sid: str, s: dict) -> dict:
    head = s.get("head") or {}
    return {
        "sid": sid,
        "status": s.get("status"),
        "chunkCount": s.get("chunkCount", 0),
        "startedAt": s.get("startedAt"),
        "lastReceivedAt": head.get("receivedAt"),
        "final": bool(head.get("final", False)),
    }


def work_detail(deps: Deps, work_id: str, w: dict) -> dict:
    # 【T14】sessions はすべての記録（作った順）。session はいちばん新しい記録（これまでと同じ意味）
    sessions = [_session_summary(x, s) for x, s in deps.repo.sessions_of(w)]
    latest = next((x for x in sessions if x["sid"] == w.get("sid")), None)
    ex = review_explanation(w)
    return {
        "workId": work_id,
        "title": w["title"],
        "displayName": w["displayName"],
        "status": w["status"],
        "session": latest,
        "sessions": sessions,
        "png": w.get("png"),
        "publicId": w.get("publicId"),
        "match": w.get("match"),
        "explanation": {"text": ex["text"], "model": ex["model"], "included": ex["included"]} if ex else None,
        "createdAt": w["createdAt"],
    }


def create_work(deps: Deps, uid: str, title: str, display_name: str) -> dict:
    work_id = c.new_work_id()
    w = {
        "ownerUid": uid,
        "title": title,
        "displayName": display_name,
        "status": "draft",
        "sid": None,
        "sids": [],
        "png": None,
        "publicId": None,
        "match": None,
        "explanation": None,
        "createdAt": c.iso_ms(deps.clock()),
    }
    deps.repo.create_work(work_id, w)
    return work_detail(deps, work_id, w)


def get_owned(deps: Deps, uid: str, work_id: str) -> dict:
    w = deps.repo.get(WORKS, work_id)
    if w is None:
        raise ApiError("NOT_FOUND", "work not found")
    if w.get("ownerUid") != uid:
        raise ApiError("FORBIDDEN", "not the owner")
    return w


def check_app_check(deps: Deps, token: str) -> str | None:
    """APP_CHECK=required なら App Check のトークンを確かめ、使い切りにする。確かめた時刻を返す（T12）。

    トークンが無い・検証に失敗した・使用済み（already_consumed）なら 401 APP_CHECK_FAILED。off なら何もしない。
    """
    if deps.settings.app_check != "required":
        return None
    if not token or deps.app_check is None:
        raise ApiError("APP_CHECK_FAILED", "App Check token is required")
    try:
        result = deps.app_check(token)
    except Exception as e:
        raise ApiError("APP_CHECK_FAILED", "App Check token is invalid") from e
    if result.get("already_consumed"):
        raise ApiError("APP_CHECK_FAILED", "App Check token was already used")
    return c.iso_ms(deps.clock())


def create_session(deps: Deps, uid: str, work_id: str, app_check_verified_at: str | None = None) -> dict:
    now = deps.clock()
    sid = c.new_sid()
    token = c.new_start_token()
    expires = now + START_TOKEN_TTL
    session = {
        "workId": work_id,
        "ownerUid": uid,
        "status": "created",
        "startTokenHash": c.sha256_hex(token.encode("ascii")),
        "startTokenExpiresAt": c.iso_ms(expires),
        "startTokenUsed": False,
        "devicePubKey": None,
        "startCertHash": None,
        "startedAt": None,
        "head": None,
        "chunkCount": 0,
        "imageCount": 0,
        "rejected": 0,
        "appCheckVerifiedAt": app_check_verified_at,
        "createdAt": c.iso_ms(now),
    }
    deps.repo.create_session(work_id, uid, sid, session, now)
    return {"sid": sid, "startToken": token, "expiresAt": c.iso_ms(expires)}
