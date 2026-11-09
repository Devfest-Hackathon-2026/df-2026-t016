"""T11 の試験9: 受付API の再送・同時送信・途中停止・確定の同時実行を、Cloud Run の上で1回行う。

    python server/scripts/cloud_checks.py \
        --api https://trace-api-....run.app \
        --api-key <GoogleService-Info.plist の API_KEY> \
        --pem shared/keys/kms_public.pem \
        --bucket drawtrace-gg2026-trace

本物の構成（KMS・Firestore・Cloud Storage）で、手元の pytest（memory 版）と同じことが起きるかを確かめる。
「保存の直後に止まった」場面は、チャンクのオブジェクトだけを gcloud storage で直接置いて作る。
最後に作品とテスト用の匿名ユーザーを消す。
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

RESULTS: list[tuple[bool, str]] = []


def b64e(b: bytes) -> str:
    return base64.b64encode(b).decode()


def b64d(s: str) -> bytes:
    return base64.b64decode(s, validate=True)


def dumps(o) -> bytes:
    return json.dumps(o, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def check(cond: bool, what: str) -> None:
    RESULTS.append((bool(cond), what))
    print(("OK  " if cond else "NG  ") + what, flush=True)


class Device:
    def __init__(self):
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.pub = b64e(self.key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint))

    def rs(self, msg: bytes) -> bytes:
        r, s = decode_dss_signature(self.key.sign(msg, ec.ECDSA(hashes.SHA256())))
        return r.to_bytes(32, "big") + s.to_bytes(32, "big")

    def chunk(self, sid: str, seq: int, prev: str, final=False, t_end="2026-11-07T00:00:10.000Z") -> tuple[dict, str]:
        body = dumps({"v": 1, "frames": [seq, 1], "tiles": b64e(bytes(96))})
        header = {
            "v": 1, "sid": sid, "seq": seq, "prev": prev,
            "tStart": "2026-11-07T00:00:00.000Z", "tEnd": t_end,
            "body": sha(body), "bodyLen": len(body),
            "stats": {"fps": 10, "changedTiles": 1, "resend": False, "memMB": 30, "degraded": False},
            "final": final,
        }
        hb = dumps(header)
        return {"header": b64e(hb), "sig": b64e(self.rs(hb)), "body": b64e(body)}, sha(hb)


def in_threads(fn, n: int) -> list:
    out: list = [None] * n
    barrier = threading.Barrier(n)

    def run(i):
        barrier.wait()
        out[i] = fn(i)

    ts = [threading.Thread(target=run, args=(i,)) for i in range(n)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", required=True)
    ap.add_argument("--api-key", required=True)
    ap.add_argument("--bundle-id", default="com.ggdevfest2026.drawtrace")
    ap.add_argument("--pem", required=True)
    ap.add_argument("--bucket", required=True)
    ap.add_argument("--gcloud", default="gcloud")
    a = ap.parse_args()
    api = a.api.rstrip("/")
    pub = serialization.load_pem_public_key(Path(a.pem).read_bytes())

    def kms_ok(sig_b64: str, data: bytes) -> bool:
        try:
            pub.verify(b64d(sig_b64), data, ec.ECDSA(hashes.SHA256()))
            return True
        except Exception:
            return False

    def gcs_ls(prefix: str) -> list[str]:
        r = subprocess.run([a.gcloud, "storage", "ls", f"gs://{a.bucket}/{prefix}"], capture_output=True, text=True, shell=sys.platform == "win32")
        return [x for x in r.stdout.split() if x.startswith("gs://")]

    def gcs_put(path: str, data: bytes) -> None:
        with tempfile.NamedTemporaryFile(delete=False, suffix=".json") as f:
            f.write(data)
        subprocess.run([a.gcloud, "storage", "cp", f.name, f"gs://{a.bucket}/{path}", "--quiet"], check=True,
                       capture_output=True, shell=sys.platform == "win32")
        Path(f.name).unlink()

    with httpx.Client(timeout=60) as http:
        r = http.post(f"https://identitytoolkit.googleapis.com/v1/accounts:signUp?key={a.api_key}",
                      json={"returnSecureToken": True}, headers={"X-Ios-Bundle-Identifier": a.bundle_id})
        r.raise_for_status()
        id_token = r.json()["idToken"]
        auth = {"Authorization": f"Bearer {id_token}"}
        wid = None
        try:
            wid = http.post(f"{api}/v1/works", json={"title": "cloud checks", "displayName": "T11"}, headers=auth).json()["workId"]
            s = http.post(f"{api}/v1/works/{wid}/sessions", json={}, headers=auth).json()
            sid, token = s["sid"], s["startToken"]
            dev, other = Device(), Device()

            # ---------------------------------------------------- 開始の再送・同時実行
            print("== 開始")
            starts = in_threads(lambda i: http.post(f"{api}/v1/sessions/{sid}/start",
                                                    json={"startToken": token, "devicePubKey": dev.pub}), 3)
            check(all(x.status_code == 200 for x in starts), "同じ鍵で3つ同時に開始 → 3つとも 200")
            check(len({x.text for x in starts}) == 1, "3つとも同じ開始証")
            start = starts[0].json()
            check(kms_ok(start["sig"], b64d(start["startCert"])), "開始証の KMS 署名")
            r = http.post(f"{api}/v1/sessions/{sid}/start", json={"startToken": token, "devicePubKey": dev.pub})
            check(r.status_code == 200 and r.json() == start, "開始の再送 → 保存済みの開始証")
            r = http.post(f"{api}/v1/sessions/{sid}/start", json={"startToken": token, "devicePubKey": other.pub})
            check(r.status_code == 409 and r.json()["error"]["code"] == "TOKEN_USED", "違う鍵 → TOKEN_USED")
            prev = sha(b64d(start["startCert"]))

            # ---------------------------------------------------- チャンクの再送・同時送信
            print("== チャンク")
            c0, h0 = dev.chunk(sid, 0, prev)
            r1 = http.post(f"{api}/v1/sessions/{sid}/chunks", json=c0)
            r2 = http.post(f"{api}/v1/sessions/{sid}/chunks", json=c0)
            check(r1.status_code == r2.status_code == 200 and r1.json() == r2.json(), "seq 0 の再送 → 同じ受領証")
            check(kms_ok(r1.json()["sig"], b64d(r1.json()["receipt"])), "受領証の KMS 署名")

            c1, h1 = dev.chunk(sid, 1, h0)
            same = in_threads(lambda i: http.post(f"{api}/v1/sessions/{sid}/chunks", json=c1), 4)
            check(all(x.status_code == 200 for x in same), "seq 1 を4つ同時に送る → 4つとも 200")
            check(len({x.text for x in same}) == 1, "4つとも同じ受領証")
            check(len(gcs_ls(f"sessions/{sid}/receipts/000001.json")) == 1, "受領証のオブジェクトは1つ")

            a2, ha = dev.chunk(sid, 2, h1, t_end="2026-11-07T00:00:20.000Z")
            b2, hb_ = dev.chunk(sid, 2, h1, t_end="2026-11-07T00:00:21.000Z")
            diff = in_threads(lambda i: http.post(f"{api}/v1/sessions/{sid}/chunks", json=[a2, b2][i]), 2)
            codes = sorted(x.status_code for x in diff)
            check(codes == [200, 409] and any(x.status_code == 409 and x.json()["error"]["code"] == "SEQ_CONFLICT" for x in diff),
                  "seq 2 に違うヘッダを同時に送る → 片方だけ採用、もう片方は SEQ_CONFLICT")
            winner = [a2, b2][[x.status_code for x in diff].index(200)]
            h2 = ha if winner is a2 else hb_
            w = http.get(f"{api}/v1/works/{wid}", headers=auth).json()
            check(w["session"]["chunkCount"] == 3, f"chunkCount は 3（今は {w['session']['chunkCount']}）")

            # ---------------------------------------------------- 保存の直後に止まった場面
            print("== 途中停止からの復旧")
            c3, h3 = dev.chunk(sid, 3, h2)
            gcs_put(f"sessions/{sid}/chunks/000003.json", dumps(c3))  # チャンクだけがある（受領証の前に止まった）
            r = http.post(f"{api}/v1/sessions/{sid}/chunks", json=c3)
            check(r.status_code == 200 and json.loads(b64d(r.json()["receipt"]))["header"] == h3,
                  "チャンクだけがある seq 3 を再送 → 受領証ができる")
            w = http.get(f"{api}/v1/works/{wid}", headers=auth).json()
            check(w["session"]["chunkCount"] == 4, "先頭が進んで chunkCount は 4")
            c3b, _ = dev.chunk(sid, 3, h2, t_end="2026-11-07T00:00:39.000Z")
            r = http.post(f"{api}/v1/sessions/{sid}/chunks", json=c3b)
            check(r.status_code == 409 and r.json()["error"]["code"] == "SEQ_CONFLICT", "取り込み済みの seq 3 に違うヘッダ → SEQ_CONFLICT")

            c4, h4 = dev.chunk(sid, 4, h3, final=True)
            check(http.post(f"{api}/v1/sessions/{sid}/chunks", json=c4).status_code == 200, "最終チャンク")
            r = http.post(f"{api}/v1/sessions/{sid}/chunks", json=dev.chunk(sid, 5, h4)[0])
            check(r.status_code == 409 and r.json()["error"]["code"] == "SESSION_CLOSED", "最終チャンクの後 → SESSION_CLOSED")

            # ---------------------------------------------------- 確定の同時実行
            print("== 確定")
            fins = in_threads(lambda i: http.post(f"{api}/v1/works/{wid}/finalize", json={"declarationAccepted": True}, headers=auth), 3)
            check(all(x.status_code == 200 for x in fins), f"確定を3つ同時に呼ぶ → {[x.status_code for x in fins]}")
            ok = [x.json() for x in fins if x.status_code == 200]
            check(len({x["publicId"] for x in ok}) == 1, "同じ公開 ID")
            check(len({json.dumps(x["manifest"], sort_keys=True) for x in ok}) == 1, "同じ確定記録")
            check(len(gcs_ls(f"works/{wid}/bundle.json")) == 1, "bundle.json は1つ")
            pid = ok[0]["publicId"]
            m = ok[0]["manifest"]
            ms = m["sessions"][0]  # 【T14】確定記録 v:2
            check(m["v"] == 2 and len(m["sessions"]) == 1 and ms["chunks"]["count"] == 5 and ms["status"] == "completed", "確定記録の件数は 5・正常終了")
            again = http.post(f"{api}/v1/works/{wid}/finalize", json={"declarationAccepted": True}, headers=auth).json()
            check(again["publicId"] == pid and again["manifest"] == m, "確定の再送 → 保存済みの結果")
            b = http.get(f"{api}/v1/p/{pid}").json()
            check(kms_ok(b["manifest"]["sig"], b64d(b["manifest"]["bytes"])), "証拠一式の確定記録の KMS 署名")
            seqs = [json.loads(b64d(ch["header"]))["seq"] for ch in b["sessions"][0]["chunks"]]
            check(seqs == [0, 1, 2, 3, 4], "証拠一式のチャンクは seq 順で5件")
        finally:
            if wid:
                r = http.delete(f"{api}/v1/works/{wid}", headers=auth)
                check(r.status_code == 204, "後片づけ: 作品を削除")
            http.post(f"https://identitytoolkit.googleapis.com/v1/accounts:delete?key={a.api_key}",
                      json={"idToken": id_token}, headers={"X-Ios-Bundle-Identifier": a.bundle_id})

    ng = [w for ok, w in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(ng)} / {len(RESULTS)} OK")
    sys.exit(1 if ng else 0)


if __name__ == "__main__":
    main()
