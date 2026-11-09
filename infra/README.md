# Google Cloud と Firebase のセットアップ

独自の環境を用意する場合は、Google Cloud プロジェクトを作り、Google Cloud CLI と Firebase CLI でログインします。以下のコマンドはリポジトリのルートから実行します。

```bash
gcloud auth login
firebase login
export PROJECT_ID=your-google-cloud-project-id
bash infra/setup.sh
```

セットアップスクリプトは、東京リージョンの Cloud Run、Firestore、Cloud Storage、Cloud KMS と、Firebase を準備します。Firebase を初めて使うアカウントでは、コンソールで Firebase の利用を開始してください。Authentication のログイン方法では匿名認証を有効にします。[Firebase コンソール](https://console.firebase.google.com/)

## API と Web

Cloud KMS の公開鍵は `shared/keys/kms_public.pem` と `web/src/config/kms_public.pem` に書き出されます。ブラウザはこの鍵で署名を検証します。環境を切り替えるときは、配信する Web と API で同じ鍵を使ってください。

```bash
firebase deploy --only firestore:rules --project "$PROJECT_ID"
bash server/deploy.sh
(cd web && npm ci && npm run build)
firebase deploy --only hosting --project "$PROJECT_ID"
```

`firebase.json` で `/v1/**` を Cloud Run の `trace-api` に転送します。Gemini の既定は `gemini-3.8-flash`、ロケーションは `global` です。

## iPad

`ios/DrawTrace/DrawTrace.xcodeproj` を Xcode で開き、本体アプリと録画拡張に自分の開発チームを設定します。両ターゲットで同じ App Group を使ってください。自分の Firebase プロジェクトで iOS アプリを登録し、SDK 設定の `GoogleService-Info.plist` を本体アプリのターゲットに追加します。API と Hosting の URL は `ios/Config/Base.xcconfig` を参照し、開発環境ごとの値は `ios/Config/Local.xcconfig` に設定できます。
