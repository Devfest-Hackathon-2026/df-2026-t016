#!/usr/bin/env bash
# 受付API を Cloud Run（trace-api）にデプロイする。リポジトリのルートで実行する。
#   PROJECT_ID=drawtrace-gg2026 bash server/deploy.sh
set -euo pipefail
: "${PROJECT_ID:?PROJECT_ID を指定してください}"
REGION=asia-northeast1
TAG="$(git rev-parse --short HEAD 2>/dev/null || date +%s)"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/cloud-run-source-deploy/trace-api:${TAG}"
KMS_KEY_VERSION="projects/${PROJECT_ID}/locations/${REGION}/keyRings/trace/cryptoKeys/trace-signer/cryptoKeyVersions/1"

gcloud builds submit --project "$PROJECT_ID" --config server/cloudbuild.yaml --substitutions "_IMAGE=${IMAGE}" .

gcloud run deploy trace-api --project "$PROJECT_ID" --region "$REGION" --image "$IMAGE" \
  --service-account "trace-api@${PROJECT_ID}.iam.gserviceaccount.com" --allow-unauthenticated --memory 1Gi \
  --set-env-vars "SIGNER=kms,KMS_KEY_VERSION=${KMS_KEY_VERSION},STORE=gcs,BUCKET=${PROJECT_ID}-trace,REPO=firestore,AUTH=firebase,PROJECT_ID=${PROJECT_ID},APP_CHECK=${APP_CHECK:-off},GEMINI_MODEL=${GEMINI_MODEL:-gemini-3.8-flash},GEMINI_LOCATION=${GEMINI_LOCATION:-global}" \
  --quiet
