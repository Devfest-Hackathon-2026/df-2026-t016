"""公開済み作品の旧補足説明を、画像比較の注意点に置き換える。"""

from __future__ import annotations

import argparse
import json
import subprocess

from google.api_core.exceptions import NotFound
from google.cloud import firestore, storage
from google.oauth2.credentials import Credentials

from app.repo.base import PUBLICS, REVIEW_VERSION, WORKS
from app.repo.firestore import FirestoreRepo
from app.services.finalize import bundle_path, manifest_of
from app.services.gemini import GeminiExplainer
from app.services.review import review_pairs
from app.store.gcs import GcsStore


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--gcloud-auth", action="store_true", help="gcloud のログインを使う")
    parser.add_argument("--apply", action="store_true", help="注意点を保存し、旧補足説明を削除する")
    args = parser.parse_args()

    credentials = None
    if args.gcloud_auth:
        token = subprocess.check_output(
            ["gcloud", "auth", "print-access-token", "--project", args.project], text=True,
        ).strip()
        credentials = Credentials(token, quota_project_id=args.project)

    client = storage.Client(project=args.project, credentials=credentials)
    bucket = client.bucket(f"{args.project}-trace")
    store = GcsStore(bucket.name, client=client)
    repo = FirestoreRepo(client=firestore.Client(project=args.project, credentials=credentials))
    explainer = None
    if args.apply:
        explainer = GeminiExplainer(
            args.project, "global", "gemini-3.8-flash", timeout_sec=80, credentials=credentials, attempts=5,
        )
    failed = 0

    for work_id, work in repo.query_eq(WORKS, "status", "finalized"):
        public_id = work.get("publicId")
        public = repo.get(PUBLICS, public_id) if public_id else None
        if not public or public.get("workId") != work_id:
            continue
        try:
            if work.get("reviewVersion") == REVIEW_VERSION:
                print(f"{public_id}: 更新済み", flush=True)
            else:
                raw = store.get(bundle_path(work_id))
                if raw is None:
                    raise ValueError("証拠一式が見つかりません")
                bundle = json.loads(raw)
                manifest = manifest_of(bundle)
                if manifest["workId"] != work_id:
                    raise ValueError("証拠一式の作品 ID が一致しません")
                pairs = review_pairs(store, bundle, manifest)
                if explainer is None:
                    print(f"{public_id}: 候補 {len(pairs)}組", flush=True)
                    continue
                note = explainer(pairs)
                if not repo.replace_explanation(work_id, public_id, note):
                    print(f"{public_id}: 公開状態が変わったためスキップ", flush=True)
                    continue
                print(f"{public_id}: 候補 {len(pairs)}組 / {'注意点あり' if note['text'] else '注意点なし'}", flush=True)
                if note["text"]:
                    print(note["text"], flush=True)
            if args.apply:
                try:
                    bucket.blob(f"works/{work_id}/explanation.json").delete()
                except NotFound:
                    pass
        except Exception as exc:
            failed += 1
            print(f"{public_id}: 更新できませんでした ({type(exc).__name__}: {exc})", flush=True)

    return int(failed > 0)


if __name__ == "__main__":
    raise SystemExit(main())
