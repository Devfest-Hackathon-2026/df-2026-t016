"""環境変数から設定を読む（tasks/T04）。

SIGNER   local | kms      署名の役。local は LOCAL_SIGNER_PEM（PEM の文字列かファイルのパス）
STORE    local | gcs      保存先。local は LOCAL_STORE_DIR
REPO     memory | firestore
AUTH     firebase | dev   dev は X-Dev-Uid ヘッダの値を uid にする（テストとローカル用）
"""

from __future__ import annotations

import os
from dataclasses import dataclass


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


@dataclass(frozen=True)
class Settings:
    signer: str = "local"
    kms_key_version: str = ""
    local_signer_pem: str = ""
    store: str = "local"
    bucket: str = ""
    local_store_dir: str = ".local_store"
    repo: str = "memory"
    auth: str = "dev"
    project_id: str = ""
    cors_origins: tuple[str, ...] = ("http://localhost:5173",)
    app_check: str = "off"  # required なら記録を作る要求で App Check のトークンを確かめる（T12）
    gemini_model: str = ""  # 空なら注意点を作らない
    gemini_location: str = "global"
    match_threshold: float = 0.80  # 外観照合の SSIM のしきい値（T11 で実機の値を見て決める）
    match_min_screen: float = 0.20  # 重なりが終了画面に占める割合の下限
    match_min_png: float = 0.50  # 重なりが写した PNG 全体に占める割合の下限

    @classmethod
    def from_env(cls) -> "Settings":
        project = _env("PROJECT_ID")
        default_origins = ["http://localhost:5173"]
        if project:
            default_origins += [f"https://{project}.web.app", f"https://{project}.firebaseapp.com"]
        origins = _env("CORS_ORIGINS")
        return cls(
            signer=_env("SIGNER", "local"),
            kms_key_version=_env("KMS_KEY_VERSION"),
            local_signer_pem=_env("LOCAL_SIGNER_PEM"),
            store=_env("STORE", "local"),
            bucket=_env("BUCKET"),
            local_store_dir=_env("LOCAL_STORE_DIR", ".local_store"),
            repo=_env("REPO", "memory"),
            auth=_env("AUTH", "dev"),
            project_id=project,
            cors_origins=tuple(o.strip() for o in origins.split(",") if o.strip()) if origins else tuple(default_origins),
            gemini_model=_env("GEMINI_MODEL"),
            gemini_location=_env("GEMINI_LOCATION", "global"),
            match_threshold=float(_env("MATCH_THRESHOLD", "0.80")),
            match_min_screen=float(_env("MATCH_MIN_SCREEN", "0.20")),
            match_min_png=float(_env("MATCH_MIN_PNG", "0.50")),
            app_check=_env("APP_CHECK", "off"),
        )
