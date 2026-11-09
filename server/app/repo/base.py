"""作品・セッション・公開 ID の読み書き（共通仕様6章の Firestore）。

トランザクションは run_txn(fn) で行う。fn は Txn を受け取り、読み（get）を全部済ませてから
書き（set・update・delete）をする（Firestore のトランザクションの決まり）。
状態を変える処理（セッションの作成・開始・先頭を進める）はここに置き、memory 版と Firestore 版で共通にする。
"""

from __future__ import annotations

import math
from abc import ABC, abstractmethod
from datetime import datetime
from typing import Any, Callable, TypeVar

from ..errors import ApiError

T = TypeVar("T")

WORKS = "works"
SESSIONS = "sessions"
PUBLICS = "publics"
REVIEW_VERSION = 2
# 【11/8】アカウント。ドキュメントの ID は Firebase の uid で、作品・記録の ownerUid と同じ値（それで紐付ける）
ACCOUNTS = "accounts"


def review_explanation(work: dict, *, include_empty: bool = False) -> dict | None:
    ex = work.get("explanation")
    if work.get("reviewVersion") != REVIEW_VERSION or not ex:
        return None
    return ex if include_empty or ex.get("text") else None

MAX_WORKS_PER_USER = 20
MAX_SESSIONS_PER_WORK = 30  # 【T14】1作品の記録の数
QUIET_SEC = 60  # 最後の受信からこれだけたてば、録画は止まったとみなす（確定・記録の追加）


