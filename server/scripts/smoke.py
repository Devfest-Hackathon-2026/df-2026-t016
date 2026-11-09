"""デプロイした受付API で、作品の作成から確定・公開・削除までを1回通す（T04・T08 の完了条件）。

    python server/scripts/smoke.py \
        --api https://trace-api-....run.app \
        --api-key <GoogleService-Info.plist の API_KEY> \
        --pem shared/keys/kms_public.pem

ID トークンは Firebase の REST API の匿名ログインで取る。作ったテスト用の匿名ユーザーは最後に消す。
最後に作品を消す。--keep を付けると消さずに、検証ページの URL を出す。
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import sys

import httpx
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature


sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parents[2] / "tools" / "fixtures"))
import generate as fx  # noqa: E402  画像の合成に使う（tools/fixtures/generate.py）


def b64e(b: bytes) -> str:
    return base64.b64encode(b).decode()


def b64d(s: str) -> bytes:
    return base64.b64decode(s, validate=True)


def dumps(o) -> bytes:
    return json.dumps(o, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def rs(key, msg: bytes) -> bytes:
    r, s = decode_dss_signature(key.sign(msg, ec.ECDSA(hashes.SHA256())))
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def check(cond, what):
    print(("OK  " if cond else "NG  ") + what)
    if not cond:
        sys.exit(1)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", required=True)
    ap.add_argument("--api-key", required=True)
    ap.add_argument("--bundle-id", default="com.ggdevfest2026.drawtrace")
    ap.add_argument("--pem", required=True)
    ap.add_argument("--keep", action="store_true", help="最後に作品を消さない（検証ページで開いて確かめる用）")
    ap.add_argument("--hosting", default="https://drawtrace-gg2026.web.app")
    a = ap.parse_args()
    pub = serialization.load_pem_public_key(open(a.pem, "rb").read())

    def kms_ok(sig_b64, data: bytes) -> bool:
        try:
            pub.verify(b64d(sig_b64), data, ec.ECDSA(hashes.SHA256()))
            return True
        except InvalidSignature:
            return False

    with httpx.Client(timeout=30) as http:
        # 匿名ログイン
        r = http.post(
            f"https://identitytoolkit.googleapis.com/v1/accounts:signUp?key={a.api_key}",
            json={"returnSecureToken": True},
            headers={"X-Ios-Bundle-Identifier": a.bundle_id},
        )
        r.raise_for_status()
        id_token = r.json()["idToken"]
        auth = {"Authorization": f"Bearer {id_token}"}
        try:
            api = a.api.rstrip("/")
            check(http.get(f"{api}/v1/healthz").json() == {"ok": True}, "healthz")
            r = http.post(f"{api}/v1/works", json={"title": "smoke", "displayName": "smoke"}, headers=auth)
            check(r.status_code == 201, f"作品の作成 {r.status_code}")
            wid = r.json()["workId"]
            r = http.post(f"{api}/v1/works/{wid}/sessions", json={}, headers=auth)
            check(r.status_code == 201, f"セッションの作成 {r.status_code}")
            sid, token = r.json()["sid"], r.json()["startToken"]

            key = ec.generate_private_key(ec.SECP256R1())
            pub_b64 = b64e(key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint))
            r = http.post(f"{api}/v1/sessions/{sid}/start", json={"startToken": token, "devicePubKey": pub_b64})
            check(r.status_code == 200, f"開始 {r.status_code} {r.text[:200]}")
            start = r.json()
            check(kms_ok(start["sig"], b64d(start["startCert"])), "開始証の KMS 署名")
            prev = sha(b64d(start["startCert"]))

            # 開始画面・終了画面・PNG は、試験データ（T06）と同じ作り方で合成する
            lines = fx.strokes(seed=7, n=26)
            canvas = fx.canvas(lines)
            png_img = fx.png(canvas)
            # 【11/6】撮る画像は全体画像だけ。最初の全体画像が開始画面、最後の全体画像が終了画面（T05）
            wholes = [fx.whole_jpeg(fx.canvas(lines[:k])) for k in (6, 16, 26)]
            start_img, end_img = wholes[0], wholes[-1]

            def put_image(data: bytes) -> str:
                h = sha(data)
                r = http.put(
                    f"{api}/v1/sessions/{sid}/images/{h}",
                    content=data,
                    headers={"Content-Type": "image/jpeg", "X-Device-Sig": b64e(rs(key, f"image:{sid}:{h}".encode()))},
                )
                check(r.status_code == 200, f"画像 {r.status_code}")
                return h

            wh = [put_image(w) for w in wholes]
            ih, eh = wh[0], wh[-1]

            for seq in range(3):
                body = dumps({"v": 1, "frames": [seq, 1], "tiles": b64e(bytes(96))})
                header = {
                    "v": 1, "sid": sid, "seq": seq, "prev": prev,
                    "tStart": "2026-11-05T00:00:00.000Z", "tEnd": "2026-11-05T00:00:10.000Z",
                    "body": sha(body), "bodyLen": len(body),
                    "stats": {"fps": 10, "changedTiles": 1, "resend": False, "memMB": 30, "degraded": False},
                    "final": seq == 2,
                }
                header["images"] = {"whole": wh[seq]}
                if seq == 0:
                    header["images"]["start"] = ih
                if seq == 2:
                    header["images"]["end"] = eh
                hb = dumps(header)
                req = {"header": b64e(hb), "sig": b64e(rs(key, hb)), "body": b64e(body)}
                r = http.post(f"{api}/v1/sessions/{sid}/chunks", json=req)
                check(r.status_code == 200, f"チャンク {seq} {r.status_code} {r.text[:200]}")
                rec = b64d(r.json()["receipt"])
                check(kms_ok(r.json()["sig"], rec) and json.loads(rec)["header"] == sha(hb), f"受領証 {seq}")
                r2 = http.post(f"{api}/v1/sessions/{sid}/chunks", json=req)
                check(r2.json() == r.json(), f"チャンク {seq} の再送で同じ受領証")
                prev = sha(hb)

            w = http.get(f"{api}/v1/works/{wid}", headers=auth).json()
            check(w["status"] == "recorded" and w["session"]["chunkCount"] == 3, f"作品の状態 {w['status']}")

            # T08: PNG → 確定 → 公開 → 説明の切り替え → 削除
            r = http.put(f"{api}/v1/works/{wid}/png", content=png_img, headers={**auth, "Content-Type": "image/png"})
            check(r.status_code == 200 and r.json()["sha256"] == sha(png_img), f"PNG {r.status_code}")
            r = http.post(f"{api}/v1/works/{wid}/finalize", json={"declarationAccepted": True}, headers=auth, timeout=90)
            check(r.status_code == 200, f"確定 {r.status_code} {r.text[:300]}")
            fin = r.json()
            pid, m = fin["publicId"], fin["manifest"]
            ms = m["sessions"][0]  # 【T14】確定記録 v:2
            check(m["v"] == 2 and ms["status"] == "completed" and ms["chunks"]["count"] == 3, "確定記録の件数")
            print(f"     外観照合: {m['match']}")
            check(m["match"]["result"] == "match", "外観照合が match")
            w = m.get("whole") or {}
            print(f"     全体画像: {[(l['result'], l['kept']) for l in w.get('links', [])]} toPng={w.get('toPng')}")
            check(len(w.get("items", [])) == 3 and all(it["received"] and it["canvas"] for it in w["items"]), "全体画像3枚が届き、キャンバスを検出")
            check(all(l["result"] == "linked" for l in w["links"]) and w["toPng"]["result"] == "linked", "全体画像のつながりがすべて linked")
            print(f"     補足説明: {fin['explanation']}")
            r2 = http.post(f"{api}/v1/works/{wid}/finalize", json={"declarationAccepted": True}, headers=auth)
            check(r2.json()["publicId"] == pid, "確定の再送で同じ公開 ID")

            b = http.get(f"{api}/v1/p/{pid}").json()
            check(kms_ok(b["manifest"]["sig"], b64d(b["manifest"]["bytes"])), "確定記録の KMS 署名")
            check(json.loads(b64d(b["manifest"]["bytes"])) == m, "証拠一式の確定記録が確定の応答と同じ")
            for name, want in (("start.jpg", start_img), ("end.jpg", end_img), ("whole-1.jpg", wholes[1])):
                f = http.get(f"{api}/v1/p/{pid}/files/{name}")
                check(f.status_code == 200 and f.content == want, f"画像の配布 {name}")
            check(http.get(f"{api}/v1/p/{pid}/files/png.jpg").status_code == 200, "画像の配布 png.jpg")
            if fin["explanation"]:
                r = http.put(f"{api}/v1/works/{wid}/explanation", json={"include": False}, headers=auth)
                check(r.json() == {"included": False} and http.get(f"{api}/v1/p/{pid}").json()["explanation"] is None, "説明を載せない")
                http.put(f"{api}/v1/works/{wid}/explanation", json={"include": True}, headers=auth)
            print(f"workId={wid} sid={sid} publicId={pid}")
            if a.keep:
                print(f"     残しました: {a.hosting}/p/{pid}")
            else:
                r = http.delete(f"{api}/v1/works/{wid}", headers=auth)
                check(r.status_code == 204 and http.get(f"{api}/v1/p/{pid}").status_code == 404, "削除の後は 404")
        finally:
            http.post(f"https://identitytoolkit.googleapis.com/v1/accounts:delete?key={a.api_key}",
                      json={"idToken": id_token}, headers={"X-Ios-Bundle-Identifier": a.bundle_id})


if __name__ == "__main__":
    main()
