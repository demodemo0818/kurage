# 既知の罠 (詳細)

[CLAUDE.md](../CLAUDE.md) の「既知の罠」一覧の詳細版。各項目の経緯・原因・回避方法をここに記す。**該当する領域を触る前に対応する項目を読むこと**。

## 実行時に名前解決するだけの Android リソースは release の resource shrinker に削除される

Flutter Gradle プラグインは release ビルドで R8 minify + resource shrink を**デフォルト有効**にする (build.gradle.kts に記述が無くても有効)。Java/XML からの静的参照が無く、Dart から `getIdentifier` で実行時解決されるだけのリソース (通知アイコン `ic_stat_kurage` が典型) は shrinker がリソーステーブルごと削除し、**全端末で `getIdentifier` が 0 → `PlatformException(invalid_icon)`** になる (v0.15.0〜v0.16.1-beta の通知アイコン障害の真因。`drawable/` へ置くだけでは直らなかった)。

対策は **`android/app/src/main/res/raw/keep.xml` の `tools:keep="@drawable/ic_stat_kurage"`** + AndroidManifest の `com.google.firebase.messaging.default_notification_icon` meta-data (静的参照の保険)。同種のリソースを増やす時は keep.xml に追記し、`flutter build appbundle --release` 後に `unzip -l app-release.aab | grep <名前>` で base に残っていることを確認する。

なお AAB の density config split はリソース**ファイル実体**を分割するだけでリソーステーブルは常に base に入るため、「density split で getIdentifier が 0 になる」ことは原理的に無い (過去の誤診断)。修飾なし `drawable/` にも置いておく運用 (`tool/gen_notification_icon.dart` 対応済み) は害が無いので継続。

## `scrollable_positioned_list` の State 再生成

スクロールで画面外に出た tile の State は破棄される。エフェメラルでない UI 状態 (アクションバー展開、sensitive ぼかし解除など) は **status ID をキーにした `static final Map`** で持たないと往復で消える。

## スクロール通知中の `setState` / Riverpod state 更新は危険

`NotificationListener<ScrollNotification>.onNotification` は build/paint パイプラインの一部で呼ばれるため、その中で同期に Provider state を変更すると `debugFrameWasSentToEngine` アサートに引っかかる。スクロール由来の状態更新は `WidgetsBinding.instance.addPostFrameCallback` で次フレームに遅延させる必要がある。

## AppBar 自動隠しは `AnimatedSize(child: AppBar)` では動かない

`AnimatedSize` は中間サイズで child を再 layout しようとするが、`AppBar` の最小高さ制約と衝突して大量の例外が出る。やるなら `Align(heightFactor: ...)` + `ClipRect` で「窓だけ動かす」方式か、もしくは `SliverAppBar(floating: true, snap: true)` だが、後者は `scrollable_positioned_list` を `CustomScrollView` + `SliverList` 系に置き換える必要がある。**過去にこの機能で挫折した経緯あり** — 簡単に思えるが、現状の TL 構造で素直には実装できないので注意。

## タブスワイプで通知ページに飛ぶ罠

カラム切替の `_tabController.index` (0..カラム数-1) と BottomNav 用 `tabStateProvider` (0..ナビ数-1) は別物。カラム TabController のリスナから `tabStateProvider` に書き込むと「カラムスワイプ → 通知タブへ遷移」のバグになる。書き込まないこと。

## OGP は `status.card` のみ

クライアント側 fetch は廃止済み。サーバが card を返さない投稿はプレビュー無し。再導入する場合はパフォーマンス影響 (タイムライン中の N+1 HTTP) を必ず検討する。

## gifv をタイムラインで自動再生しない

Mastodon が GIF→mp4 変換した `type: 'gifv'` のメディアは、タイムラインで多数同時に `VideoPlayer` を立ち上げると ExoPlayer のデコーダー上限 (端末によって 8〜16) を超え、`MediaCodecVideoRenderer error` で **native レベルでアプリがクラッシュ**する。タイムラインでは静止プレビュー + 「GIF」バッジ (`_GifBadge`) のみに留め、フルスクリーン (`VideoPlayerWidget(looping: true, muted: true, showControls: false)`) で 1 枠だけ decoder を起こしてループ再生する設計。再導入したい場合は `visibility_detector` で「画面内のもののみ再生」+ 同時再生数 cap が必須。

## `PopScope.canPop` は build 時評価で stale になる

投稿ページのように `ValueNotifier` + `ValueListenableBuilder` で setState を抑制している画面では、`canPop: !_hasContent()` のような書き方をしても `canPop` の値が rebuild されず古いまま (本文を入力しても `canPop = true` のままでダイアログが出ない)。**`canPop: false` 固定にして `onPopInvokedWithResult` 内で live に判定する** のが確実。同様の罠は他のオプティミスティックな setState 抑制パターンでも起き得る。

## `showDialog` 内で使った `TextEditingController` を即時 dispose しない

