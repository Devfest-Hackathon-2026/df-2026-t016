"""【11/8】アカウント（#15・#16）。

アカウントの ID は Firebase の uid。作品（works）と記録（sessions）は ownerUid に同じ値を持ち、それで紐付ける。
1人の描き手が複数の作品を持ち、複数の描き手が同じ受付API を使える。今は匿名ログインだけなので、
アプリを消すと uid が変わる（別のアカウントになる）。Google などのログインを足すときは、
Firebase の linkWithCredential で同じ uid を引き継げば、この表も作品もそのまま使える。
"""

from __future__ import annotations

from ..core import canonical as c
from ..deps import Deps
from ..repo.base import ACCOUNTS, MAX_WORKS_PER_USER


def _view(deps: Deps, uid: str, account: dict | None) -> dict:
    works = deps.repo.list_works(uid)
    return {
        "uid": uid,
        "displayName": account.get("displayName") if account else None,
        "createdAt": account.get("createdAt") if account else None,
        "workCount": len(works),
        "workLimit": MAX_WORKS_PER_USER,
    }


def get_me(deps: Deps, uid: str) -> dict:
    return _view(deps, uid, deps.repo.get(ACCOUNTS, uid))


def put_me(deps: Deps, uid: str, display_name: str) -> dict:
    account = deps.repo.put_account(uid, display_name, c.iso_ms(deps.clock()))
    return _view(deps, uid, account)
