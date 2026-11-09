"""受付API（Cloud Run）。

    uvicorn app.main:app --reload          # 環境変数は app/config.py
"""

from __future__ import annotations

from fastapi import FastAPI, Request, Response

from . import errors
from .config import Settings
from .deps import Deps, build_deps
from .routes import sessions, works


def create_app(deps: Deps | None = None) -> FastAPI:
    app = FastAPI(title="DrawTrace trace-api", docs_url=None, redoc_url=None, openapi_url=None)
    errors.install(app)
    app.state.deps = deps if deps is not None else build_deps(Settings.from_env())

    @app.get("/v1/healthz")
    def healthz():
        return {"ok": True}

    app.include_router(works.router)
    app.include_router(sessions.router)
    app.include_router(works.public)

    # CORS は GET /v1/p/* だけ（共通仕様5章）。中身は T08
    @app.middleware("http")
    async def cors(request: Request, call_next):
        origin = request.headers.get("origin")
        allowed = origin in app.state.deps.settings.cors_origins
        public = request.url.path.startswith("/v1/p/")
        if public and request.method == "OPTIONS":
            resp = Response(status_code=204)
        else:
            resp = await call_next(request)
        if public and allowed:
            resp.headers["Access-Control-Allow-Origin"] = origin
            resp.headers["Access-Control-Allow-Methods"] = "GET"
            resp.headers["Vary"] = "Origin"
        return resp

    return app


def _lazy_app():
    # import しただけでは環境変数を読まない（テストで create_app を使うため）
    return create_app()


class _App:
    _app: FastAPI | None = None

    async def __call__(self, scope, receive, send):
        if self._app is None:
            type(self)._app = _lazy_app()
        await self._app(scope, receive, send)


app = _App()
