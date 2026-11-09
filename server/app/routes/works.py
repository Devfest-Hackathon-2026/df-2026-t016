"""#2〜#5（本体アプリ。Firebase ID トークン）。"""

from __future__ import annotations

from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Request, Response
from fastapi.responses import JSONResponse
from pydantic import AfterValidator, BaseModel, Field
from starlette.concurrency import run_in_threadpool

from ..core.text import clean_line
from ..deps import Deps, current_uid, get_deps
from ..errors import ApiError
from ..services import accounts as accounts_svc
from ..services import finalize as finalize_svc
from ..services import png as png_svc
from ..services import works as svc

router = APIRouter(prefix="/v1")

# 題名・表示名は見え方を偽れる文字を消してから使う（core/text.py）
Title = Annotated[str, Field(min_length=1, max_length=100), AfterValidator(clean_line)]
DisplayName = Annotated[str, Field(min_length=1, max_length=50), AfterValidator(clean_line)]


class PutMe(BaseModel):
    displayName: DisplayName


# 【11/8】アカウント（#15・#16）。作品は ownerUid（= uid）でアカウントに紐付く
@router.get("/me")
def get_me(deps: Deps = Depends(get_deps), uid: str = Depends(current_uid)):
    return accounts_svc.get_me(deps, uid)


@router.put("/me")
def put_me(body: PutMe, deps: Deps = Depends(get_deps), uid: str = Depends(current_uid)):
    return accounts_svc.put_me(deps, uid, body.displayName)


class CreateWork(BaseModel):
    title: Title
    displayName: DisplayName


@router.post("/works")
def create_work(body: CreateWork, deps: Deps = Depends(get_deps), uid: str = Depends(current_uid)):
    return JSONResponse(svc.create_work(deps, uid, body.title, body.displayName), status_code=201)


@router.get("/works")
def list_works(deps: Deps = Depends(get_deps), uid: str = Depends(current_uid)):
    return {"works": [svc.work_detail(deps, wid, w) for wid, w in deps.repo.list_works(uid)]}


@router.get("/works/{work_id}")
def get_work(work_id: str, deps: Deps = Depends(get_deps), uid: str = Depends(current_uid)):
    return svc.work_detail(deps, work_id, svc.get_owned(deps, uid, work_id))


@router.post("/works/{work_id}/sessions")
def create_session(work_id: str, request: Request, deps: Deps = Depends(get_deps), uid: str = Depends(current_uid)):
    svc.get_owned(deps, uid, work_id)
    verified_at = svc.check_app_check(deps, request.headers.get("x-firebase-appcheck", ""))
    return JSONResponse(svc.create_session(deps, uid, work_id, app_check_verified_at=verified_at), status_code=201)


# ---------------------------------------------------------------- T08


class DeclarationReq(BaseModel):
    """【11/8】作者の申告（版2）。AI の使い方を3つから選び、詳細は任意で書く"""

    aiUse: Literal["none", "partial", "major"]
    detail: str = Field(default="", max_length=finalize_svc.MAX_DETAIL)


class FinalizeReq(BaseModel):
    # 版1（固定の文言にチェック）。【11/8】新しいアプリは declaration を送る。両方あれば declaration を使う
    declarationAccepted: bool = False
    declaration: DeclarationReq | None = None
    useEndImage: bool = True
    showWhole: bool = True


class ExplanationReq(BaseModel):
    include: bool


@router.put("/works/{work_id}/png")
async def put_png(work_id: str, request: Request, deps: Deps = Depends(get_deps), uid: str = Depends(current_uid)):
    # 受け取る前に、所有者と確定の状態、大きさを確かめる
    await run_in_threadpool(png_svc.check_open, deps, uid, work_id)
    n = request.headers.get("content-length")
    if n is not None and n.isdigit() and int(n) > png_svc.MAX_PNG:
        raise ApiError("TOO_LARGE", "PNG exceeds 30MB")
    data = await request.body()
    return await run_in_threadpool(png_svc.receive, deps, uid, work_id, request.headers.get("content-type", ""), data)


@router.post("/works/{work_id}/finalize")
def post_finalize(work_id: str, body: FinalizeReq, deps: Deps = Depends(get_deps), uid: str = Depends(current_uid)):
    declaration = body.declaration.model_dump() if body.declaration else None
    return finalize_svc.finalize(deps, uid, work_id, body.declarationAccepted, body.useEndImage, body.showWhole, declaration=declaration)


@router.put("/works/{work_id}/explanation")
def put_explanation(work_id: str, body: ExplanationReq, deps: Deps = Depends(get_deps), uid: str = Depends(current_uid)):
    return {"included": deps.repo.set_explanation_included(work_id, uid, body.include)}


@router.delete("/works/{work_id}")
def delete_work(work_id: str, deps: Deps = Depends(get_deps), uid: str = Depends(current_uid)):
    finalize_svc.delete(deps, uid, work_id)
    return Response(status_code=204)


# ---------------------------------------------------------------- 公開（#13・#14、認証なし）

public = APIRouter(prefix="/v1/p")


@public.get("/{public_id}")
def get_public(public_id: str, deps: Deps = Depends(get_deps)):
    _, bundle = finalize_svc.public_bundle(deps, public_id)
    return JSONResponse(bundle, headers={"Cache-Control": "no-store"})


@public.get("/{public_id}/files/{name}")
def get_public_file(public_id: str, name: str, deps: Deps = Depends(get_deps)):
    data = finalize_svc.public_file(deps, public_id, name)
    return Response(data, media_type="image/jpeg", headers={"Cache-Control": "private, max-age=300"})
