# 試験データ（T06）

検証ページ（T09）を、iOS や本物のサーバを待たずに作って試すための証拠一式です。**鍵は `shared/vectors/signing.json` のテスト用の鍵で、本番では使いません。**

```bash
pip install -r tools/fixtures/requirements.txt
python tools/fixtures/generate.py --out web/public/fixtures
```

- ECDSA は RFC 6979（決定的）、乱数は種を固定しているので、同じ環境なら何度動かしても同じファイルになります。
- JPEG・PNG のバイト列は Pillow の版で変わりうるので、版を `requirements.txt` で固定しています。版が違うと画像のハッシュが変わり、`bundle.json` も変わります（中身の意味は同じ）。
- できたものは `web/public/fixtures/` に入れ、git に入れます（合計 4.4MB。上限 8MB）。
- 検証ページでは `?fixture=normal` のように開きます（T09）。

## できるもの
```
web/public/fixtures/index.json            一覧と説明
web/public/fixtures/{name}/bundle.json    証拠一式（共通仕様7章）
web/public/fixtures/{name}/start.jpg      開始画面
web/public/fixtures/{name}/end.jpg        終了画面（no_end_image・aborted には無い）
web/public/fixtures/{name}/png.jpg        提出された PNG の表示用の縮小画像
web/public/fixtures/{name}/original.png   「手元の PNG」として検証ページに落とす用
web/public/fixtures/{name}/expected.json  verifyBundle が返すべき結果（T09 の VerifyResult）
```

共通の作り:
- チャンクは5秒おきに120件（10分ぶん）。受信時刻は 開始 + 5秒 ×（seq + 1）に 0.04〜0.4秒の揺らぎを足したもの。
- 線を描いている区間（seq 8〜35、44〜80、88〜116）だけ、本文の `frames` に値が入る。
- キャンバスは 1600×1200 の白に線。終了画面は 1024×768 の「アプリの画面風」の枠（上と左に灰色の帯）に縮小して置いたもの。
- 確定記録の `match` は表の値を書き込んだもの（照合の計算は T08）。

## 14種類
| 名前 | 作り方 | 整合性 | ほかの期待 |
|---|---|---|---|
| `normal` | そのまま | 一致 | 正常終了、外観は一致、手元の PNG はハッシュ一致 |
| `gap` | seq 60 と 61 の受信の間を約65秒あける | 一致 | 受信の空き1か所（`after: 60`） |
| `missing_chunk` | seq 40 を抜く | つながりの切れ | problems: seq 41 の `chain`、`count` |
| `tampered_header` | seq 30 のヘッダの `tEnd` の1文字を変える（署名はそのまま） | 署名の不一致 | problems: seq 30 の `signature`、seq 31 の `chain` |
| `tampered_body` | seq 50 の本文の `frames` の数字を1文字変える | 内容の不一致 | problems: seq 50 の `hash` |
| `truncated` | 最後の2件を消す（確定記録はそのまま） | 確定記録との不一致 | problems: `count` |
| `aborted` | 最終チャンクなし、`status: aborted`。終了画面もない | 一致 | 異常終了、`images.end: none`、外観は未確認 |
| `other_png` | 手元の PNG が別の絵（確定記録の PNG のハッシュは元の絵）。縮小画像も別の絵 | 一致 | 外観は不一致、手元の PNG はハッシュ不一致 |
| `similar_png` | 手元の PNG に3本の線を足す | 一致 | 外観は一致、手元の PNG はハッシュ不一致 |
| `no_end_image` | 終了画面なし（`images.end: null`、`files.end: null`） | 一致 | `images.end: none`、外観は未確認、未確認事項に「終了画面がない」 |
| `whole_normal` | `normal` に、描き進めた全体画像を6枚（seq 10・30・50・70・90・110） | 一致 | つながりはすべて確認、PNG へも確認 |
| `whole_switched` | 4枚目（seq 70）だけ別の絵 | 一致 | 2→3 と 3→4 が確認できず（「別の絵」とは出さない） |
| `whole_tampered` | `whole-2.jpg` を、見た目が同じで中身の違う画像に差し替える | 内容の不一致 | problems: seq 50 の `image` |
| `multi_declared` | 【11/8】`multi_session` と同じ記録で、作者の申告が版2（`aiUse: partial`、詳細あり） | 一致 | 申告の文言と詳細を出す（`expected.json` の `declaration` は文言と時刻だけ） |
| `whole_hidden` | 載せない設定（`shown: false`、`files.whole: null`、画像は置かない） | 一致 | 各項目は `hidden`、未確認事項に「途中の全体画像は公開されていないため、画像のハッシュは確かめていません」 |

## expected.json の決め方（T09 の verifyBundle も同じにする）
`problems` は、次の手順で、見つけた順に並べる。**同じ（seq, kind）の組は1つにまとめる**（例: seq 41 は `prev` も `seq` の抜けも合わないが、`chain` 1つ）。seq の無い問題（件数など）も kind ごとに1つ。

1. `kms.publicKeyPem` が埋め込みの公開鍵と違う → `key`
2. 確定記録・開始証の KMS 署名 → `signature`（seq なし）
3. チャンクごとに、並んでいる順に:
   1. 端末署名 → `signature`
   2. 受領証の署名、受領証の `header` と `sha256(header)` の一致 → `signature`
   3. 受領証の `seq` とヘッダの `seq`、`prev`（最初は開始証のハッシュ、以降は前のヘッダのハッシュ）、`seq` が前＋1 → `chain`
   4. 本文のハッシュと長さ → `hash`
4. 件数・先頭・末尾が確定記録と合わない → `count`（1つ）
5. 受領証の時刻から計算し直した受信の空き（30秒超、秒は小数3桁に丸める）が確定記録の `gaps` と合わない → `gap`
6. 開始画面・終了画面: 確定記録が `null` なら `none`（問題にしない。未確認事項に「開始画面がない」「終了画面がない」）。ファイルが取れない → `missing`。ハッシュが違う → `image`

7. 途中の全体画像（T13）: ヘッダの `images.whole` の並び（seq と sha256）が確定記録の `whole.items` と違う → `count`。載せる設定なら、届いている各画像を `files.whole[i]` から取り、取れない → `missing`、ハッシュが違う → `image`（どちらもその seq）

`status` は、problems の kind のうち、表の上にあるものを採る（資料不足 → 署名の不一致 → 内容の不一致 → つながりの切れ → 確定記録との不一致 → 一致）。

テストで比べるのは `detail` 以外。`detail` は人が読むための文なので、T09 で文言を変えてよい。

## 確かめ方
`server/tests/test_fixtures.py` が、T09 の手順を Python で書いたもので10種類を検証し、`expected.json` と一致すること、`normal` の署名がすべて通ること、スキーマに合うこと、合計が5MB 以内であることを確かめます（CI でも回る）。

## 全体画像（T13）
- 全体画像の画面は、共通の試験画像（`tools/whole_vectors/generate.py`）と同じ作り方で、JPEG の品質60。
- 確定記録の `whole` は `server/app/services/whole.py` の `judge_whole` で計算する。表の期待（つながりの結果）にならなければ、生成を止める。
- `expected.json` の `whole.items[].minutes` は、その seq の受領証の時刻の、受信開始からの分（JS の `Math.round` と同じ丸め）。
- 合計の上限は 8MB（T13 で 5MB から上げた。今は 4.4MB）。