ダイアログ閉鎖時に focus が外れる際、`EditableTextState._handleFocusChanged` がマイクロタスクで `controller.clearComposing()` を呼ぶ。`await showDialog` 直後 / `finally` で同期 `controller.dispose()` するとここで「disposed な controller を使用」例外を投げ、連鎖して `InheritedElement._dependents.isEmpty` assert / dirty widget / RenderFlex オーバーフロー例外まで噴き出してデバッグビルドが赤画面になる。**`WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose())` で 1 frame 遅らせる** のが正解。プロジェクト内のダイアログ系ローカル controller (アカウント追加 URL / リスト名 / プロフィールメモ / ALT 編集 等) は全てこのパターンで統一済み。State レベルで保持する controller (`_PostPageState._controller` 等) は `State.dispose()` で消せばよく対象外。

## `DefaultFirebaseOptions.currentPlatform` は同期 throw する

[firebase_options.dart](../lib/firebase_options.dart) は未対応プラットフォーム (現状 Web / iOS / desktop) で `UnsupportedError` を **getter 本体で同期に投げる** 設計。`Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)` と書くと、引数評価の時点で throw が起き、Future はまだ作られていないため後段の `.catchError` には拾われない → **main() ごと unhandled で死亡 → 真っ白画面**。`main.dart` は `kIsWeb` 分岐で Firebase init 自体を skip する形で対処済み (Web は FCM/Crashlytics とも未使用なので OK)。iOS / desktop を追加するときに「getter で throw を残したまま `.catchError` で何とかなる」と勘違いしないこと。回避するなら `Future.sync(() => Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform))` で同期 throw も Future に取り込むか、対象プラットフォームを `firebase_options.dart` 側で実装する。

## Web で `dart:io` Platform / File は実行時 throw

`dart:io` は Web でも import は通るが、`Platform.isAndroid` / `File('...')` / `Directory` / `getApplicationDocumentsDirectory()` などは実行時に `MissingPluginException` や `UnsupportedError` を投げる。同期 throw が `runApp` 前に出ると真っ白画面になる。**dart:io を import している実装は `kIsWeb` で短絡** すること。ファイル/メディア系の cross-platform 抽象は `cross_file` の `XFile` を使い、`MultipartFile.fromPath` ではなく `XFile.readAsBytes()` + `fromBytes` で組む (`mastodon_api.dart::uploadMedia` / `updateProfile` がこのパターン)。`Image.file` / `FileImage` も Web で使えないので、`kIsWeb` 分岐で `Image.network(xfile.path)` / `NetworkImage(xfile.path)` に切り替える (blob URL がそのまま読める)。

## `XFile.fromData` は io 実装で `name` を無視する → 空 filename で 422

`cross_file` の `XFile.fromData(bytes, name: ...)` は **Web 実装は `name` を保持するが、io (Android/iOS/デスクトップ) 実装は `name` を無視** し、`name` getter を `path` から導出する (`XFile.fromData` に `path` を渡さないと `name` が空文字)。この空 `name` を `MultipartFile.fromBytes('file', bytes, filename: '')` に渡すと、Mastodon (Rails) がマルチパートを「ファイル」と認識せず **422 `バリデーションに失敗しました: File を入力してください` (File can't be blank)** になる。メモリ上のバイト列 (クリップボード貼り付け等) から `XFile` を作って upload する経路で踏む。**`uploadMedia` は filename が空なら MIME サブタイプから `upload.<ext>` を補完して回避済み**。新規に `fromData` 由来の upload を足すときも filename を必ず非空にすること。Web だけ通って Desktop で落ちる典型なので、Web で動いても Desktop を必ず確認する。

## クリップボード画像貼り付け (Web/Desktop) は取得経路がプラットフォームで別物

[clipboard_image.dart](../lib/services/clipboard_image.dart) が条件付き import で実装を切替。**Web** ([clipboard_image_web.dart](../lib/services/clipboard_image_web.dart)) はブラウザの `paste` イベント (push、権限不要・全ブラウザ) で画像 File を取得、**Desktop** ([clipboard_image_io.dart](../lib/services/clipboard_image_io.dart)) は `pasteboard` の `Pasteboard.image` を Ctrl/Cmd+V キー契機で pull する。`pasteboard` の Web パスは async Clipboard API 依存で実質 Chrome 限定なので Web では使わない。**Windows の `Pasteboard.image` は画像を BMP で返す** が Mastodon は BMP 非対応なので、`dart:ui` (`instantiateImageCodec` → `toByteData(png)`) で **PNG に変換してから** upload する (Mastodon 対応の png/jpeg/gif/webp はマジックバイト判定でそのまま通す)。Ctrl/Cmd+V は `CallbackShortcuts` に bind せず `Focus.onKeyEvent` で検知して **常に `KeyEventResult.ignored`** を返す (テキストペーストを壊さないため)。
