"""エラーの形（共通仕様5章）: {"error":{"code","message"}}。"""

from __future__ import annotations

import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

log = logging.getLogger("trace-api")

_STATUS = {
    "BAD_REQUEST": 400,
    "DECLARATION_REQUIRED": 400,
    "UNAUTHENTICATED": 401,
    "TOKEN_INVALID": 401,
    "APP_CHECK_FAILED": 401,
    "FORBIDDEN": 403,
    "NOT_FOUND": 404,
    "SESSION_EXISTS": 409,
    "TOKEN_USED": 409,
    "SEQ_CONFLICT": 409,
    "SEQ_GAP": 409,
    "PREV_MISMATCH": 409,
    "SESSION_CLOSED": 409,
    "STILL_RECORDING": 409,
    "ALREADY_FINALIZED": 409,
    "TOKEN_EXPIRED": 410,
    "TOO_LARGE": 413,
    "UNSUPPORTED_MEDIA": 415,
    "SIGNATURE_INVALID": 422,
    "HASH_MISMATCH": 422,
    "LIMIT_EXCEEDED": 429,
    "INTERNAL": 500,
}


class ApiError(Exception):
    def __init__(self, code: str, message: str = "", **extra):
        super().__init__(f"{code}: {message}")
        if code not in _STATUS:
            raise ValueError(f"unknown error code {code}")
        self.code = code
        self.status = _STATUS[code]
        self.message = message or code
        self.extra = extra


def error_body(code: str, message: str, **extra) -> dict:
    return {"error": {"code": code, "message": message, **extra}}


def install(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api(_: Request, e: ApiError):
        return JSONResponse(error_body(e.code, e.message, **e.extra), status_code=e.status)

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, e: RequestValidationError):
        first = e.errors()[0] if e.errors() else {}
        where = ".".join(str(x) for x in first.get("loc", []))
        return JSONResponse(error_body("BAD_REQUEST", f"{where}: {first.get('msg', 'invalid')}"), status_code=400)

    @app.exception_handler(StarletteHTTPException)
    async def _http(_: Request, e: StarletteHTTPException):
        code = {404: "NOT_FOUND", 401: "UNAUTHENTICATED", 403: "FORBIDDEN", 413: "TOO_LARGE"}.get(e.status_code, "BAD_REQUEST")
        if e.status_code >= 500:
            code = "INTERNAL"
        return JSONResponse(error_body(code, str(e.detail)), status_code=e.status_code)

    @app.exception_handler(Exception)
    async def _any(_: Request, e: Exception):
        log.exception("unhandled error")
        return JSONResponse(error_body("INTERNAL", "internal error"), status_code=500)
