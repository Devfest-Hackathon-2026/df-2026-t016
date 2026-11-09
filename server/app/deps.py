"""依存するもの（署名・保存先・リポジトリ・認証・時計）をまとめる。テストでは差し替える。"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import TYPE_CHECKING, Callable

from fastapi import Request

from .auth import Authenticator, DevAuth, FirebaseAuth
from .config import Settings
from .core.crypto import LocalSigner, Signer
from .repo.base import Repo
from .store.base import Store

if TYPE_CHECKING:
    from .services.review import ReviewPair


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


@dataclass
class Deps:
    settings: Settings
    signer: Signer
    store: Store
    repo: Repo
    auth: Authenticator
    clock: Callable[[], datetime] = field(default=utcnow)
    # 途中画像の組から注意点 {"text","model"} を作る。該当がなければ text は空。
    explainer: Callable[[list[ReviewPair]], dict] | None = None
    # App Check のトークンを確かめる役（APP_CHECK=required のとき。T12）
    app_check: Callable[[str], dict] | None = None


def _read_pem(value: str) -> str:
    if "BEGIN" in value:
        return value
    return Path(value).read_text(encoding="ascii")


def build_deps(s: Settings) -> Deps:
    if s.signer == "kms":
        from .signer.kms import KmsSigner

        signer: Signer = KmsSigner(s.kms_key_version)
    elif s.signer == "local":
        if not s.local_signer_pem:
            raise RuntimeError("SIGNER=local needs LOCAL_SIGNER_PEM")
        signer = LocalSigner(_read_pem(s.local_signer_pem))
    else:
        raise RuntimeError(f"unknown SIGNER {s.signer}")

    if s.store == "gcs":
        from .store.gcs import GcsStore

        store: Store = GcsStore(s.bucket)
    elif s.store == "local":
        from .store.local import LocalStore

        store = LocalStore(s.local_store_dir)
    else:
        raise RuntimeError(f"unknown STORE {s.store}")

    if s.repo == "firestore":
        from .repo.firestore import FirestoreRepo

        repo: Repo = FirestoreRepo(s.project_id)
    elif s.repo == "memory":
        from .repo.memory import MemoryRepo

        repo = MemoryRepo()
    else:
        raise RuntimeError(f"unknown REPO {s.repo}")

    if s.auth == "firebase":
        auth: Authenticator = FirebaseAuth(s.project_id)
    elif s.auth == "dev":
        auth = DevAuth()
    else:
        raise RuntimeError(f"unknown AUTH {s.auth}")

    explainer = None
    if s.gemini_model:
        from .services.gemini import GeminiExplainer

        explainer = GeminiExplainer(s.project_id, s.gemini_location, s.gemini_model)

    app_check = None
    if s.app_check == "required":
        from .auth import AppCheckVerifier

        app_check = AppCheckVerifier(s.project_id)
    elif s.app_check != "off":
        raise RuntimeError(f"unknown APP_CHECK {s.app_check}")

    return Deps(settings=s, signer=signer, store=store, repo=repo, auth=auth, explainer=explainer, app_check=app_check)


def get_deps(request: Request) -> Deps:
    return request.app.state.deps


def current_uid(request: Request) -> str:
    return get_deps(request).auth.uid(request)
