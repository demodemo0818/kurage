# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

Flutter 製の Mastodon クライアント **Kurage** （pubspec name: `kurage`、Android applicationId: `jp.demo2.kurage`）。Android / iOS / Web / Windows / macOS / Linux 対応。日本語 UI（`flutter_localizations` で ja/en サポート）。

**v1.0.0 正式版リリース済み・OSS 公開済み** (Apache-2.0、https://github.com/demodemo0818/kurage )。バージョン番号・タグ・リリース手順のルールは [RELEASING.md](RELEASING.md) を参照。`pubspec.yaml` の `version:` を編集する時は必ず同ドキュメントに従う（特に `+BUILD` は monotonic 通し番号で必ず +1）。「Kurage」の名称とアプリアイコンは Apache-2.0 の許諾対象外（README 参照）。

リリースビルドは Claude 側で「コミット → タグ → push → `flutter build appbundle --release` → 署名検証 → `dist/kurage-vX.Y.Z*.aab` へコピー → Web ビルド + デプロイ」まで実施する (Windows は `v*` タグ push で GitHub Actions が自動ビルドして GitHub Release に添付)。**Play Console への AAB アップロードと `adb install` はユーザー側で行う** 運用。勝手に `adb install` しないこと。

## ツールチェーン要件

- **Flutter SDK ≧ 3.41**（Dart ≧ 3.11）。`intl: ^0.20.2` が `flutter_localizations` 経由で要求するため。古い Flutter（3.29 等）では依存解決失敗。
- **Android NDK 28.2.13676358**（[android/app/build.gradle.kts](android/app/build.gradle.kts) で固定）。Firebase / Crashlytics ほか native コードを持つプラグインが要求する最大バージョンに揃えてある。プラグイン更新で「different Android NDK version」エラーが出たら、要求された最大値に追従して上げる。
- **AGP ≧ 8.12.1 / Kotlin 2.2.0**（[android/settings.gradle.kts](android/settings.gradle.kts)）。share_plus 12+ / package_info_plus 9+ が要求する (Kotlin 2.2 でコンパイルされた AAR を含むため、古い Kotlin だと metadata 非互換でビルド失敗する)。Gradle wrapper は 8.13。
- **Core library desugaring 有効**（同 build.gradle.kts、`desugar_jdk_libs:2.0.4`）。`flutter_local_notifications` の Java 8+ API 用。

## 主要コマンド

```powershell
# 初回 clone 時のみ: Firebase 設定をテンプレートから配置 (実ファイルは git 管理外)
cp lib/firebase_options.dart.example lib/firebase_options.dart
cp android/app/google-services.json.example android/app/google-services.json

flutter pub get                         # 依存関係インストール
flutter run                             # 接続中のデバイス／エミュレータで実行
flutter run -d chrome                   # Web で実行
flutter run -d windows                  # Windows デスクトップで実行
flutter analyze                         # 静的解析
flutter test                            # 純粋ロジック (models / utils) の unit test
flutter clean                           # ビルドキャッシュ削除（Flutter SDK アップグレード後やアセット変更後に推奨）
flutter build apk                       # Android リリースビルド
dart run flutter_launcher_icons         # アプリアイコン再生成 (pubspec.yaml の設定キーは 0.13+ の `flutter_launcher_icons:`)
```

`test/` に unit test あり。`flutter test` で実行し、`.github/workflows/ci.yml` が push / PR (→ main) 時に自動実行する。2 階層ある:

- **純粋ロジック (models / utils)**: プラグイン初期化なしに動かせる純粋 Dart のパース・変換・マージロジック。新規テストは [test/models/status_test.dart](test/models/status_test.dart) のパターン (最小オブジェクトを直接組む or 最小 JSON Map を使う) に倣う。
- **API レイヤー / プロバイダ**: [mastodon_api.dart](lib/services/mastodon_api.dart) の HTTP は全てトップレベル変数 `httpClient` (テスト用 seam) 経由なので、テストから `MockClient` に差し替えて偽レスポンスを返せる。Completer でレスポンスをゲートすれば非同期競合 (フェッチ in-flight 中の状態変更) も決定的に再現できる。パターンは [test/providers/notifications_provider_race_test.dart](test/providers/notifications_provider_race_test.dart) に倣う (SharedPreferences は `setMockInitialValues`、SSE は flutter_test の HTTP 遮断で接続失敗するだけなので container.dispose で後始末)。Hive (`_cacheBox`) を触る関数 (タイムライン系) のテストは別途 Hive の初期化が必要な点に注意。

UI (widget) の自動テストは現状なし (timeline_view / post_tile はサイズと依存の都合でコスト高。検証は実機/手動)。

## アーキテクチャ

### 状態管理: Riverpod
全永続状態を `lib/providers/` 配下の `StateNotifierProvider` で管理。`main.dart` で `ProviderScope` をルートに配置。

主な Provider：
- [authProvider](lib/providers/auth_provider.dart) — マルチアカウント認証情報のリストのみ。各アカウントに `accountColor` 割当。`SharedPreferences['accounts']` に永続化。**「current アカウント (= プライマリ)」概念は廃止**。各画面が必要に応じて (a) ローカル state + SharedPreferences で「最後に使ったアカウント」を覚える (post_page の `post_last_used_accounts` / search_page の `search_last_account_id`)、(b) 明示的な `accountId` パラメタで指定する (post_tile / thread_page など)、(c) `accounts.first` フォールバックを使う、のいずれかで対処する。
- [columnProvider](lib/providers/column_provider.dart) — マルチカラムタイムライン設定。`SharedPreferences['columns']`。
- [settingsProvider](lib/providers/settings_provider.dart) — 外観・挙動設定（`themeMode` (light/dark/system 3 択。旧 `isDarkMode` (bool) からの後方互換読み込みあり)、テーマカラー、フォント、絵文字倍率、CW自動展開、スリープ無効、絵文字アニメ無効、デフォルト投稿言語、リアクション数表示、折りたたみ行数、`streamingEnabled` (SSE 即時更新)、`showVia` (投稿元アプリ表示)、確認ダイアログ各種 (ブースト/お気に入り/ブックマークは **実行と解除で別フラグ** に分離)、`appLockEnabled` / `appLockBiometric` / `appLockTimeoutSeconds` (アプリロック機能、↓「アプリロック」セクション参照) 等）。`appearanceSettings` キー。
- [notificationsProvider](lib/providers/notifications_provider.dart) — 通知一覧。**マルチアカウント対応**（複数アカウントの通知をマージ）、未読カウント、SSE 購読、`unreadNotificationCountProvider` を別途公開してナビバッジに使用。通知ページを開いている最中にストリームで新着が届いたケースもバッジが消えるよう、`markAsRead` で list の identity を変えて Provider 再通知している点に注意。
- [conversationsProvider](lib/providers/conversations_provider.dart) — DM 会話一覧。マルチアカウント対応。
- [tabStateProvider](lib/providers/tab_state_provider.dart) — BottomNav の現在タブの真実のソース。`RootPage` がこれを `ref.watch` してレンダリング、`PushNotificationService` の通知タップコールバックからも書き換えられる。**注**: `_tabController.index` (カラム切替用) と混同しない。タブスワイプで通知ページに飛ぶバグの再発防止のため、カラム TabController からは `tabStateProvider` に書き込まないこと。

### 永続化レイヤー
- **Hive** (`timelineCache` Box, `String` 型): タイムライン／アカウント投稿の生 JSON をキャッシュ。`mastodon_api.dart` 内で API 失敗時のフォールバック。`main.dart` 起動時に `Hive.initFlutter` + `openBox`。
- **SharedPreferences**: アカウント、カラム、設定、下書き、最後に読んだ通知 ID 等。
- **Notifier / State 内の静的キャッシュ**: `NotificationsNotifier`、`ConversationsNotifier`、`ColumnTimelineViewState`、`_PostTileState` 等が `static final Map` を持つ。
  - **Notifier 系**: Hot reload や Notifier 再生成を跨いでデータ保持。
  - **Widget State 系** ([_PostTileState](lib/widgets/post_tile.dart) の `_showActionsByStatusId` / `_unblurredByStatusId` 等): `scrollable_positioned_list` が画面外スクロールで Widget State を破棄・再生成するため、**status ID をキーにした `static final Map` で UI 状態 (アクションバー展開・sensitive ぼかし解除など) を永続化**しないとスクロール往復で状態がリセットされる。新規にスクロール往復で消えてはいけない UI 状態を加える時はこのパターンを踏襲する。

### API レイヤー
[lib/services/mastodon_api.dart](lib/services/mastodon_api.dart) に Mastodon REST API 呼び出しを **トップレベル関数として** 集約（クラス化されていない）。各関数が `instanceUrl` と `accessToken` を引数で受け取る。タイムライン／投稿の取得は `_cacheBox` への put / 失敗時 get を内蔵。HTTP は直接 `http.get` 等を呼ばず、必ずトップレベル変数 `httpClient` 経由で叩く (テストから `MockClient` に差し替えるための seam。新規エンドポイント追加時もこれを使うこと)。

`fetchInstanceConfig` は in-memory `_instanceConfigCache` (instanceUrl → InstanceConfig) を持ち、同一プロセス内では一度取得したら再利用する。文字数上限のような滅多に変わらない値の取得を、アカウント選択操作のたびに毎回飛ばさないため。

**SSE ストリーミング**: 自前の [lib/services/sse_client.dart](lib/services/sse_client.dart) (Web = ブラウザ標準 EventSource を `package:web` 経由 / Mobile・Desktop = `dart:io` HttpClient ベースの自前パーサ) 経由で `subscribeNotifications` / `subscribeTimelineUpdates(timelineType, listId)` の Stream を提供 (いずれもトップレベル関数)。切断時の自動再接続は **呼び出し側** ([timeline_view.dart](lib/widgets/timeline_view.dart) `_StreamConnection`) の責任 (指数バックオフ)。再接続時のギャップ復旧 (`_refresh` を購読前に await するレース回避) やサイレント切断 watchdog (`:thump` ハートビート + liveness タイマー) の詳細は [docs/timeline-internals.md](docs/timeline-internals.md) 参照。

**プッシュ通知**: `createPushSubscription` / `deletePushSubscription` は Mastodon の `/api/v1/push/subscription` エンドポイントを叩いてリレーの公開鍵で購読登録 / 解除する。

### OAuth: プラットフォーム条件付き import
[lib/services/auth_service.dart](lib/services/auth_service.dart) で 3 実装を切替：
```dart
import 'auth_service_stub.dart'
    if (dart.library.js_interop) 'auth_service_web.dart'
    if (dart.library.io) 'auth_service_mobile.dart' as auth_impl;
```
- **io 実装** ([auth_service_mobile.dart](lib/services/auth_service_mobile.dart)): `dart.library.io` を持つ全プラットフォーム共通。**条件付き import では Android と Windows を区別できない**（どちらも `dart.library.io`）ため、ファイル内で `Platform.isWindows / isLinux` を**実行時分岐**する:
  - **Android / iOS / macOS**: `flutter_appauth`。リダイレクト URI スキーム `jp.demo2.kurage://callback`。`AndroidManifest.xml` に対応する intent-filter 定義済み。client_name = `Kurage for mastodon`。
  - **Windows / Linux**: `flutter_appauth` が**非対応**（Windows のプラグイン登録に存在しない）なので、`dart:io` の `HttpServer` + `url_launcher` で**ループバック redirect 方式**（RFC 8252）を自前実装。`127.0.0.1` のエフェメラルポートにローカルサーバを立て、redirect_uri = `http://127.0.0.1:<port>/` を**その都度**アプリ登録 → システムブラウザで認可 → `code` をコールバック受信 → `/oauth/token` 交換。`state` で CSRF 検証、5 分タイムアウト。client_name = `Kurage for mastodon (Windows)` / `(Linux)`。ループバックなので Windows ファイアウォール警告は出ない。
  - **注**: トップレベルの `FlutterAppAuth()` 生成は MethodChannel を作るだけで native を叩かないため Windows でも安全。実 native 呼び出し (`authorizeAndExchangeCode`) はデスクトップ分岐で回避している。
- **Web** ([auth_service_web.dart](lib/services/auth_service_web.dart)): `package:web` + `dart:js_interop` でポップアップ → `web/auth/callback.html` から `postMessage`。client_name = `Kurage for mastodon (Web)`。(dart:html は deprecated のため全廃済み。Web 実装の条件付き import は `dart.library.js_interop` で判定する)
- **Stub**: 未対応プラットフォーム用フォールバック。

> 注: `flutter_appauth` は `pubspec.yaml` で git master 参照（pub.dev 版ではない）。iOS/Android/macOS のみ対応で Windows/Linux は未対応。

> **投稿の via（application 名）はトークンに紐づきサーバ側で固定**: OAuth アプリ登録時の client_name が決め打ちになるため、後からクライアントで変更できない。バックアップ復元で別プラットフォームのトークンを持ち込むと via もそのプラットフォーム名のままになる（例: Web のトークンを Windows に復元 → via が `(Web)`）。直すには対象プラットフォームで**新規ログイン**が必要。

### プッシュ通知（実装済み）

Firebase Cloud Messaging + 自前の Cloudflare Worker リレー経由で動作。

- **クライアント**: [lib/services/push_notification_service.dart](lib/services/push_notification_service.dart)
  - `main.dart` の起動時に `initialize(onTapNotification: ...)` で初期化
  - `_autoRegisterForSavedAccounts` が `SharedPreferences['accounts']` を読んで全アカウントを Mastodon サーバに購読登録 (`/api/v1/push/subscription`)
  - リレー公開鍵 / auth_secret は Worker の `/pubkey` `/auth` から取得 (セッションキャッシュ)
  - data only な FCM メッセージを受信 → `flutter_local_notifications` で通知表示。フォアグラウンド／バックグラウンド／コールドスタート全対応
  - 通知タップ → `onTapNotification` コールバック発火 → `tabStateProvider` 経由で通知タブへ遷移
- **Firebase 設定**: [lib/firebase_options.dart](lib/firebase_options.dart) (手書き管理、iOS 追加時は同ファイルに追記)
  - `firebase_options.dart` と `android/app/google-services.json` は **git 管理外** (OSS 公開のため example 化)。clone 直後は各 `.example` をコピーして配置する (ダミー値のままでもビルド・起動可。CI も同方式でコピーしている)。実物はこの PC のローカルにのみ存在し、消えた場合は Firebase Console から再取得
  - `android/app/build.gradle.kts` で `com.google.gms.google-services` プラグイン適用
  - `android/settings.gradle.kts` でバージョン宣言
- **OAuth**: ログイン時のスコープに `push` 必須 ([auth_service*.dart](lib/services/auth_service.dart))。スコープ無しの旧トークンでは購読登録できないので、変更時は再ログインが必要
- **リレー**: [worker/](worker/) ディレクトリ (Cloudflare Worker, TypeScript)。aes128gcm/aesgcm 両形式の Web Push 復号 + Service Account JWT で FCM HTTP v1 へ転送。鍵類は Worker Secret として保管。詳細は [worker/README.md](worker/README.md)。デプロイ済み URL は [lib/services/push_relay_config.dart](lib/services/push_relay_config.dart) に定義

### アプリロック（PIN / 生体認証、オプション）

オプションで起動時とバックグラウンド復帰時に PIN / 生体認証を要求する。設定で OFF (デフォルト) なら一切動かない。

- **PIN 保管**: [lib/services/app_lock_service.dart](lib/services/app_lock_service.dart) で SHA-256 + 16 byte ランダムソルトでハッシュ化、`flutter_secure_storage` (Android Keystore / iOS Keychain) に保存。`SharedPreferences` には平文も hash も置かない。
- **生体認証**: `local_auth` パッケージ。Android 側は **`MainActivity.kt` を `FlutterFragmentActivity` 継承に変える必要あり** (`FlutterActivity` のままだと local_auth が動かない)。`USE_BIOMETRIC` 権限を `AndroidManifest.xml` に追加済み。iOS は `Info.plist` に `NSFaceIDUsageDescription` 必須。
- **runtime state**: [lib/providers/app_lock_provider.dart](lib/providers/app_lock_provider.dart) `appLockProvider` が `locked` フラグと `lastPausedAt` を保持 (永続化しない、起動毎にリセット)。`onAppPaused` / `onAppResumed` をライフサイクルフックから呼ぶ設計。
- **ロック画面**: [lib/main.dart](lib/main.dart) の `LockGate(child: RootPage())` がトップレベルにあり、`Stack(Offstage(child) + AppLockScreen)` でロック中も子の State (タブ・SSE・スクロール位置) を破棄しない。`WidgetsBindingObserver` で `paused` / `resumed` を捕捉して `AppLockNotifier` に流す。
- **コールドスタート時のロック判定**: `SettingsNotifier._load()` が非同期完了するまでは settingsProvider が default 値 (appLockEnabled = false) を返してしまうため、`runApp` 前に `AppLockService.instance.shouldStartLocked()` が直接 SharedPreferences の `appearanceSettings` JSON を読み、必要なら `_container.read(appLockProvider.notifier).lock()` を呼ぶ。これで最初のフレームから正しくロック画面が出る。
- **タイムアウト**: バックグラウンドに行ってから timeout 秒以内の復帰は再ロックしない (画像ピッカー / OAuth / プッシュ通知タップなどの短時間遷移を許容するため)。設定可能値は即時/30s/1m/5m/15m/30m。

### タイムラインアイテムの抽象化
[lib/models/timeline_item.dart](lib/models/timeline_item.dart) — `TimelineItem` 抽象クラスを `PostItem` と `GapItem` が継承。タイムラインに「ギャップ」（未取得期間のプレースホルダ）を混在表示するための仕組み。`gap_tile.dart` でタップ時に補完取得。

### 画面構成
- [main.dart](lib/main.dart) `RootPage` — 6 タブ BottomNav（メイン/通知/検索/DM/マイプロフィール/設定）。**`PopScope` で戻るボタンをカスタム制御** — メインタブで戻るは終了確認、他タブから戻るはメインへ。`WidgetsBindingObserver` で lifecycle を監視し Wake Lock を制御。
- [pages/main_page.dart](lib/pages/main_page.dart) — マルチカラムタイムライン。デスクトップ（>600px）は横並び、モバイルはタブ。
- [widgets/timeline_view.dart](lib/widgets/timeline_view.dart) — `ColumnTimelineView`。複数ソース（複数アカウント／タイムラインタイプ）を 1 カラムにマージ表示。`AutomaticKeepAliveClientMixin` でタブ切替時の状態保持。`scrollable_positioned_list` で位置検出無限スクロール。SSE ストリーミング受信時の挙動には注意点が複数あり ([docs/timeline-internals.md](docs/timeline-internals.md) 必読)
- [widgets/post_tile.dart](lib/widgets/post_tile.dart) — 投稿表示の中核（3000+ 行）。お気に入り／ブースト／ブックマーク／編集・削除・削除して下書き／引用 (`status.quote` ベース。Mastodon 4.4 公式形式を優先し、無ければ Misskey/Fedibird の本文末 URL を解析するフォールバックあり)／翻訳 (Android では `Intent.ACTION_PROCESS_TEXT` で外部翻訳アプリ起動も対応)／ミュート・ブロック等のアクションを集約。サブウィジェットとして `_PostMediaGallery` / `_PostActionBar` を切り出し済みだが、PostTile 本体に押し込まれた処理がまだ多い。`_PostMediaGallery` は `MediaAttachment.aspectRatio` (Mastodon の `meta.original.aspect`) を見て、横長は最大 2:1 まで枠を広げ、縦長/正方形は正方形のまま (画面占有を抑えるため)。
- [widgets/link_preview.dart](lib/widgets/link_preview.dart) — OGP カード。**`status.card` (サーバ提供 `PreviewCard`) のみを使用** し、クライアント側で URL を fetch して metadata を取らない (旧 `metadata_fetch` 経由の実装は廃止)。これによりレイアウトジャンプと N+1 の HTTP 取得を回避。
- [pages/post_page.dart](lib/pages/post_page.dart) — 投稿コンポーズ画面 (2500+ 行)。`_remaining` (残り文字数) を `ValueNotifier<int>` 化 + `ValueListenableBuilder` でカウンタ表示部だけが rebuild する。本文編集中の毎キーストローク全画面 rebuild を防ぐ最適化。オートコンプリートは 350ms debounce + 進行中タイマー cancel。draft 本文と予約日時は `post_temp` / `post_temp_scheduled_at` で永続化。
- [utils/snackbar_helpers.dart](lib/utils/snackbar_helpers.dart) — `showErrorSnackBar(context, message)` の共通エラー通知 (赤背景 + アイコン + 「閉じる」ボタン、4 秒)。新規にネットワーク失敗等を伝えたい時はこれを使うと見た目が揃う。

### タイムラインのストリーミング・スクロール挙動
`ColumnTimelineView` ([lib/widgets/timeline_view.dart](lib/widgets/timeline_view.dart)) は SSE 即時更新と「下スクロール中の上方追加でも見ている位置がずれない」UX を両立するため、多数の不変条件を持つ。**timeline_view.dart / post_tile.dart / sse_client.dart を変更する前に [docs/timeline-internals.md](docs/timeline-internals.md) を必ず読むこと**。破ると回帰する主要ルール:

- SSE 新着は 150ms バッチング + スクロール中はフラッシュ延期 (`_isUserScrolling`)。`Status.fromJson` はフラッシュまで遅延し、`_onStreamUpdate` では正規表現で id 抽出のみ行う (ホットパスに重い処理を足さない)
- `_items` を変更したら必ず `_invalidateKnownIds()`、`_unreadIds` を変更したら必ず `_syncUnreadCount()`、ストリームバナー状態を変えたら必ず `_syncStreamBanner()`
- `_items` を投稿ベースで全再構築する経路は必ず既存 `GapItem` を `_rebuildItemsWithGaps` で挿し直す (素通しはギャップボタン消失の回帰)
- スクロール位置の復元は必ず `_restoreScrollAnchor` 経由 (生 `jumpTo` 禁止)。**refresh 系に「atTop ならピン留め」を足さない** (アプリ復帰時に位置を失う回帰。fd6b1ed で一度発生し撤回済み)。atTop ピン留めは SSE フラッシュだけが行う
- 非表示タブは SSE 購読しない (`isActive`)。未読セマンティクスは「アンカーより上にある新着」
- PostTile はパース結果を `_cachedParseSpans` でメモ化し、画像は表示サイズ相当でデコードする (詳細は同ドキュメント「PostTile のレンダリングコスト」)

### 投稿コンテンツのレンダリング
[lib/utils/html_parser.dart](lib/utils/html_parser.dart) `parseContentWithEmojis` が、Mastodon の HTML をテキスト／カスタム絵文字（`:shortcode:`）／URL／ハッシュタグ／メンションに分解し `List<InlineSpan>` を返す。`flutter_html` も併用（プロフィール note 等）。

### テーマ
`MyApp._buildTheme` で Material 3 ベース。`settings.themeColor` がデフォルト紫 (`0xFF6750A4`) かどうかで `colorSchemeSeed` を渡すか個別 widget theme を渡すか分岐。ダークモードは `scaffoldBackgroundColor` を黒 + `cardColor` を `grey[900]`。

## プラットフォーム固有の注意

詳細 (Windows ツールチェーンのセットアップ手順、Android の gradle 設定・アダプティブアイコンなど) は [docs/platform-notes.md](docs/platform-notes.md) 参照。要点:

- **Android**: debug ビルドは `jp.demo2.kurage.debug` の別アプリとして release 版と端末上で共存する (OAuth redirect scheme も `kDebugMode` で分岐)。**debug ビルドでは FCM トークン取得が実行時に失敗** する (google-services.json の debug エントリは Firebase Console 未登録のダミー)。`MainActivity.kt` は `FlutterFragmentActivity` 継承必須 (local_auth 要件)。アプリアイコン元画像を差し替えたらアダプティブアイコン用 foreground 画像の再生成も必要。
- **Web**: `web/auth/callback.html` をアセットに含む (OAuth ポップアップの postMessage 受け)。
- **Windows**: ビルドには VS2022 + C++ ワークロード + ATL + NuGet ソース設定が必要 (新しい PC でのセットアップは docs/platform-notes.md を必ず読む)。**Windows では Firebase (FCM プッシュ / Crashlytics / Analytics) は無効**。配布 zip は `tool\package_windows.ps1` で生成 (詳細は [RELEASING.md](RELEASING.md))。

## 開発時の留意点

- **マルチアカウント**: `AuthState.accounts` のみが正。「current」概念は廃止 (上記参照)。新機能で「このアカウントで操作する」が必要な場面では、画面のローカル state + 永続化、または明示的な `accountId` パラメタで対処する。`auth.current` を復活させない。
- **API は全てトップレベル関数**: 新規エンドポイントは `mastodon_api.dart` 末尾に追加するのが既存パターン。
- **UI 文言・コメント・例外メッセージは日本語が主**。
- **ファイル粒度**: `post_tile.dart` 等が肥大化している（3000+ 行）。**新機能追加時は無理に押し込まず別 widget に切り出す** のが望ましい（が、既存パターンとしては集約する側）。`_PostMediaGallery` / `_PostActionBar` のような切り出しが既にいくつかある。
- **`_lints`**: `flutter_lints` の推奨ルール（`analysis_options.yaml`）。プロジェクト独自カスタマイズ無し。**`flutter analyze` は 0 issues を維持する** (2026-06 に deprecation 警告を全て解消済み。新規コードで警告を増やさないこと)。

## 既知の罠

各罠の詳細 (経緯・原因・回避コード) は [docs/pitfalls.md](docs/pitfalls.md) に記載。**該当領域を触る前に必ず対応項目を読むこと**。以下は 1 行要約:

- **Android release: `getIdentifier` でしか参照しないリソースは resource shrinker に消される** → keep.xml に追記 + AAB 内の残存確認 (通知アイコン障害の真因)
- **`scrollable_positioned_list` は画面外 tile の State を破棄** → 消えてはいけない UI 状態は status ID キーの `static final Map` で持つ
- **スクロール通知中の同期 setState / Provider 更新はアサート違反** → `addPostFrameCallback` で次フレームに遅延
- **AppBar 自動隠しは `AnimatedSize(child: AppBar)` では実装不可** (過去に挫折済み。安易に着手しない)
- **カラム TabController から `tabStateProvider` に書き込まない** (カラムスワイプで通知ページに飛ぶ回帰)
- **OGP は `status.card` のみ** (クライアント側 fetch の再導入は N+1 HTTP になるため要検討)
- **gifv をタイムラインで自動再生しない** (ExoPlayer デコーダー上限超過で native クラッシュ)
- **`PopScope.canPop` は build 時評価で stale になる** → `canPop: false` 固定 + `onPopInvokedWithResult` で live 判定
- **ダイアログ内 `TextEditingController` の同期 dispose は例外連鎖** → post-frame で 1 frame 遅らせて dispose
- **`DefaultFirebaseOptions.currentPlatform` は同期 throw** → `.catchError` では拾えず真っ白画面。`kIsWeb` 分岐で init 自体を skip
- **Web では `dart:io` が実行時 throw** → `kIsWeb` で短絡。ファイルは `XFile` + `readAsBytes` + `fromBytes` で組む
- **`XFile.fromData` は io 実装で `name` を無視 → 空 filename で 422** → filename を必ず非空に (Web で通っても Desktop を確認)
- **クリップボード画像貼り付けは Web/Desktop で取得経路が別物** (Windows は BMP→PNG 変換必須。Ctrl+V は `Focus.onKeyEvent` + `ignored`)
