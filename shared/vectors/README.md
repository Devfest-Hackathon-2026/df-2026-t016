# テストベクタ

`signing.json` は `generate_vectors.py` で作る。**鍵はテスト専用で、本番では使わない。**

```bash
python shared/vectors/generate_vectors.py
```

秘密鍵は固定値で、ECDSA は RFC 6979（決定的）なので、何度動かしても同じファイルになる。再生成後に `git diff -- shared/vectors/signing.json` で差分を確認できる。

## 中身
| キー | 内容 |
|---|---|
| `deviceKey` | 端末役の P-256 の鍵。`privateHex`（32バイト）と `publicX963`（65バイトの base64） |
| `canonical` | 正準 JSON の見本（日本語・スラッシュ・エスケープを含む） |
| `startCert` | 開始証。`obj`・`bytes`（b64）・`sha256`・`sig`（KMS 役の DER） |
| `body` | チャンクの本文。`tilesSet` は立っているタイル番号（`i = y*32 + x`） |
| `header` | seq=0 のヘッダ。`prev` は開始証のハッシュ、`body` は本文のハッシュ |
| `deviceSig` | `header.bytes` への端末署名（r‖s の b64） |
| `imageSig` | `image:{sid}:{sha256}` への端末署名（r‖s の b64） |
| `receipt` | 受領証と KMS 役の DER 署名 |
| `kmsKey` | KMS 役のテスト鍵。`privateHex`（32バイト）と `publicPem`（公開鍵 SPKI）。テスト時に必要な形式へ変換する |
| `derToRs` | DER と r‖s の組を3つ（33バイト・31バイト・30バイトの整数を含む） |

## Swift（T03）
Swift で `header.bytes` に署名した結果を `swift_signature.json` に置くと、Python と web のテストがそれも検証する。

```json
{"publicX963": "<x963Representation の b64>", "sig": "<rawRepresentation の b64>", "header": "<省略可。省略時は signing.json の header.bytes>"}
```
