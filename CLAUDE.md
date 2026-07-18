# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

Flutter 製の Mastodon クライアント **Kurage** （pubspec name: `kurage`、Android applicationId: `jp.demo2.kurage`）。Android / iOS / Web / Windows / macOS / Linux 対応。日本語 UI（`flutter_localizations` で ja/en サポート）。

**v1.0.0 正式版リリース済み・OSS 公開済み** (Apache-2.0、https://github.com/demodemo0818/kurage )。バージョン番号・タグ・リリース手順のルールは [RELEASING.md](RELEASING.md) を参照。`pubspec.yaml` の `version:` を編集する時は必ず同ドキュメントに従う（特に `+BUILD` は monotonic 通し番号で必ず +1）。「Kurage」の名称とアプリアイコンは Apache-2.0 の許諾対象外（README 参照）。

リリースビルドは Claude 側で「コミット → タグ → push → `flutter build apk --release` → 署名検証 → `dist/kurage-vX.Y.Z*.apk` へコピー」まで実施し、**端末への `adb install` はユーザー側で行う** 運用（過去にここまでで完結したいと明示されている）。勝手に `adb install` しないこと。

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

**SSE ストリーミング**: 自前の [lib/services/sse_client.dart](lib/services/sse_client.dart) (Web = ブラウザ標準 EventSource を `package:web` 経由 / Mobile・Desktop = `dart:io` HttpClient ベースの自前パーサ) 経由で以下の Stream を提供 (いずれもトップレベル関数):
- `subscribeNotifications` — `/api/v1/streaming/user` の `notification` イベント
- `subscribeTimelineUpdates(timelineType, listId)` — `/api/v1/streaming/{public,public:local,user,list,hashtag}` の `update` イベント
- 切断時の自動再接続は **呼び出し側** ([timeline_view.dart](lib/widgets/timeline_view.dart) `_StreamConnection`) が責任を持つ。指数バックオフ (1s/2s/5s/10s/20s/30s) で再試行。
- **再接続時のギャップ復旧**: `_StreamConnection.everConnected` で「初回接続」と「切断→再接続」を区別し、再接続のときは `_connectStream` が **購読を開始する前に** `_refresh()` を await して切断中に取り逃した投稿を `since_id` 付きで埋める (先に購読すると「SSE の新着が先頭に入った後から間の投稿が下に挟まる」レースになるため)。複数ソースがほぼ同時に再接続しても `_refreshInFlight` で fetch は 1 回に合流する。
- **サイレント切断 watchdog**: TCP/プロキシの都合で `onError` / `onDone` が発火しないまま無音になる SSE 切断を検知するため、60 秒間隔の `_livenessCheckTimer` で各接続の `lastEventAt` を確認し、閾値以上無音なら強制再接続する。`lastEventAt` は update イベントに加え **`:thump` ハートビート** (io 実装の sse_client が `'heartbeat'` イベントとして流し、`subscribeTimelineUpdates` の `onHeartbeat` callback で受ける) でも更新される。ハートビート観測済みの接続は 90 秒 (`_livenessTimeoutWithHeartbeatSeconds`)、未観測 (Web はブラウザ EventSource がコメント行を露出しないため常にこちら) は 600 秒で死亡判定。

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
- [widgets/timeline_view.dart](lib/widgets/timeline_view.dart) — `ColumnTimelineView`。複数ソース（複数アカウント／タイムラインタイプ）を 1 カラムにマージ表示。`AutomaticKeepAliveClientMixin` でタブ切替時の状態保持。`scrollable_positioned_list` で位置検出無限スクロール。SSE ストリーミング受信時の挙動には注意点が複数あり ↓
- [widgets/post_tile.dart](lib/widgets/post_tile.dart) — 投稿表示の中核（3000+ 行）。お気に入り／ブースト／ブックマーク／編集・削除・削除して下書き／引用 (`status.quote` ベース。Mastodon 4.4 公式形式を優先し、無ければ Misskey/Fedibird の本文末 URL を解析するフォールバックあり)／翻訳 (Android では `Intent.ACTION_PROCESS_TEXT` で外部翻訳アプリ起動も対応)／ミュート・ブロック等のアクションを集約。サブウィジェットとして `_PostMediaGallery` / `_PostActionBar` を切り出し済みだが、PostTile 本体に押し込まれた処理がまだ多い。`_PostMediaGallery` は `MediaAttachment.aspectRatio` (Mastodon の `meta.original.aspect`) を見て、横長は最大 2:1 まで枠を広げ、縦長/正方形は正方形のまま (画面占有を抑えるため)。
- [widgets/link_preview.dart](lib/widgets/link_preview.dart) — OGP カード。**`status.card` (サーバ提供 `PreviewCard`) のみを使用** し、クライアント側で URL を fetch して metadata を取らない (旧 `metadata_fetch` 経由の実装は廃止)。これによりレイアウトジャンプと N+1 の HTTP 取得を回避。
- [pages/post_page.dart](lib/pages/post_page.dart) — 投稿コンポーズ画面 (2500+ 行)。`_remaining` (残り文字数) を `ValueNotifier<int>` 化 + `ValueListenableBuilder` でカウンタ表示部だけが rebuild する。本文編集中の毎キーストローク全画面 rebuild を防ぐ最適化。オートコンプリートは 350ms debounce + 進行中タイマー cancel。draft 本文と予約日時は `post_temp` / `post_temp_scheduled_at` で永続化。
- [utils/snackbar_helpers.dart](lib/utils/snackbar_helpers.dart) — `showErrorSnackBar(context, message)` の共通エラー通知 (赤背景 + アイコン + 「閉じる」ボタン、4 秒)。新規にネットワーク失敗等を伝えたい時はこれを使うと見た目が揃う。

### タイムラインのストリーミング・スクロール挙動
`ColumnTimelineView` ([lib/widgets/timeline_view.dart](lib/widgets/timeline_view.dart)) は SSE による即時更新と「下スクロール中の上方追加でも見ている位置がずれない」UX を両立するため、以下の仕組みを持つ:

- **`_StreamConnection`**: カラムソース 1 本ごとの SSE 接続を表す内部クラス。`subscription` / `reconnectTimer` / `attempt` (バックオフ用) を保持。`onError` / `onDone` から `_scheduleReconnect` で指数バックオフ再接続。
- **`_pendingStreamUpdates` + 150ms バッチング**: 連合 TL 等の高頻度ソースで `_onStreamUpdate` ごとに `setState` + `jumpTo` していると競合するため、150ms バッファに溜めて 1 回でフラッシュする。
- **スクロール中はフラッシュ延期**: `NotificationListener<ScrollNotification>` で drag / ballistic を `_scrollDepth` で追跡し、スクロール中 (`_isUserScrolling`) は `_flushPendingStreamUpdates` を early-return + タイマー arming もスキップする。`ScrollEndNotification` で post-frame に再フラッシュ。フリック中に `jumpTo` を呼ぶと進行中の慣性スクロールが強制キャンセルされ「新着が来るたびにスクロールが止まる」体感の主因になるため。SSE 切断バナーも同様で、`_anyStreamDisconnected` (`ValueNotifier<bool>`) + `ValueListenableBuilder` 経由なので接続 up/down で本体は rebuild されない。`_markStreamConnected` / `_markStreamDisconnected` / `_unsubscribeFromStreams` は必ず `_syncStreamBanner()` を呼ぶ。
- **重複排除キャッシュ (`_knownStatusIds`)**: SSE は同期的に `_onStreamUpdate` を UI スレッドで叩くため、毎イベント `_items` (最大 1000 件) を走査して Set を組むと O(n) 走査がスクロールフレーム予算を食い潰す。`_knownIdsCache` を lazy 構築 + `_items` 変更時に `_invalidateKnownIds()` する方式で O(1) 化。差分 prepend 時は invalidate でなく incremental に追加 (ホットパスで再構築を避けるため)。`_items` を変更する全パス (initial / refresh / loadMore / fillGap / refreshWithGapDetection / cache 復元 / flush 全件ソートフォールバック) で必ず invalidate を呼ぶ。
- **`Status.fromJson` をフラッシュまで遅延**: `subscribeTimelineUpdates` は `Stream<String>` (生 JSON) を返す。`json.decode` + `Status.fromJson` (再帰オブジェクト構築) は 5KB 級 JSON で 1〜3ms かかり、SSE が UI スレッドで同期に `.map` を回すため毎イベントこのコストを払うとフレーム予算を直撃する ("新着受信の瞬間に止まる" の真因)。`_onStreamUpdate` は `_statusIdRegex` で id だけ先頭マッチ抽出 (~10μs) して dedup + buffer add で済ませ、`Status.fromJson` は `_flushPendingStreamUpdates` 内で `rawBatch` を回すときにまとめて実行する。フラッシュ自体が `_isUserScrolling` で延期されるので、結果としてパースは「ユーザーが指を離した後」しか走らない。
- **非アクティブタブの SSE 解除 (`isActive`)**: `TabBarView` + `AutomaticKeepAliveClientMixin` で裏のタブの State も生かしっぱなしになるため、何もしないと裏のカラムも全部 SSE 購読 + イベント処理 + setState を続けて表のスクロールに干渉する (連合 TL を裏に持っていると致命的)。`ColumnTimelineView.isActive` を [main_page.dart](lib/pages/main_page.dart) のタブ index と突き合わせて、現在表示中のタブだけが SSE を購読するようにする。`didUpdateWidget` で false→true 遷移を検出して `_maybeStartStreaming` + `_refresh` で取りこぼしを回収。デスクトップは Row で全カラム同時表示なので全て active。`_onAppResumed` のギャップ検出 refresh も非アクティブタブでは skip (タブ復帰時に `_refresh` が走るので OK)。
- **差分 prepend**: `_flushPendingStreamUpdates` はバッチを `_items` の先頭に挿入するだけで、既存全件のソート / ギャップ再検出 / `TimelineItem` 再生成は行わない。バッチ末と既存先頭の境界ギャップだけ `_maybeBuildGap` で 1 回チェック。連合遅延等でバッチに既存より古い投稿が混じった稀なケースだけ全件ソートにフォールバック。旧実装は 1000 件規模のリストに対し 150ms ごとに O(n log n) を回しており、これがストリーミング中スクロール詰まりの主因だった。
- **`_items` 全再構築時のギャップ保全**: `_convertToTimelineItems` はギャップを再検出しない (時間ベース検出は過剰表示の原因で廃止済み) ため、`_items` を投稿ベースで全再構築する経路 (refresh / SSE フラッシュのフォールバック / loadMore / fillGap) は **必ず既存 `GapItem` を退避して `_rebuildItemsWithGaps` (実体は [lib/utils/timeline_item_ops.dart](lib/utils/timeline_item_ops.dart) の `insertGapsByAnchor`、unit test あり) で挿し直す**。素通しすると「ストリーミング中にギャップボタンが消える」回帰になる。
- **アンカー復元**: setState 直前に live `itemPositions` から「topVisible item の id と alignment (`_captureScrollAnchor`)」を読み、setState 後に明示的に `jumpTo` して見えている位置をピン留めする。`_refresh` / `_loadMore` / `_fillGap` はこの方式。**先頭 (atTop) への `jumpTo(0, 0)` ピン留めは SSE フラッシュ (`_flushPendingStreamUpdates`) だけ**が行う (最上部で live 更新を眺める ticker 挙動。かつ atTop で何もしないとパッケージのデフォルト挙動で prepend のたびに数 px のズレが累積する)。**refresh 系に「atTop ならピン留め」を足してはいけない** — refresh はアプリ復帰・SSE 再接続時にも走るため、バックグラウンド中の新着をまとめて取得する復帰時に「見ていた位置」を失って最新へ飛ぶ回帰になる (fd6b1ed で一度発生し撤回済み)。refresh の新着はアンカーの上に積んで未読バッジで知らせるのが設計意図。**注意**: パッケージの `jumpTo` は `widget.itemCount - 1` で index をクランプするが、setState 直後の同期呼び出しでは SPL の widget はまだ**旧リストの itemCount** のまま。アンカーより上に大量挿入してアンカーの新 index が旧件数を超えるケース (`_fillGap` の下側キープが典型) では post-frame に遅延しないと挿入ブロックの途中へ飛ぶ。`_restoreScrollAnchor` が `_lastBuiltItemCount` との比較でこれを自動処理するので、復元は必ず `_restoreScrollAnchor` を経由すること (生 `jumpTo` を直接呼ばない)。
- **未読カウント**: 引っ張って更新やストリーム受信で得た新着の status ID を `_unreadIds` に積み、画面に入ったら順次取り除く。バッジ表示は `ValueListenableBuilder` + `_unreadCount` (`ValueNotifier<int>`) 経由で行うため、件数の増減でタイムライン本体は rebuild されない。`_unreadIds` を変更したら必ず `_syncUnreadCount()` を呼ぶこと。セマンティクスは **「未読 = 視点 (スクロールアンカー) より上にある新着」**。ソート再構築で視点より下に interleave された投稿 (統合カラムで遅れていたソースの取得分や連合遅延の SSE 投稿) を積むと上スクロールで通過せず可視判定で消えない (= バッジが減らないバグ) ため、再構築を伴う経路では `unreadIdsAboveAnchor` ([lib/utils/timeline_item_ops.dart](lib/utils/timeline_item_ops.dart)) でアンカー上の id だけ積む。最上部到達時は `_onScrollPositions` が `_unreadIds` を全クリアする自己修復もある。
- **重複取得回避**: 引っ張って更新時にストリーム受信済みの ID を除外しないと二重表示されるため、`_items` と `_pendingStreamUpdates` 両方の ID と `removeWhere` で突合する。

### PostTile のレンダリングコスト
PostTile は本文 / 表示名 / CW / 引用 / 翻訳など最大 6〜8 箇所で `parseContentWithEmojis` (HTML 正規表現 + InlineSpan / TapGestureRecognizer / CachedNetworkImage 生成) を呼ぶ。ストリーミング中は親が SSE フラッシュごとに setState するため、メモ化なしだと秒間数百回の正規表現走査が発生する。
- **`_cachedParseSpans`**: tile の State に `Map<String, _ParsedSpansEntry>` を持ち、`(html.hashCode, fontSize, color, emojiSize, アニメ設定...)` の signature でキャッシュ。signature が同じなら前回の InlineSpan リストをそのまま返す。signature が変わったら旧 spans の `TapGestureRecognizer` を `dispose()` してから再パース。tile の `dispose()` でも全エントリを dispose する。
- **画像デコード抑制**: アバター / 引用アバター / メディアプレビューの `CachedNetworkImage` には `memCacheWidth` / `memCacheHeight` を、`CircleAvatar.backgroundImage` には `ResizeImage` を指定して `表示サイズ × DPR` 相当でデコードする。これがないと Mastodon サーバから来る 256〜1024px 級の元画像を丸ごとデコードして縮小描画することになり、メモリと CPU を浪費する。

### 投稿コンテンツのレンダリング
[lib/utils/html_parser.dart](lib/utils/html_parser.dart) `parseContentWithEmojis` が、Mastodon の HTML をテキスト／カスタム絵文字（`:shortcode:`）／URL／ハッシュタグ／メンションに分解し `List<InlineSpan>` を返す。`flutter_html` も併用（プロフィール note 等）。

### テーマ
`MyApp._buildTheme` で Material 3 ベース。`settings.themeColor` がデフォルト紫 (`0xFF6750A4`) かどうかで `colorSchemeSeed` を渡すか個別 widget theme を渡すか分岐。ダークモードは `scaffoldBackgroundColor` を黒 + `cardColor` を `grey[900]`。

## プラットフォーム固有の注意

- **Android**:
  - `compileSdk` / `targetSdk` / `minSdk` は Flutter SDK 既定を継承（`flutter.compileSdkVersion` 等）
  - `appAuthRedirectScheme = "jp.demo2.kurage"`（[build.gradle.kts](android/app/build.gradle.kts)。`buildTypes.debug` だけ `applicationIdSuffix = ".debug"` で `jp.demo2.kurage.debug` に、OAuth scheme も `jp.demo2.kurage.debug` に、ラベルは `Kurage Dev` に上書き。release / profile はデフォルト値を継承）
  - **debug / release 共存運用**: `flutter run` (debug) は `jp.demo2.kurage.debug` 別アプリとしてインストールされるので、`flutter build apk --release` で作った release 版と端末上で共存する (ホーム画面にアイコン 2 つ、ストレージ・OAuth トークン・カラム設定すべて独立)。Dart 側は [auth_service_mobile.dart](lib/services/auth_service_mobile.dart) が `kDebugMode` 定数で redirect URI を分岐 (`kDebugMode == true` → `jp.demo2.kurage.debug://callback`、false → `jp.demo2.kurage://callback`)。これは Android 側の `manifestPlaceholders` と 1:1 で対応していて、profile / release は false 側に揃う
  - **FCM の debug ビルド注意**: [google-services.json](android/app/google-services.json) に `jp.demo2.kurage.debug` 用のクライアントエントリをダミー追加してビルドを通している (= Firebase Console 未登録)。**debug ビルドでは FCM トークン取得が実行時に失敗** してプッシュ通知が動かない。debug でもプッシュを動かしたい場合は Firebase Console で debug 用 Android アプリを正式登録して google-services.json を再ダウンロード
  - `JavaCompile` で `-Xlint:-options,-Xlint:-deprecation` を抑制（古い API 利用時の警告除去）
  - 通知用に `POST_NOTIFICATIONS` 権限を `AndroidManifest.xml` で宣言済み (Android 13+ ランタイム要求は `PushNotificationService.initialize()` 内で実行)
  - `MainActivity.kt` は **`FlutterFragmentActivity` 継承** (アプリロックの `local_auth` が要求)。`USE_BIOMETRIC` 権限あり。
  - **アダプティブアイコン** ([mipmap-anydpi-v26/ic_launcher.xml](android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml)): 背景色 `#0A0620` ([colors.xml](android/app/src/main/res/values/colors.xml)) + 前景画像。`pubspec.yaml` の `flutter_icons` で `adaptive_icon_foreground` には **元画像と異なる別ファイル** [assets/icon/kurage_icon_foreground.png](assets/icon/kurage_icon_foreground.png) を指定 (元の `kurage_icon.png` をそのまま使うと安全ゾーンを超えてマスクで端が切られる)。foreground は元画像を 70% に縮小し同色の余白を足したもの。元画像を差し替えたら foreground 用画像も再生成が必要。
- **Web**: `web/auth/callback.html` をアセットに含む。OAuth 完了時に親ウィンドウへ `postMessage`。
- **Windows (デスクトップ)**: `flutter run -d windows` / `flutter build windows` には以下のツールチェーン整備が必要。Android/Web だけ触ってきた環境で初めて通すと複数の壁に順にぶつかるので、新しい PC でセットアップする時は下記を先に揃える。
  - **Visual Studio 2022 + 「C++ によるデスクトップ開発」ワークロード必須**。VS2019 BuildTools 同梱の CMake 3.20 では `firebase_cpp_sdk_windows` が CMake 3.22+ を要求して configure 失敗する。Flutter は検出した VS に同梱された cmake を使う (flutter_tools `visual_studio.dart` の `cmakePath`) ため、PATH に新しい cmake を入れても効かず **VS 自体を 2022 に上げる**必要がある。winget: `winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"`。
  - **ATL コンポーネント (`Microsoft.VisualStudio.Component.VC.ATL`) も必須**。無いと `flutter_secure_storage_windows` (アプリロックの PIN 保管) が `atlstr.h` not found (C1083) で失敗する。既存 VS への追加は **winget では不可** (既インストール→アップグレード判定でスキップ)。VS Installer を直接叩く: `"C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe" modify --productId Microsoft.VisualStudio.Product.BuildTools --channelId VisualStudio.17.Release --add Microsoft.VisualStudio.Component.VC.ATL` → GUI が開くので「変更」+ UAC。注意: `--passive`/`--quiet` は最初から管理者起動でないと exit 5007 で即終了する (自己昇格しない)。`--installPath "C:\Program Files (x86)\..."` は PowerShell の `Start-Process` がスペースを自動クオートせず途中で切れるので、**productId/channelId 指定**が安全。
  - **NuGet にパッケージソースが必要**。`%APPDATA%\NuGet\NuGet.Config` の `<packageSources>` が空だと `audioplayers_windows` の `nuget install Microsoft.Windows.ImplementationLibrary` が "Argument cannot be null or empty / primarySources" で失敗する。`<add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />` を追加して解決。
  - VS のジェネレータを変えた後 (例: VS2019→2022) は `build\windows` を一度削除する。古い `CMakeCache.txt` が「generator does not match」エラーを出すため。
  - 生成 exe は **`build\windows\x64\runner\Debug\mastodon_app.exe`** (`kurage.exe` ではない。Windows runner の `BINARY_NAME` が旧名 `mastodon_app` のまま [windows/CMakeLists.txt](windows/CMakeLists.txt))。リンク時の `LNK4099 PDB が見つかりません` 大量警告は Firebase 静的ライブラリのシンボル欠落で**無害**。
  - 実行時は [main.dart](lib/main.dart) が `firebaseSupported = kIsWeb || android` で Windows の Firebase 初期化を skip するので起動する。**Windows ではプッシュ通知 (FCM) / Crashlytics / Analytics は無効** (Firebase は Android/Web のみ対象の設計)。
  - **配布**: テスター向けは `tool\package_windows.ps1` で release ビルド + VC++ ランタイム同梱の zip (`dist\kurage-vX.Y.Z[-pre]-windows.zip`) を生成する (ポータブル/未署名)。exe 名・ウィンドウタイトル・アイコンは Kurage ブランド化済み ([windows/CMakeLists.txt](windows/CMakeLists.txt) `BINARY_NAME=kurage`、[windows/runner/Runner.rc](windows/runner/Runner.rc)、`app_icon.ico` は [tool/gen_windows_icon.dart](tool/gen_windows_icon.dart) で生成)。詳細は [RELEASING.md](RELEASING.md)「Windows 配布」。

## 開発時の留意点

- **マルチアカウント**: `AuthState.accounts` のみが正。「current」概念は廃止 (上記参照)。新機能で「このアカウントで操作する」が必要な場面では、画面のローカル state + 永続化、または明示的な `accountId` パラメタで対処する。`auth.current` を復活させない。
- **API は全てトップレベル関数**: 新規エンドポイントは `mastodon_api.dart` 末尾に追加するのが既存パターン。
- **UI 文言・コメント・例外メッセージは日本語が主**。
- **ファイル粒度**: `post_tile.dart` 等が肥大化している（3000+ 行）。**新機能追加時は無理に押し込まず別 widget に切り出す** のが望ましい（が、既存パターンとしては集約する側）。`_PostMediaGallery` / `_PostActionBar` のような切り出しが既にいくつかある。
- **`_lints`**: `flutter_lints` の推奨ルール（`analysis_options.yaml`）。プロジェクト独自カスタマイズ無し。**`flutter analyze` は 0 issues を維持する** (2026-06 に deprecation 警告を全て解消済み。新規コードで警告を増やさないこと)。

## 既知の罠

- **実行時に名前解決するだけの Android リソースは release の resource shrinker に削除される**: Flutter Gradle プラグインは release ビルドで R8 minify + resource shrink を**デフォルト有効**にする (build.gradle.kts に記述が無くても有効)。Java/XML からの静的参照が無く、Dart から `getIdentifier` で実行時解決されるだけのリソース (通知アイコン `ic_stat_kurage` が典型) は shrinker がリソーステーブルごと削除し、**全端末で `getIdentifier` が 0 → `PlatformException(invalid_icon)`** になる (v0.15.0〜v0.16.1-beta の通知アイコン障害の真因。`drawable/` へ置くだけでは直らなかった)。対策は **`android/app/src/main/res/raw/keep.xml` の `tools:keep="@drawable/ic_stat_kurage"`** + AndroidManifest の `com.google.firebase.messaging.default_notification_icon` meta-data (静的参照の保険)。同種のリソースを増やす時は keep.xml に追記し、`flutter build appbundle --release` 後に `unzip -l app-release.aab | grep <名前>` で base に残っていることを確認する。なお AAB の density config split はリソース**ファイル実体**を分割するだけでリソーステーブルは常に base に入るため、「density split で getIdentifier が 0 になる」ことは原理的に無い (過去の誤診断)。修飾なし `drawable/` にも置いておく運用 (`tool/gen_notification_icon.dart` 対応済み) は害が無いので継続。
- **`scrollable_positioned_list` の State 再生成**: スクロールで画面外に出た tile の State は破棄される。エフェメラルでない UI 状態 (アクションバー展開、sensitive ぼかし解除など) は **status ID をキーにした `static final Map`** で持たないと往復で消える。
- **スクロール通知中の `setState` / Riverpod state 更新は危険**: `NotificationListener<ScrollNotification>.onNotification` は build/paint パイプラインの一部で呼ばれるため、その中で同期に Provider state を変更すると `debugFrameWasSentToEngine` アサートに引っかかる。スクロール由来の状態更新は `WidgetsBinding.instance.addPostFrameCallback` で次フレームに遅延させる必要がある。
- **AppBar 自動隠し は `AnimatedSize(child: AppBar)` では動かない**: `AnimatedSize` は中間サイズで child を再 layout しようとするが、`AppBar` の最小高さ制約と衝突して大量の例外が出る。やるなら `Align(heightFactor: ...)` + `ClipRect` で「窓だけ動かす」方式か、もしくは `SliverAppBar(floating: true, snap: true)` だが、後者は `scrollable_positioned_list` を `CustomScrollView` + `SliverList` 系に置き換える必要がある。**過去にこの機能で挫折した経緯あり** — 簡単に思えるが、現状の TL 構造で素直には実装できないので注意。
- **タブスワイプで通知ページに飛ぶ罠**: カラム切替の `_tabController.index` (0..カラム数-1) と BottomNav 用 `tabStateProvider` (0..ナビ数-1) は別物。カラム TabController のリスナから `tabStateProvider` に書き込むと「カラムスワイプ → 通知タブへ遷移」のバグになる。書き込まないこと。
- **OGP は `status.card` のみ**: クライアント側 fetch は廃止済み。サーバが card を返さない投稿はプレビュー無し。再導入する場合はパフォーマンス影響 (タイムライン中の N+1 HTTP) を必ず検討する。
- **gifv をタイムラインで自動再生しない**: Mastodon が GIF→mp4 変換した `type: 'gifv'` のメディアは、タイムラインで多数同時に `VideoPlayer` を立ち上げると ExoPlayer のデコーダー上限 (端末によって 8〜16) を超え、`MediaCodecVideoRenderer error` で **native レベルでアプリがクラッシュ**する。タイムラインでは静止プレビュー + 「GIF」バッジ (`_GifBadge`) のみに留め、フルスクリーン (`VideoPlayerWidget(looping: true, muted: true, showControls: false)`) で 1 枠だけ decoder を起こしてループ再生する設計。再導入したい場合は `visibility_detector` で「画面内のもののみ再生」+ 同時再生数 cap が必須。
- **`PopScope.canPop` は build 時評価で stale になる**: 投稿ページのように `ValueNotifier` + `ValueListenableBuilder` で setState を抑制している画面では、`canPop: !_hasContent()` のような書き方をしても `canPop` の値が rebuild されず古いまま (本文を入力しても `canPop = true` のままでダイアログが出ない)。**`canPop: false` 固定にして `onPopInvokedWithResult` 内で live に判定する** のが確実。同様の罠は他のオプティミスティックな setState 抑制パターンでも起き得る。
- **`showDialog` 内で使った `TextEditingController` を即時 dispose しない**: ダイアログ閉鎖時に focus が外れる際、`EditableTextState._handleFocusChanged` がマイクロタスクで `controller.clearComposing()` を呼ぶ。`await showDialog` 直後 / `finally` で同期 `controller.dispose()` するとここで「disposed な controller を使用」例外を投げ、連鎖して `InheritedElement._dependents.isEmpty` assert / dirty widget / RenderFlex オーバーフロー例外まで噴き出してデバッグビルドが赤画面になる。**`WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose())` で 1 frame 遅らせる** のが正解。プロジェクト内のダイアログ系ローカル controller (アカウント追加 URL / リスト名 / プロフィールメモ / ALT 編集 等) は全てこのパターンで統一済み。State レベルで保持する controller (`_PostPageState._controller` 等) は `State.dispose()` で消せばよく対象外。
- **`DefaultFirebaseOptions.currentPlatform` は同期 throw する**: [firebase_options.dart](lib/firebase_options.dart) は未対応プラットフォーム (現状 Web / iOS / desktop) で `UnsupportedError` を **getter 本体で同期に投げる** 設計。`Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)` と書くと、引数評価の時点で throw が起き、Future はまだ作られていないため後段の `.catchError` には拾われない → **main() ごと unhandled で死亡 → 真っ白画面**。`main.dart` は `kIsWeb` 分岐で Firebase init 自体を skip する形で対処済み (Web は FCM/Crashlytics とも未使用なので OK)。iOS / desktop を追加するときに「getter で throw を残したまま `.catchError` で何とかなる」と勘違いしないこと。回避するなら `Future.sync(() => Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform))` で同期 throw も Future に取り込むか、対象プラットフォームを `firebase_options.dart` 側で実装する。
- **Web で `dart:io` Platform / File は実行時 throw**: `dart:io` は Web でも import は通るが、`Platform.isAndroid` / `File('...')` / `Directory` / `getApplicationDocumentsDirectory()` などは実行時に `MissingPluginException` や `UnsupportedError` を投げる。同期 throw が `runApp` 前に出ると真っ白画面になる ([WEB_TODO.md](WEB_TODO.md) 参照)。**dart:io を import している実装は `kIsWeb` で短絡** すること。ファイル/メディア系の cross-platform 抽象は `cross_file` の `XFile` を使い、`MultipartFile.fromPath` ではなく `XFile.readAsBytes()` + `fromBytes` で組む (`mastodon_api.dart::uploadMedia` / `updateProfile` がこのパターン)。`Image.file` / `FileImage` も Web で使えないので、`kIsWeb` 分岐で `Image.network(xfile.path)` / `NetworkImage(xfile.path)` に切り替える (blob URL がそのまま読める)。
- **`XFile.fromData` は io 実装で `name` を無視する → 空 filename で 422**: `cross_file` の `XFile.fromData(bytes, name: ...)` は **Web 実装は `name` を保持するが、io (Android/iOS/デスクトップ) 実装は `name` を無視** し、`name` getter を `path` から導出する (`XFile.fromData` に `path` を渡さないと `name` が空文字)。この空 `name` を `MultipartFile.fromBytes('file', bytes, filename: '')` に渡すと、Mastodon (Rails) がマルチパートを「ファイル」と認識せず **422 `バリデーションに失敗しました: File を入力してください` (File can't be blank)** になる。メモリ上のバイト列 (クリップボード貼り付け等) から `XFile` を作って upload する経路で踏む。**`uploadMedia` は filename が空なら MIME サブタイプから `upload.<ext>` を補完して回避済み**。新規に `fromData` 由来の upload を足すときも filename を必ず非空にすること。Web だけ通って Desktop で落ちる典型なので、Web で動いても Desktop を必ず確認する。
- **クリップボード画像貼り付け (Web/Desktop) は取得経路がプラットフォームで別物**: [clipboard_image.dart](lib/services/clipboard_image.dart) が条件付き import で実装を切替。**Web** ([clipboard_image_web.dart](lib/services/clipboard_image_web.dart)) はブラウザの `paste` イベント (push、権限不要・全ブラウザ) で画像 File を取得、**Desktop** ([clipboard_image_io.dart](lib/services/clipboard_image_io.dart)) は `pasteboard` の `Pasteboard.image` を Ctrl/Cmd+V キー契機で pull する。`pasteboard` の Web パスは async Clipboard API 依存で実質 Chrome 限定なので Web では使わない。**Windows の `Pasteboard.image` は画像を BMP で返す** が Mastodon は BMP 非対応なので、`dart:ui` (`instantiateImageCodec` → `toByteData(png)`) で **PNG に変換してから** upload する (Mastodon 対応の png/jpeg/gif/webp はマジックバイト判定でそのまま通す)。Ctrl/Cmd+V は `CallbackShortcuts` に bind せず `Focus.onKeyEvent` で検知して **常に `KeyEventResult.ignored`** を返す (テキストペーストを壊さないため)。