def parse_time(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def work_sids(work: dict) -> list[str]:
    """作品の記録の sid を作った順に返す（【T14】T14 より前の作品は sid だけを持つ）。"""
    sids = list(work.get("sids") or [])
    if not sids and work.get("sid"):
        sids = [work["sid"]]
    return sids


def recording_wait(s: dict, now: datetime) -> int | None:
    """録画中かもしれない記録なら、あと何秒待てば止まったとみなせるかを返す。そうでなければ None。"""
    if s.get("status") != "recording":
        return None
    last = (s.get("head") or {}).get("receivedAt") or s["startedAt"]
    elapsed = (now - parse_time(last)).total_seconds()
    return math.ceil(QUIET_SEC - elapsed) if elapsed < QUIET_SEC else None


def _put_account(t: "Txn", uid: str, account: dict | None, display_name: str, now: str) -> dict:
    """アカウントを作るか、表示名が変わったときだけ書き換える（読みは呼び出し側で済ませておく）。"""
    if account is None:
        doc = {"uid": uid, "displayName": display_name, "createdAt": now, "updatedAt": now}
        t.set(ACCOUNTS, uid, doc)
        return doc
    if account.get("displayName") != display_name:
        t.update(ACCOUNTS, uid, {"displayName": display_name, "updatedAt": now})
        return {**account, "displayName": display_name, "updatedAt": now}
    return account


class Txn(ABC):
    @abstractmethod
    def get(self, col: str, doc_id: str) -> dict | None: ...

    @abstractmethod
    def set(self, col: str, doc_id: str, data: dict) -> None: ...

    @abstractmethod
    def update(self, col: str, doc_id: str, fields: dict) -> None: ...

    @abstractmethod
    def delete(self, col: str, doc_id: str) -> None: ...


class Repo(ABC):
    # ------------------------------------------------------------ 下回り

    @abstractmethod
    def run_txn(self, fn: Callable[[Txn], T]) -> T: ...

    @abstractmethod
    def get(self, col: str, doc_id: str) -> dict | None: ...

    @abstractmethod
    def query_eq(self, col: str, field: str, value: Any) -> list[tuple[str, dict]]: ...

    # ------------------------------------------------------------ 作品

    def create_work(self, work_id: str, work: dict) -> None:
        uid = work["ownerUid"]
        owned = self.query_eq(WORKS, "ownerUid", uid)
        if len(owned) >= MAX_WORKS_PER_USER:
            raise ApiError("LIMIT_EXCEEDED", f"up to {MAX_WORKS_PER_USER} works per user")

        def fn(t: Txn):
            if t.get(WORKS, work_id) is not None:
                raise ApiError("INTERNAL", "workId collision")
            account = t.get(ACCOUNTS, uid)
            t.set(WORKS, work_id, work)
            # 【11/8】アカウントが無ければ作る（前の版のアプリは /v1/me を呼ばないので、作品を作るときにも作る）
            _put_account(t, uid, account, work["displayName"], work["createdAt"])

        self.run_txn(fn)

    # ------------------------------------------------------------ アカウント（【11/8】#15・#16）

    def put_account(self, uid: str, display_name: str, now: str) -> dict:
        """アカウントを作るか、表示名を変える。保存した内容を返す。"""

        def fn(t: Txn):
            return _put_account(t, uid, t.get(ACCOUNTS, uid), display_name, now)

        return self.run_txn(fn)

    def list_works(self, uid: str) -> list[tuple[str, dict]]:
        works = self.query_eq(WORKS, "ownerUid", uid)
        return sorted(works, key=lambda x: x[1].get("createdAt", ""), reverse=True)

    # ------------------------------------------------------------ セッションの作成（#5）

    def create_session(self, work_id: str, uid: str, sid: str, session: dict, now: datetime) -> None:
        """作品に記録（セッション）を足す（【T14】作品ごとに複数）。

        未開始の記録は置き換える。録画中かもしれない記録があれば 409 SESSION_EXISTS。
        """

        def fn(t: Txn):
            work = t.get(WORKS, work_id)
            if work is None:
                raise ApiError("NOT_FOUND", "work not found")
            if work.get("ownerUid") != uid:
                raise ApiError("FORBIDDEN", "not the owner")
            if work.get("status") in ("finalizing", "finalized"):
                raise ApiError("ALREADY_FINALIZED", "work is finalized")
            sessions = [(x, t.get(SESSIONS, x)) for x in work_sids(work)]
            started = [(x, s) for x, s in sessions if s is not None and s.get("status") != "created"]
            waits = [w for _, s in started if (w := recording_wait(s, now)) is not None]
            if waits:
                raise ApiError("SESSION_EXISTS", "録画中の記録があります。止めてから追加してください", retryAfterSec=max(waits))
            if len(started) >= MAX_SESSIONS_PER_WORK:
                raise ApiError("LIMIT_EXCEEDED", f"up to {MAX_SESSIONS_PER_WORK} records per work")
            for x, s in sessions:
                if s is not None and s.get("status") == "created":
                    t.delete(SESSIONS, x)
            t.set(SESSIONS, sid, session)
            t.update(WORKS, work_id, {"sid": sid, "sids": [x for x, _ in started] + [sid]})

        self.run_txn(fn)

    def sessions_of(self, work: dict) -> list[tuple[str, dict]]:
        """作品の記録を作った順に返す（消えたものは飛ばす）。"""
        out = []
        for x in work_sids(work):
            s = self.get(SESSIONS, x)
            if s is not None:
                out.append((x, s))
        return out

    # ------------------------------------------------------------ 開始（#6 の手順7）

    def start_session(self, sid: str, device_pub: str, start_cert_hash: str, started_at: str) -> None:
        def fn(t: Txn):
            s = t.get(SESSIONS, sid)
            if s is None:
                raise ApiError("NOT_FOUND", "session not found")
            if s.get("startTokenUsed"):
                if s.get("devicePubKey") != device_pub:
                    raise ApiError("TOKEN_USED", "start token already used with another key")
                return
            work = t.get(WORKS, s["workId"])
            if work is not None and work.get("status") in ("finalizing", "finalized"):
                raise ApiError("SESSION_CLOSED", "work is finalized")
            t.update(
                SESSIONS,
                sid,
                {
                    "startTokenUsed": True,
                    "status": "recording",
                    "devicePubKey": device_pub,
                    "startCertHash": start_cert_hash,
                    "head": {"seq": -1, "hash": start_cert_hash, "receivedAt": None, "final": False},
                    "startedAt": started_at,
                },
            )
            # 【T14】次の記録を始めたら recorded から recording に戻す
            if work is not None and work.get("status") in ("draft", "recorded") and work.get("sid") == sid:
                t.update(WORKS, s["workId"], {"status": "recording"})

        self.run_txn(fn)

    # ------------------------------------------------------------ 先頭を進める（チャンクの手順7）

    def advance_head(self, sid: str, seq: int, header_hash: str, received_at: str, final: bool) -> None:
        def fn(t: Txn):
            s = t.get(SESSIONS, sid)
            if s is None:
                raise ApiError("NOT_FOUND", "session not found")
            head = s["head"]
            if s.get("status") != "recording":
                if head["seq"] >= seq:
                    return  # 取り込み済みのチャンクの再送
                raise ApiError("SESSION_CLOSED", "session is not recording")
            if head["seq"] >= seq:
                return
            if head["seq"] != seq - 1:
                raise ApiError("SEQ_GAP", f"expected seq {head['seq'] + 1}")
            work = t.get(WORKS, s["workId"]) if final else None
            fields = {
                "head": {"seq": seq, "hash": header_hash, "receivedAt": received_at, "final": final},
                "chunkCount": seq + 1,
            }
            if final:
                fields["status"] = "completed"
            t.update(SESSIONS, sid, fields)
            # 【T14】古い記録の最終チャンクが後から届いても、作品の状態は変えない
            if final and work is not None and work.get("status") == "recording" and work.get("sid") == sid:
                t.update(WORKS, s["workId"], {"status": "recorded"})

        self.run_txn(fn)

    # ------------------------------------------------------------ PNG（#9）

    def set_png(self, work_id: str, png: dict) -> None:
        def fn(t: Txn):
            w = t.get(WORKS, work_id)
            if w is None:
                raise ApiError("NOT_FOUND", "work not found")
            if w.get("status") in ("finalizing", "finalized"):
                raise ApiError("ALREADY_FINALIZED", "work is finalized")
            t.update(WORKS, work_id, {"png": png})

        self.run_txn(fn)

    # ------------------------------------------------------------ 確定の段階A（#10）

    def finalize_fix(self, work_id: str, uid: str, now, finalize: dict) -> tuple[str, dict]:
        """作品を finalizing にして finalize の値を保存する。

        戻り値は (状態, 作品)。状態は "fixed"（今固定した）・"finalizing"（固定済み）・"finalized"（確定済み）。
        finalize には publicId・createdAt・acceptedAt・useEndImage を入れて渡す。残りはここで決める。
        【T14】開始したすべての記録を、開始した順に固定する（finalize.sessions）。未開始の記録は消す。
        """

        def fn(t: Txn):
            w = t.get(WORKS, work_id)
            if w is None:
                raise ApiError("NOT_FOUND", "work not found")
            if w.get("ownerUid") != uid:
                raise ApiError("FORBIDDEN", "not the owner")
            if w.get("status") == "finalized":
                return "finalized", w
            if w.get("status") == "finalizing":
                return "finalizing", w
            sessions = [(x, t.get(SESSIONS, x)) for x in work_sids(w)]
            started = [(x, s) for x, s in sessions if s is not None and s.get("status") != "created"]
            if not started:
                raise ApiError("NOT_FOUND", "録画が始まっていません")
            waits = [wt for _, s in started if (wt := recording_wait(s, now)) is not None]
            if waits:
                raise ApiError("STILL_RECORDING", "recording may still be in progress", retryAfterSec=max(waits))
            started.sort(key=lambda x: x[1].get("startedAt") or "")
            fixed = []
            for x, s in started:
                if s["status"] == "completed":
                    result = "completed"
                elif s["status"] == "recording":
                    result = "aborted"
                else:
                    raise ApiError("ALREADY_FINALIZED", "session is already finalizing")
                head = s["head"]
                fixed.append(
                    {
                        "sid": x,
                        "result": result,
                        "range": {"count": head["seq"] + 1, "lastSeq": head["seq"], "lastHash": head["hash"]},
                        "rejected": int(s.get("rejected", 0)),
                    }
                )
            f = {**finalize, "sessions": fixed, "png": w.get("png")}
            for x, s in sessions:
                if s is not None and s.get("status") == "created":
                    t.delete(SESSIONS, x)
            fields = {"status": "finalizing", "finalize": f, "sids": [x["sid"] for x in fixed], "sid": fixed[-1]["sid"]}
            t.update(WORKS, work_id, fields)
            for x in fixed:
                t.update(SESSIONS, x["sid"], {"status": "finalizing"})
            return "fixed", {**w, **fields}

        return self.run_txn(fn)

    # ------------------------------------------------------------ 確定の段階C

    def finalize_publish(self, work_id: str, public_id: str, finalized_at: str, match: dict, explanation: dict | None) -> dict:
        def fn(t: Txn):
            w = t.get(WORKS, work_id)
            if w is None:
                raise ApiError("NOT_FOUND", "work not found")
            if w.get("status") == "finalized":
                return w
            pub = t.get(PUBLICS, public_id)
            sessions = [(x, t.get(SESSIONS, x)) for x in work_sids(w)]
            if pub is None:
                t.set(PUBLICS, public_id, {"workId": work_id})
            fields = {
                "status": "finalized",
                "publicId": public_id,
                "finalizedAt": finalized_at,
                "match": match,
                "explanation": explanation,
            }
            if explanation is not None:
                fields["reviewVersion"] = REVIEW_VERSION
            t.update(WORKS, work_id, fields)
            for x, s in sessions:
                if s is not None:
                    t.update(SESSIONS, x, {"status": "finalized"})
            return {**w, **fields}

        return self.run_txn(fn)

    # ------------------------------------------------------------ 注意点を載せるか（#11）

    def replace_explanation(self, work_id: str, public_id: str, explanation: dict) -> bool:
        def fn(t: Txn):
            w = t.get(WORKS, work_id)
            pub = t.get(PUBLICS, public_id)
            if (not w or w.get("status") != "finalized" or w.get("publicId") != public_id
                    or not pub or pub.get("workId") != work_id):
                return False
            if w.get("reviewVersion") == REVIEW_VERSION:
                return True
            included = (w.get("explanation") or {}).get("included", True)
            t.update(WORKS, work_id, {
                "reviewVersion": REVIEW_VERSION,
                "explanation": {**explanation, "included": included},
            })
            return True

        return self.run_txn(fn)

    def set_explanation_included(self, work_id: str, uid: str, include: bool) -> bool:
        def fn(t: Txn):
            w = t.get(WORKS, work_id)
            if w is None:
                raise ApiError("NOT_FOUND", "work not found")
            if w.get("ownerUid") != uid:
                raise ApiError("FORBIDDEN", "not the owner")
            if w.get("status") != "finalized":
                raise ApiError("BAD_REQUEST", "work is not finalized")
            ex = review_explanation(w)
            if not ex:
                return False
            t.update(WORKS, work_id, {"explanation": {**ex, "included": bool(include)}})
            return bool(include)

        return self.run_txn(fn)

    # ------------------------------------------------------------ 削除（#12）

    def delete_work(self, work_id: str, uid: str) -> dict:
        """作品・セッション・公開 ID を消し、消した作品を返す（GCS は呼び出し側で消す）。"""

        def fn(t: Txn):
            w = t.get(WORKS, work_id)
            if w is None:
                raise ApiError("NOT_FOUND", "work not found")
            if w.get("ownerUid") != uid:
                raise ApiError("FORBIDDEN", "not the owner")
            t.delete(WORKS, work_id)
            for x in work_sids(w):
                t.delete(SESSIONS, x)
            pid = w.get("publicId") or (w.get("finalize") or {}).get("publicId")
            if pid:
                t.delete(PUBLICS, pid)
            return w

        return self.run_txn(fn)

    def reserve_image(self, sid: str, sha: str, limit: int) -> None:
        """画像の保存前に枠を確保する。同じハッシュの再送は同じ枠を使う。

        保存に失敗しても予約は残す。再送で保存を続けられ、保存結果が不明な
        障害でも枚数を数え漏らさない。最大150個なのでセッション内に保持する。
        """
        def fn(t: Txn):
            s = t.get(SESSIONS, sid)
            if s is None:
                raise ApiError("NOT_FOUND", "session not found")
            if s.get("status") not in ("recording", "completed"):
                raise ApiError("SESSION_CLOSED", "session is not accepting images")
            hashes = s.get("imageHashes", [])
            if sha in hashes:
                return
            count = int(s.get("imageCount", 0))
            if count >= limit:
                raise ApiError("LIMIT_EXCEEDED", f"up to {limit} images per session")
            t.update(SESSIONS, sid, {"imageCount": count + 1, "imageHashes": [*hashes, sha]})

        self.run_txn(fn)

    def increment_rejected(self, sid: str) -> None:
        def fn(t: Txn):
            s = t.get(SESSIONS, sid)
            if s is not None:
                t.update(SESSIONS, sid, {"rejected": int(s.get("rejected", 0)) + 1})

        self.run_txn(fn)
