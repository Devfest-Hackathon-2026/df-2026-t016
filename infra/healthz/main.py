"""T02 で Cloud Run へのデプロイを確かめるための雛形。T04 で server/ の本体に置き換える。"""

from fastapi import FastAPI

app = FastAPI()


@app.get("/v1/healthz")
def healthz():
    return {"ok": True}
