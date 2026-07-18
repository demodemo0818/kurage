# Kurage Push Relay

Mastodon の Web Push 通知を Firebase Cloud Messaging (FCM) 経由で
Kurage Android アプリへ転送する Cloudflare Worker。

## アーキテクチャ

```
[mastodon.demo2.jp]
    │ POST /relay/<fcm_token>  (aes128gcm 暗号化ペイロード)
    ▼
[Cloudflare Worker (このリポジトリ)]
    │ 1. Web Push を ECDH + HKDF + AES-GCM で復号
    │ 2. Service Account JWT で FCM アクセストークン取得
    │ 3. FCM HTTP v1 API へ data メッセージとして転送
    ▼
[FCM] → [Android 端末]
```

ECDH 鍵ペアは Worker で 1 セットだけ持ち、全アプリインスタンスで共有する方式
（toot-relay 風）。`auth_secret` も同様。

## セットアップ

### 1. 依存インストール

```powershell
npm install
```

### 2. Cloudflare ログイン

```powershell
npx wrangler login
```

ブラウザが開いて Cloudflare 認証が走る。

### 3. 鍵生成

```powershell
node scripts/generate-keys.mjs
```

出力された `ECDH_PRIVATE_KEY_PKCS8_B64` / `ECDH_PUBLIC_KEY_RAW_B64URL` /
`AUTH_SECRET_B64URL` の 3 値を後で Secret として登録。**安全な場所に保存しておく**
（再生成すると既存の購読が全部無効になる）。

### 4. Firebase Service Account 鍵を取得

Firebase Console → プロジェクト設定 → サービスアカウント →
「**新しい秘密鍵を生成**」で JSON をダウンロード。

中身に以下の値があることを確認:

- `project_id` → `kurage-for-mastodon`
- `client_email` → `firebase-adminsdk-xxx@kurage-for-mastodon.iam.gserviceaccount.com`
- `private_key` → `-----BEGIN PRIVATE KEY-----\n...`

### 5. Worker Secret 登録

各値を 1 つずつ `wrangler secret put` で登録（プロンプトで値を貼る）:

```powershell
npx wrangler secret put FIREBASE_PROJECT_ID
npx wrangler secret put FIREBASE_CLIENT_EMAIL
npx wrangler secret put FIREBASE_PRIVATE_KEY
npx wrangler secret put ECDH_PRIVATE_KEY_PKCS8_B64
npx wrangler secret put ECDH_PUBLIC_KEY_RAW_B64URL
npx wrangler secret put AUTH_SECRET_B64URL
```

`FIREBASE_PRIVATE_KEY` は PEM 全文（改行込み or `\n` エスケープ済み、どちらも対応）。

### 6. デプロイ

```powershell
npm run deploy
```

成功すると `https://kurage-push-relay.<your-account>.workers.dev` のような URL が出る。
これを Flutter アプリ側に設定する。

## 動作確認

```powershell
# 公開鍵が取れるか
curl https://kurage-push-relay.<your-account>.workers.dev/pubkey

# auth_secret が取れるか
curl https://kurage-push-relay.<your-account>.workers.dev/auth
```

実際の Push 動作確認は Flutter アプリ側で `/api/v1/push/subscription` 登録 → Mastodon でメンション等を発生させて確認。

## 既知のセキュリティ上のトレードオフ

全クライアントで ECDH 鍵ペア + `auth_secret` を共有し、`/pubkey` `/auth` を
無認証 GET で公開する設計のため、以下のリスクがある:

- **通知の偽装**: 暗号化に必要な材料 (公開鍵 + auth_secret) が公開なので、
  対象端末の FCM トークンを知っている第三者は「正規に復号できる偽 push」を
  `/relay/{fcm_token}` に直接 POST できる。FCM トークン自体が秘密であることが
  実質的な防壁。アプリ側でトークンをログ等に出さないこと。
- **オープンリレー**: `/relay/` に認証・レート制限が無いので、スパム転送の
  踏み台にされ得る (FCM 送信は自プロジェクトの quota を消費する)。
  Cloudflare ダッシュボードの WAF レートリミットルールを `/relay/*` に
  設定しておくことを推奨。

根本対策はクライアント (購読) ごとに検証トークンを発行して URL パスに含め、
relay 側で照合する方式だが、未実装。

## 鍵をローテートしたい場合

`generate-keys.mjs` を再実行して 3 値を新規発行 → `wrangler secret put` で上書き。
ただし**既存購読は全部無効になる**ので、アプリ側で再購読が必要。

## ログ確認

```powershell
npm run tail
```

リアルタイムで Worker のログがストリーミングされる（FCM 失敗、復号エラー等）。
