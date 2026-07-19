<p align="center">
  <img src="assets/icon/kurage_icon.png" width="120" alt="Kurage アイコン">
</p>

# Kurage

Flutter 製の Mastodon クライアントです。
Android / Web / Windows を中心に、iOS / macOS / Linux もビルドできます。

> **English**: [README.en.md](README.en.md) — Kurage is a Mastodon client
> built with Flutter, with a switchable English / Japanese UI. It runs on
> Android, Web and Windows; iOS / macOS / Linux are buildable but less tested.
> Licensed under [Apache-2.0](LICENSE).

## 特徴

- **マルチアカウント / マルチカラム** — 複数アカウント・複数タイムラインを 1 カラムにマージ表示も可能
- **ストリーミング (SSE)** — 新着の即時反映。切断検知・自動再接続・取り逃しのギャップ復旧つき
- **プッシュ通知** — FCM + セルフホスト可能な Cloudflare Worker リレー ([worker/](worker/)) 経由
- **引用表示** — Mastodon 4.4 公式の引用形式に対応、Misskey / Fedibird 互換のフォールバックあり
- カスタム絵文字・リアクション、投稿の翻訳、フィルタ、リスト、予約投稿、下書き
- 通知グループ、DM (会話)、検索、ブックマーク・お気に入り一覧
- **アプリロック** — PIN / 生体認証 (オプション)
- **フルバックアップ / 復元** — 設定・カラム・アカウントを JSON で別端末へ移行
- ボスキー (ワンタップでそれっぽい画面に偽装するあれ)
- ダーク / ライトテーマ、テーマカラー・フォント・絵文字サイズの調整
- **日本語 / 英語 UI 切替** — 既定は端末言語に追従、設定 → 外観設定で変更可能

<!-- TODO: スクリーンショットを追加 (docs/screenshots/ に配置して参照) -->

## 対応プラットフォーム

| プラットフォーム | 状態 |
|---|---|
| Android | ✅ 主対応。Google Play で配信 |
| Web | ✅ [kurage.demo2.jp](https://kurage.demo2.jp) で公開 |
| Windows | ✅ インストーラー / ポータブル zip を [GitHub Releases](https://github.com/demodemo0818/kurage/releases) で配布 |
| iOS / macOS / Linux | ⚠️ ビルド可能だが未検証・未配布 |

## ビルド方法

必要なもの: **Flutter SDK 3.41 以上** (Dart 3.11 以上)

```bash
git clone https://github.com/demodemo0818/kurage.git
cd kurage

# Firebase 設定はテンプレートからコピー (ダミー値のままでビルド・起動可能)
cp lib/firebase_options.dart.example lib/firebase_options.dart
cp android/app/google-services.json.example android/app/google-services.json

flutter pub get
flutter run            # 接続中のデバイスで実行
flutter run -d chrome  # Web
flutter run -d windows # Windows デスクトップ
```

- ダミーの Firebase 設定でもアプリは完全に動作します (プッシュ通知と Analytics が無効になるだけ)。
- プッシュ通知を自分の環境で動かすには、自分の Firebase プロジェクトと
  リレー ([worker/](worker/)) のセルフホストが必要です。
  [PUSH_NOTIFICATION_SETUP.md](PUSH_NOTIFICATION_SETUP.md) と
  [worker/README.md](worker/README.md) を参照してください。
- Windows デスクトップビルドに必要なツールチェーン (Visual Studio 2022 ほか) は
  [CLAUDE.md](CLAUDE.md) の「Windows (デスクトップ)」の節にまとまっています。
- アーキテクチャの詳細 (状態管理・API レイヤー・既知の罠) も [CLAUDE.md](CLAUDE.md) が
  最も詳しいドキュメントです。

## 開発

```bash
flutter analyze   # 静的解析 (0 issues を維持)
flutter test      # unit test
```

バグ報告・提案は Issue へ。変更の提案は [CONTRIBUTING.md](CONTRIBUTING.md) を
一読してから PR をお送りください。

## ライセンス

[Apache License 2.0](LICENSE)

「Kurage」の名称およびアプリアイコンは、Apache-2.0 のライセンス対象に含まれません
(同ライセンス第 6 条参照)。フォークを配布する場合は別の名称・アイコンを使用してください。
