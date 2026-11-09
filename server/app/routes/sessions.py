"""#6〜#8（録画拡張。開始トークンと端末署名）。"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel

from ..core import canonical as c
from ..deps import Deps, get_deps
from ..errors import ApiError
from ..services import chunks, images, start

router = APIRouter(prefix="/v1/sessions")

# 本文を読む前に弾く上限（base64 で約4/3倍になる分と JSON の分を見込む）
MAX_CHUNK_REQUEST = 128 * 1024
MAX_IMAGE_REQUEST = images.MAX_IMAGE + 1


class StartReq(BaseModel):
    startToken: str
    devicePubKey: str


class ChunkReq(BaseModel):
    header: str
    sig: str
    body: str


def _b64(name: str, value: str) -> bytes:
    try:
        return c.b64d(value)
    except ValueError:
        raise ApiError("BAD_REQUEST", f"{name} is not valid base64")


def _check_length(request: Request, limit: int) -> None:
    n = request.headers.get("content-length")
    if n is not None and n.isdigit() and int(n) > limit:
        raise ApiError("TOO_LARGE", "request too large")


@router.post("/{sid}/start")
def post_start(sid: str, body: StartReq, deps: Deps = Depends(get_deps)):
    return start.start(deps, sid, body.startToken, body.devicePubKey)


@router.post("/{sid}/chunks")
async def post_chunk(sid: str, request: Request, deps: Deps = Depends(get_deps)):
    _check_length(request, MAX_CHUNK_REQUEST)
    raw = await request.body()
    if len(raw) > MAX_CHUNK_REQUEST:
        raise ApiError("TOO_LARGE", "request too large")
    try:
        req = ChunkReq.model_validate_json(raw)
    except ValueError:
        raise ApiError("BAD_REQUEST", "body must be {header, sig, body}")
    header = _b64("header", req.header)
    sig = _b64("sig", req.sig)
    body = _b64("body", req.body)
    from starlette.concurrency import run_in_threadpool

    return await run_in_threadpool(chunks.receive, deps, sid, header, sig, body)


@router.put("/{sid}/images/{sha}")
async def put_image(sid: str, sha: str, request: Request, deps: Deps = Depends(get_deps)):
    _check_length(request, MAX_IMAGE_REQUEST)
    data = await request.body()
    from starlette.concurrency import run_in_threadpool

    return await run_in_threadpool(
        images.receive,
        deps,
        sid,
        sha,
        request.headers.get("content-type", ""),
        request.headers.get("x-device-sig", ""),
        data,
    )
