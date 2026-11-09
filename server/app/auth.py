"""本体アプリの認証（Firebase ID トークン）。"""

from __future__ import annotations

import re
from typing import Protocol

from fastapi import Request

from .errors import ApiError


class Authenticator(Protocol):
    def uid(self, request: Request) -> str: ...


def _bearer(request: Request) -> str:
    h = request.headers.get("authorization", "")
    m = re.fullmatch(r"Bearer\s+(\S+)", h, flags=re.IGNORECASE)
    if not m:
        raise ApiError("UNAUTHENTICATED", "missing bearer token")
    return m.group(1)


class FirebaseAuth:
    def __init__(self, project_id: str):
        import firebase_admin

        try:
            self._app = firebase_admin.get_app()
        except ValueError:
            self._app = firebase_admin.initialize_app(options={"projectId": project_id})

    def uid(self, request: Request) -> str:
        from firebase_admin import auth

        token = _bearer(request)
        try:
            return auth.verify_id_token(token, app=self._app)["uid"]
        except Exception as e:  # 期限切れ・署名違い・形式違いはすべて 401
            raise ApiError("UNAUTHENTICATED", "invalid id token") from e


class AppCheckVerifier:
    """Firebase App Check のトークンを確かめ、使い切りにする（T12）。

    戻り値は検証の結果（already_consumed を含む）。トークンが偽物・期限切れなら例外。
    サービスアカウントに「Firebase App Check Token Verifier」のロールが要る（使い切りにするため）。
    """

    def __init__(self, project_id: str):
        import firebase_admin

        try:
            self._app = firebase_admin.get_app()
        except ValueError:
            self._app = firebase_admin.initialize_app(options={"projectId": project_id})

    def __call__(self, token: str) -> dict:
        from firebase_admin import app_check

        return app_check.verify_token(token, app=self._app, consume=True)


class DevAuth:
    """テストとローカル用。X-Dev-Uid の値を uid にする。"""

    def uid(self, request: Request) -> str:
        uid = request.headers.get("x-dev-uid", "").strip()
        if not uid:
            raise ApiError("UNAUTHENTICATED", "missing X-Dev-Uid")
        return uid
