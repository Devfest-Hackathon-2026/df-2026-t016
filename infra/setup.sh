#!/usr/bin/env bash
# Google Cloud・Firebase の準備（tasks/T02）。何度実行しても同じ結果になる。
#
#   PROJECT_ID=... [MEMBER_EMAIL=...] [BUNDLE_ID=...] [BILLING_ACCOUNT=... BUDGET_JPY=5000] bash infra/setup.sh
#
# 前提: gcloud auth login、firebase login 済み。課金が有効なプロジェクト。
set -euo pipefail

: "${PROJECT_ID:?PROJECT_ID を指定してください}"
REGION="asia-northeast1"
BUCKET="${PROJECT_ID}-trace"
KEYRING="trace"
KEY="trace-signer"
SA_NAME="trace-api"
SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
BUNDLE_ID="${BUNDLE_ID:-com.ggdevfest2026.drawtrace}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log() { printf '\n== %s\n' "$*"; }
g() { gcloud --project "$PROJECT_ID" --quiet "$@"; }

gcloud config set project "$PROJECT_ID" >/dev/null

# ---------------------------------------------------------------- 1. API
log "API を有効にする"
g services enable \
  run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  firestore.googleapis.com storage.googleapis.com cloudkms.googleapis.com \
  aiplatform.googleapis.com firebase.googleapis.com identitytoolkit.googleapis.com \
  firebasehosting.googleapis.com firebaseappcheck.googleapis.com \
  iam.googleapis.com billingbudgets.googleapis.com

# ---------------------------------------------------------------- 2. メンバー・予算
if [[ -n "${MEMBER_EMAIL:-}" ]]; then
  log "メンバーを追加する: $MEMBER_EMAIL"
  for role in roles/editor roles/firebase.admin; do
    g projects add-iam-policy-binding "$PROJECT_ID" \
      --member "user:${MEMBER_EMAIL}" --role "$role" --condition=None >/dev/null
  done
fi

if [[ -n "${BILLING_ACCOUNT:-}" ]]; then
  log "予算アラート（月 ${BUDGET_JPY:-5000} 円）"
  NAME="drawtrace-${PROJECT_ID}"
  if ! gcloud billing budgets list --billing-account "$BILLING_ACCOUNT" --format='value(displayName)' | grep -qx "$NAME"; then
    gcloud billing budgets create --billing-account "$BILLING_ACCOUNT" \
      --display-name "$NAME" --budget-amount "${BUDGET_JPY:-5000}JPY" \
      --filter-projects "projects/${PROJECT_ID}" \
      --threshold-rule percent=0.5 --threshold-rule percent=0.9 --threshold-rule percent=1.0
  fi
fi

# ---------------------------------------------------------------- 3. Firestore
log "Firestore（ネイティブ、$REGION）"
if ! g firestore databases describe --database='(default)' >/dev/null 2>&1; then
  g firestore databases create --database='(default)' --location="$REGION" --type=firestore-native
fi

# ---------------------------------------------------------------- 4. Cloud Storage
log "バケット gs://$BUCKET"
if ! g storage buckets describe "gs://$BUCKET" >/dev/null 2>&1; then
  g storage buckets create "gs://$BUCKET" --location="$REGION" \
    --uniform-bucket-level-access --public-access-prevention
fi
g storage buckets update "gs://$BUCKET" --uniform-bucket-level-access --public-access-prevention >/dev/null

# ---------------------------------------------------------------- 5. Cloud KMS
log "KMS（$KEYRING/$KEY）"
g kms keyrings describe "$KEYRING" --location "$REGION" >/dev/null 2>&1 \
  || g kms keyrings create "$KEYRING" --location "$REGION"
g kms keys describe "$KEY" --keyring "$KEYRING" --location "$REGION" >/dev/null 2>&1 \
  || g kms keys create "$KEY" --keyring "$KEYRING" --location "$REGION" \
       --purpose asymmetric-signing --default-algorithm ec-sign-p256-sha256 --protection-level software

# 鍵の版1が使えるようになるまで待つ
for _ in $(seq 1 30); do
  state=$(g kms keys versions describe 1 --key "$KEY" --keyring "$KEYRING" --location "$REGION" --format='value(state)' 2>/dev/null || true)
  [[ "$state" == "ENABLED" ]] && break
  sleep 2
done
KMS_KEY_VERSION="projects/${PROJECT_ID}/locations/${REGION}/keyRings/${KEYRING}/cryptoKeys/${KEY}/cryptoKeyVersions/1"

mkdir -p "$ROOT/shared/keys" "$ROOT/web/src/config"
g kms keys versions get-public-key 1 --key "$KEY" --keyring "$KEYRING" --location "$REGION" \
  --output-file "$ROOT/shared/keys/kms_public.pem"
cp "$ROOT/shared/keys/kms_public.pem" "$ROOT/web/src/config/kms_public.pem"

# ---------------------------------------------------------------- 6. サービスアカウント
log "サービスアカウント $SA"
g iam service-accounts describe "$SA" >/dev/null 2>&1 \
  || g iam service-accounts create "$SA_NAME" --display-name "DrawTrace 受付API"

for _ in $(seq 1 10); do g iam service-accounts describe "$SA" >/dev/null 2>&1 && break; sleep 3; done

for role in roles/cloudkms.signer roles/cloudkms.publicKeyViewer; do
  g kms keys add-iam-policy-binding "$KEY" --keyring "$KEYRING" --location "$REGION" \
    --member "serviceAccount:$SA" --role "$role" >/dev/null
done
g storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member "serviceAccount:$SA" --role roles/storage.objectAdmin >/dev/null
# tokenVerifier は App Check の使い切りの確認に要る（T12。APP_CHECK=required のときだけ使う）
for role in roles/datastore.user roles/aiplatform.user roles/firebaseappcheck.tokenVerifier; do
  g projects add-iam-policy-binding "$PROJECT_ID" \
    --member "serviceAccount:$SA" --role "$role" --condition=None >/dev/null
done

# ---------------------------------------------------------------- 7. Cloud Run（healthz の雛形）
if [[ "${SKIP_RUN:-}" != "1" ]]; then
  log "Cloud Run trace-api（healthz の雛形。T04 で本体に置き換える）"
  g run deploy trace-api --source "$ROOT/infra/healthz" --region "$REGION" \
    --service-account "$SA" --allow-unauthenticated
fi
API_BASE_URL=$(g run services describe trace-api --region "$REGION" --format='value(status.url)' 2>/dev/null || true)

# ---------------------------------------------------------------- 8. Firebase
if [[ "${SKIP_FIREBASE:-}" != "1" ]]; then
  log "Firebase"
  if ! firebase projects:list --json | grep -q "\"projectId\": *\"$PROJECT_ID\""; then
    firebase projects:addfirebase "$PROJECT_ID"
  fi

  # 匿名ログインを有効にする（Identity Toolkit の設定）
  TOKEN=$(gcloud auth print-access-token)
  curl -sf -X PATCH \
    -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $PROJECT_ID" -H "Content-Type: application/json" \
    "https://identitytoolkit.googleapis.com/admin/v2/projects/${PROJECT_ID}/config?updateMask=signIn.anonymous.enabled" \
    -d '{"signIn":{"anonymous":{"enabled":true}}}' >/dev/null \
    || echo "!! 匿名ログインを API で有効にできませんでした。コンソールの Authentication で有効にしてください"

  # iOS アプリ
  if ! firebase apps:list IOS --project "$PROJECT_ID" --json | grep -q "\"bundleId\": *\"$BUNDLE_ID\""; then
    firebase apps:create IOS DrawTrace --bundle-id "$BUNDLE_ID" --project "$PROJECT_ID"
  fi
fi
HOSTING_URL="https://${PROJECT_ID}.web.app"

# ---------------------------------------------------------------- 出力
log "構築したリソース"
cat <<EOF
PROJECT_ID=$PROJECT_ID
REGION=$REGION
API_BASE_URL=$API_BASE_URL
HOSTING_URL=$HOSTING_URL
BUCKET=$BUCKET
KMS_KEY_VERSION=$KMS_KEY_VERSION
SERVICE_ACCOUNT=$SA
EOF
