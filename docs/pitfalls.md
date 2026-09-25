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

## Windows の動画は再生位置を終端に留まらせてはいけない (点滅する)

Windows (`video_player_win` = Media Foundation) で通常動画を最後まで再生すると、**映像がチカチカ点滅し続ける** ([Issue #4](https://github.com/demodemo0818/kurage/issues/4)、v1.2.1 で発生・v1.2.2 で修正)。連鎖はこうなっている:

1. 終端到達 → `video_player_win` が `MESessionEnded` を受けて `completed` イベントを発火
2. `video_player` の `VideoEventType.completed` 処理が **`pause()` → `seekTo(duration)`** を呼ぶ (upstream の実装)
3. この「終端への seek」が Media Foundation の `MESessionEnded` を**再発火**させる
4. → 1 に戻り、以後延々と往復する

実測では終端到達後に `VideoPlayerValue` の更新が **3600 回以上**発生し、`isBuffering` が **814 回** true/false を往復していた (`isCompleted` は true で安定していたので、値を眺めるときは buffering を見ること)。

**重要な回り道の記録**: 当初 Chewie 側の表示ロジックが原因と考え (Chewie の `getIsBuffering` は終端でスピナーを出さない対策が `TargetPlatform.android` 限定になっており、Windows は `isBuffering` が素通りする)、終端では Chewie を外して自前表示に差し替える修正を入れたが、**実機で点滅は止まらなかった**。点滅の実体は**ネイティブ側がテクスチャを描き直し続けていること**であり、Dart 側の widget 構成とは無関係だったため。UI 層をいくら変えても直らない。

対策は [video_player_widget.dart](../lib/widgets/video_player_widget.dart) の `_onValueChanged`: **終端に達したら先頭へ seek して連鎖を断つ**。`video_player` の `seekTo(duration)` と綱引きになるので、終端へ戻されたことを検知したら何度でも逃がす (`video_player` 側は `completed` イベントを受けたときしか seek しないため必ず収束する。固定遅延で一度だけ逃がす実装はタイミング依存で負けるケースがログに残ったため却下した)。終端表示は Chewie を外し、リプレイボタンを重ねた静止表示にする。**副作用として再生終了後に見えるのは最終フレームではなく先頭フレームになる** (終端に留まれないので原理的に避けられない)。

`video_player_win` 固有の問題なので `defaultTargetPlatform == TargetPlatform.windows` に限定し、他プラットフォームは Chewie の標準挙動を保つこと。gifv (`looping: true`) は `video_player_win` 側が終端で先頭へ戻すため、そもそもこの連鎖に入らない (対象外にしてよい)。

## `PopScope.canPop` は build 時評価で stale になる

投稿ページのように `ValueNotifier` + `ValueListenableBuilder` で setState を抑制している画面では、`canPop: !_hasContent()` のような書き方をしても `canPop` の値が rebuild されず古いまま (本文を入力しても `canPop = true` のままでダイアログが出ない)。**`canPop: false` 固定にして `onPopInvokedWithResult` 内で live に判定する** のが確実。同様の罠は他のオプティミスティックな setState 抑制パターンでも起き得る。

## `showDialog` 内で使った `TextEditingController` を即時 dispose しない

ダイアログ閉鎖時に focus が外れる際、`EditableTextState._handleFocusChanged` がマイクロタスクで `controller.clearComposing()` を呼ぶ。`await showDialog` 直後 / `finally` で同期 `controller.dispose()` するとここで「disposed な controller を使用」例外を投げ、連鎖して `InheritedElement._dependents.isEmpty` assert / dirty widget / RenderFlex オーバーフロー例外まで噴き出してデバッグビルドが赤画面になる。**`WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose())` で 1 frame 遅らせる** のが正解。プロジェクト内のダイアログ系ローカル controller (アカウント追加 URL / リスト名 / プロフィールメモ / ALT 編集 等) は全てこのパターンで統一済み。State レベルで保持する controller (`_PostPageState._controller` 等) は `State.dispose()` で消せばよく対象外。

## `DefaultFirebaseOptions.currentPlatform` は同期 throw する

[firebase_options.dart](../lib/firebase_options.dart) は未対応プラットフォーム (現状 Web / iOS / desktop) で `UnsupportedError` を **getter 本体で同期に投げる** 設計。`Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)` と書くと、引数評価の時点で throw が起き、Future はまだ作られていないため後段の `.catchError` には拾われない → **main() ごと unhandled で死亡 → 真っ白画面**。`main.dart` は `kIsWeb` 分岐で Firebase init 自体を skip する形で対処済み (Web は FCM/Crashlytics とも未使用なので OK)。iOS / desktop を追加するときに「getter で throw を残したまま `.catchError` で何とかなる」と勘違いしないこと。回避するなら `Future.sync(() => Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform))` で同期 throw も Future に取り込むか、対象プラットフォームを `firebase_options.dart` 側で実装する。

## Web で `dart:io` Platform / File は実行時 throw

`dart:io` は Web でも import は通るが、`Platform.isAndroid` / `File('...')` / `Directory` / `getApplicationDocumentsDirectory()` などは実行時に `MissingPluginException` や `UnsupportedError` を投げる。同期 throw が `runApp` 前に出ると真っ白画面になる。**dart:io を import している実装は `kIsWeb` で短絡** すること。ファイル/メディア系の cross-platform 抽象は `cross_file` の `XFile` を使い、`MultipartFile.fromPath` ではなく `XFile.readAsBytes()` + `fromBytes` (`updateProfile`) か、`XFile.openRead()` のストリーム + 長さで組む (`uploadMedia`。大きな動画を全量メモリに載せないため)。`Image.file` / `FileImage` も Web で使えないので、`kIsWeb` 分岐で `Image.network(xfile.path)` / `NetworkImage(xfile.path)` に切り替える (blob URL がそのまま読める)。

## `XFile.fromData` は io 実装で `name` を無視する → 空 filename で 422

`cross_file` の `XFile.fromData(bytes, name: ...)` は **Web 実装は `name` を保持するが、io (Android/iOS/デスクトップ) 実装は `name` を無視** し、`name` getter を `path` から導出する (`XFile.fromData` に `path` を渡さないと `name` が空文字)。この空 `name` を `MultipartFile.fromBytes('file', bytes, filename: '')` に渡すと、Mastodon (Rails) がマルチパートを「ファイル」と認識せず **422 `バリデーションに失敗しました: File を入力してください` (File can't be blank)** になる。メモリ上のバイト列 (クリップボード貼り付け等) から `XFile` を作って upload する経路で踏む。**`uploadMedia` は filename が空なら MIME サブタイプから `upload.<ext>` を補完して回避済み**。新規に `fromData` 由来の upload を足すときも filename を必ず非空にすること。Web だけ通って Desktop で落ちる典型なので、Web で動いても Desktop を必ず確認する。

## クリップボード画像貼り付け (Web/Desktop) は取得経路がプラットフォームで別物

[clipboard_image.dart](../lib/services/clipboard_image.dart) が条件付き import で実装を切替。**Web** ([clipboard_image_web.dart](../lib/services/clipboard_image_web.dart)) はブラウザの `paste` イベント (push、権限不要・全ブラウザ) で画像 File を取得、**Desktop** ([clipboard_image_io.dart](../lib/services/clipboard_image_io.dart)) は `pasteboard` の `Pasteboard.image` を Ctrl/Cmd+V キー契機で pull する。`pasteboard` の Web パスは async Clipboard API 依存で実質 Chrome 限定なので Web では使わない。**Windows の `Pasteboard.image` は画像を BMP で返す** が Mastodon は BMP 非対応なので、`dart:ui` (`instantiateImageCodec` → `toByteData(png)`) で **PNG に変換してから** upload する (Mastodon 対応の png/jpeg/gif/webp はマジックバイト判定でそのまま通す)。Ctrl/Cmd+V は `CallbackShortcuts` に bind せず `Focus.onKeyEvent` で検知して **常に `KeyEventResult.ignored`** を返す (テキストペーストを壊さないため)。

## 日付ピッカー入力モード: 巨大な数字で ArgumentError が build に漏れ、入力欄がグレーの矩形になる

`showDatePicker` の入力モードは、一度 OK を押してバリデーションに失敗すると autovalidate になり、以降**毎キーストロークの build 中に** `MaterialLocalizations.parseCompactDate` が走る。flutter_localizations の `GlobalMaterialLocalizations.parseCompactDate` は **`FormatException` しか catch していない**ため、「日」部分が DateTime の表現範囲 (epoch から ±1 億日) を超える入力 — 実例: 予約投稿の日付欄で `2026/7/21` の末尾に数字を 7 桁追記 → 日 = 210000000 — で intl 内部の `DateTime` 生成が投げる `ArgumentError` が build に素通りし、入力欄サブツリーが `ErrorWidget` に置換される (**release ではグレーの矩形**、debug では赤いエラー表示)。upstream は [flutter/flutter#126397](https://github.com/flutter/flutter/issues/126397) (Flutter 3.47 時点でも flutter_localizations 側は未修正)。

対策は [lib/l10n/safe_material_localizations.dart](../lib/l10n/safe_material_localizations.dart) の `SafeMaterialLocalizationsDelegate`: ja / en の `parseCompactDate` を「ArgumentError もパース失敗 (null) に丸める」サブクラスで差し替え、[main.dart](../lib/main.dart) の `localizationsDelegates` **先頭** (先勝ち) に置いている。このデリゲートを外さないこと。サポートロケールを増やす場合は対応する Safe サブクラスも追加が必要。再現・検証は headless Chrome + puppeteer の E2E で実施済み (修正後は「形式が無効です。」の通常エラー表示になる)。

なお Web には別件として、Chrome の住所オートフィルが Flutter の透明な DOM `<input class="flt-text-editing">` に `-webkit-autofill` の背景色を強制適用し、canvas 上の入力欄を不透明矩形で覆い得る挙動がある (Chrome は住所系で `autocomplete="off"` を無視する)。こちらは [web/index.html](../web/index.html) の transition 遅延ハック (`input.flt-text-editing { transition: background-color 9999999s }`) で予防している。このスタイルも消さないこと。

## Windows 配布 zip: 同梱する VC++ ランタイムがビルド時ツールセットより古いと、起動はするのに機能単位でクラッシュする

[package_windows.ps1](../tool/package_windows.ps1) は VC++ 再頒布可能パッケージ未導入のテスターでも起動できるよう、`msvcp140.dll` / `vcruntime140.dll` / `vcruntime140_1.dll` を exe の隣に同梱する。**app-local に置いた DLL は System32 より優先ロードされる**ため、ここでビルドに使った MSVC ツールセットより**古い** CRT を掴ませると、exe は起動するのに特定機能だけが落ちる、という切り分けの難しい壊れ方をする。

実例が v1.2.0 の **Windows 版で動画再生がクラッシュする不具合** ([Issue #1](https://github.com/demodemo0818/kurage/issues/1))。配布 zip をビルドしている GitHub Actions の `windows-latest` ランナーは、VS2026 の Redist ディレクトリ配下に**旧世代の再頒布可能パッケージも同居させている**。旧実装の `Get-ChildItem -Recurse | Select-Object -First 1` は**バージョン順でソートせず列挙順の先頭**を採るため、実際に選ばれていたのは以下だった:

```
[package] VC++ ランタイム同梱元:
  C:\Program Files\Microsoft Visual Studio\18\Enterprise\VC\Redist\MSVC\14.29.30133\x64\Microsoft.VC142.CRT
```

`Microsoft.VC142.CRT` = VS2019 世代 (CRT **14.29.30157.0**)。一方ビルドはランナーの VS2026 (MSVC **14.51**、`kurage.exe` / `video_player_win_plugin.dll` とも linker version 14.51) で行われていた。結果 14.51 でリンクしたバイナリを 14.29 の CRT で動かす形になり、`video_player_win` (Media Foundation) の再生パスでプロセスごと落ちていた。手元の VS2022 環境は Redist が 14.44 のみでツールセットとも一致するため、**ローカルビルドでは絶対に再現しない**のがこの罠の厄介なところ。実際、切り分けの初手でローカル製の `dist/*.zip` を検体にしてしまい (linker 14.44 + CRT 14.44 で整合しているので当然再生できる)、一度誤った結論を出しかけた。**検体は必ず GitHub Release から落とした実配布物を使うこと** (`gh release download`)。ローカル製か CI 製かは `dumpbin /headers kurage.exe` の linker version で判別できる。

- **切り分け方**: 展開した配布 zip から `msvcp140.dll` / `vcruntime140*.dll` をリネームして退避し (System32 の CRT が使われる)、同じ操作を試す。それで直るなら CRT 不整合。
- **dumpbin の未解決シンボルは 0 でも安心できない**。エクスポート欠落による即死ではなく、CRT 実装差による実行時の未定義動作として出るため、静的な依存チェックでは検出できない。
- **対策**: `package_windows.ps1` は候補をファイルバージョン**降順ソート**して最新を採り、さらに `VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt` のツールセット版と Major.Minor を比較して、**CRT の方が古ければ throw して zip を作らせない**。CI のランナー画像が更新されて VS のバージョンが上がっても、黙って壊れた zip が配られることはなくなる。

## `Theme.of(context).primaryColor` はダークモードで `grey[900]` を返す

Material 3 (`useMaterial3: true`) でも `ThemeData` の `primaryColor` は M2 由来の互換プロパティで、実装が `primaryColor ??= isDark ? Colors.grey[900]! : colorScheme.primary` になっている。つまり **ダークテーマでは「アクセント色」ではなく限りなく黒に近いグレーが返る**。`colorSchemeSeed` (= 設定のテーマカラー) を渡していても関係なく grey[900] のままなので、カスタムカラー指定時でも直らない。

これをアクセントとして文字色に使うと、ダーク背景 (`scaffoldBackgroundColor: Colors.black` / `cardColor: grey[900]`) の上で **文字が背景に埋もれて読めなくなる**。実例が v1.2.2 の「絵文字を選択」ヘッダー ([Issue #6](https://github.com/demodemo0818/kurage/issues/6))。`primaryColor.withValues(alpha: 0.1)` の帯の上に `primaryColor` の文字を載せていたため、ライトでは紫地に紫文字で読めるのに、ダークでは grey[900] 地に grey[900] 文字になっていた。

- **対策**: UI のアクセント色は必ず `Theme.of(context).colorScheme.primary` を使う。`primaryColor` は新規コードで使わない。
- 背景・枠線側だけに使っている箇所も、ダークでは「アクセントのつもりの薄いグレー」になって選択状態が伝わらないので同様に直す。
- 同じ罠は通知フィルタダイアログでも一度踏んでおり (notifications_page.dart にコメントあり)、**再発しやすい**。

## メディア保存のファイル名で拡張子を決め打ちしない

全画面ビューアの保存は元々ファイル名を `mastodon_<ts>.jpg` と**決め打ち**していたため、動画 (mp4 / mov / gif) を保存しても JPG として書き出されていた ([Issue #5](https://github.com/demodemo0818/kurage/issues/5)、v1.2.2)。Web だけ正しく保存できていたのは、Web 経路 (`_saveOnWeb`) が Content-Type から拡張子を導出していたため。

- **対策**: 拡張子は [lib/utils/media_filename.dart](../lib/utils/media_filename.dart) の `resolveMediaExtension(url, contentType)` に一本化した (Content-Type がメディア系ならそれを信用し、`application/octet-stream` 等や欠落時は URL の path 末尾に倒し、最後に jpg フォールバック)。純粋関数なので [test/utils/media_filename_test.dart](../test/utils/media_filename_test.dart) で回帰を止めている。
- **`getSaveLocation` の `XTypeGroup` も併せて直す必要がある**。ここを `['jpg','jpeg','png']` 固定にしていると、ファイル名側を .mp4 にしてもネイティブの保存ダイアログが拡張子を .jpg に付け替えてしまう。`image_save_io.dart` は suggestedName の実拡張子から型グループを組む。
- `video/quicktime` → `mov`、`audio/mpeg` → `mp3` のようにサブタイプがそのまま拡張子にならない MIME があるので、MIME のサブタイプを素で使わない。

## スクロールバーのトラックはホイール入力を横取りする (コンテンツに重ねない)

Flutter の `RawScrollbar` は、**トラックの上にカーソルがある間、ホイール入力を自分で受け取り、下のコンテンツには渡さない**。`foregroundPainter` の `hitTest` がトラック上で true を返すと `RenderCustomPaint` は子の hit test をしないので、下にあるタイムラインの `Scrollable` はイベントを受け取れない。マウスの場合の当たり判定は `_trackRect` そのもので、水平バーなら viewport 下端の **thickness 8 + crossAxisMargin 2×2 = 12px の帯**全体が対象になる。バー自身は自分の軸の成分 (水平バーなら `scrollDelta.dx`) しか見ないので、縦ホイールはこの帯の上では**何も動かさない** (デッドゾーンになる)。

Deck (ワイドレイアウト) の横スクロールバーは `thumbVisibility: true` で常時表示しており、この帯がタイムラインの上に重なっていたため、カラム下端でホイールを回しても縦に動かなかった ([Issue #7](https://github.com/demodemo0818/kurage/issues/7) の調査中に発見)。

> 注: Issue #7 の「ホイールがどこで回しても横スクロールになり、再起動まで直らない」症状の真因はこれではなく、次項の **Shift の押しっぱなし誤認** だった。v1.3.0 ではこの項の対策だけを入れて直ったと判断してしまった。

- **対策**: バーとコンテンツを重ねない。`SingleChildScrollView` に `padding: EdgeInsets.only(bottom: kDeckScrollbarReserve)` ([lib/utils/breakpoints.dart](../lib/utils/breakpoints.dart)) を渡してカラムをトラックのぶん短くする。バーが出ない時 (全カラムが画面に収まる `fits` の時) は余白を取らない。
- `interactive: false` や `ignorePointer: true` で黙らせてはいけない。ホイールの横取りは止まるが、バーのドラッグ自体もできなくなる。
- 常時表示のスクロールバーを新しく足す時は、**トラックが乗る帯の下に何を置いているか**を必ず確認する。同じ理由でタップ/ドラッグも吸われる。

## Windows: Shift が押しっぱなし扱いで残り、ホイールが横スクロールしかしなくなる

Windows 版で、使っているうちに **縦ホイールがどこで回しても Deck の横スクロールになり、カラムが縦に動かなくなる** ([Issue #7](https://github.com/demodemo0818/kurage/issues/7))。カーソルを動かしても直らず、再起動で直る。TextField のクリックが範囲選択になる・Tab が逆向きに移動する、も同じ状態の症状。Flutter 本体の未修正の不具合 ([flutter/flutter#181907](https://github.com/flutter/flutter/issues/181907))。

- **仕組み**: `Scrollable` は `HardwareKeyboard.logicalKeysPressed` に Shift があるとマウスホイールの軸を反転する (`ScrollBehavior.pointerAxisModifiers`)。縦のタイムラインは dx (= 0) を見て何もせず、外側の横 `SingleChildScrollView` が dy を拾って横に動く。
- **Shift が残る理由**: IME 使用中などに Windows が Shift の extended フラグを誤って報告すると、エンジンはスキャンコードを標準の物理キーに対応付けられず、`0x16_0000_0000 | scancode` (例 `0x1600000036`) の**非標準の物理キー**で KeyDown を送る。対になる KeyUp が同じ物理キーで届かないと残り続ける。エンジンは WM_MOUSEMOVE の `MK_SHIFT` / `MK_CONTROL` で修飾キーを OS と同期する (`SyncModifiersIfNeeded`) が、**同期対象は標準の ShiftLeft/Right・ControlLeft/Right だけ**なので、非標準の物理キーは永久に解除されない。
- **対策**: [lib/services/stale_modifier_key_guard.dart](../lib/services/stale_modifier_key_guard.dart) の `StaleModifierKeyGuard` (Windows のみ、`main()` で install)。マウス移動のポインタイベント時点ではエンジンが標準の物理キーを OS の実状態に同期済みなので、「標準の物理キーは離されているのに、非標準の物理キーが Shift/Ctrl として押下中」を取り残しとみなし、合成の `KeyUpEvent` を `HardwareKeyboard.handleKeyEvent` に流して解除する。
- `pointerAxisModifiers` を空にして Shift+ホイールの横スクロールごと殺す対処は取らない (機能が減るうえ、範囲選択・Tab 逆走の症状は残る)。
- `HardwareKeyboard.clearState()` は `@visibleForTesting` で、しかもハンドラまで消すので使わない。
- ホイールイベントではエンジンが同期しないので、ガードは hover / move でだけ判定する。マウスを少しでも動かせば解除される。
- **ガードが解除するのは Dart 側 (`HardwareKeyboard`) だけで、エンジン (C++) 側の押下記録は残る**。そのため次に Shift を押したとき、エンジンから同じ非標準の物理キーの合成 KeyUp が 1 回遅れて届く。Flutter 3.47 の `HardwareKeyboard` は押されていないキーの KeyUp を無視する (`debugPrintKeyboardEvents` 有効時にログを出すだけ) ので、アサートも例外も出ず害は無い (Windows 実機で確認済み)。
- **Windows 実機での再現手順** (2026-09-25 に修正の確認で使用。回帰確認はこれで行う):
  1. Kurage (debug ビルド) を前面にした状態で、`SendInput` で Shift の押下を送る: `wVk = VK_SHIFT`、`wScan = 0x36`、`dwFlags = KEYEVENTF_EXTENDEDKEY`。Flutter には物理 `0x1600000036`・論理 Shift Right の KeyDown として届く。`wVk = 0` でスキャンコードだけ送ると論理キーが Shift にならず再現しない。
  2. 自前のダミーウィンドウを前面にしてから Shift の解放を送る (KeyUp を Kurage に届けないため)。Kurage に KeyUp が届くと、エンジンが同じ物理キーの合成 KeyUp を出して自分で直してしまう。
  3. Kurage を前面に戻すと、非標準の物理キーの押下だけが残る (IME 使用中にフォーカスが外れる実際の状況を模したもの)。
  4. マウスを動かさずに `SendInput` でホイール (`MOUSEEVENTF_WHEEL`) を送る → `HardwareKeyboard.isShiftPressed == true` で Deck が横に動く (バグの再現)。マウスを数 px 動かす → `StaleModifierKeyGuard: 取り残された修飾キーを解除 … 0x1600000036 → Shift Right` が出て、以後のホイールは縦に効く。`main()` の `install()` を外したビルドでは、マウスを動かしても横スクロールのまま戻らない。
  - 「右 Shift を extended 付きで押し、extended なしで離す」だけでは再現しない (解放がエンジンに届いた時点で自己修復される)。フォーカスを外した状態で解放することが必須。

## `ACTION_SEND` の intent-filter をメイン Activity に直付けすると、共有 Intent が再配達される

`MainActivity` に `ACTION_SEND` の intent-filter を書くと、他アプリの「共有」で起動されたときの SEND Intent が **そのままメインタスクの Intent として Android (system_server) 側に保存される**。投稿を終えて Activity / プロセスが破棄されたあと、タスク復元やランチャーからの再起動で `onCreate` が走ると **保存済みの SEND Intent が再配達され**、`EXTRA_TEXT` を読み直したアプリが「投稿済みの内容が入った投稿画面」をまた開いてしまう。

- ユーザーからは「共有して投稿したのに、次にアプリを開くと同じ投稿画面が出る」と見える。下書き (`post_temp_draft`) の残骸に見えるが**下書きは無関係**。共有起動時は下書きを読まない (`post_page.dart` の `_loadTempDraft` 冒頭ガード) し、投稿成功時に全キー削除している。
- **`setIntent()` や `intent.removeExtra()` では直らない**。保存されているのは system_server 側の Intent なので、アプリのプロセス内でオブジェクトを書き換えても、次の復元時には元のものが渡ってくる。
- `FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY` や `savedInstanceState != null` のガードで大半は防げるが、タスクリセット等の経路を取りこぼす。
- **対策**: SEND は `MainActivity` で受けず、専用の中継 Activity ([android/app/src/main/kotlin/jp/demo2/kurage/ShareActivity.kt](../android/app/src/main/kotlin/jp/demo2/kurage/ShareActivity.kt)) に分離する。`taskAffinity=""` + `noHistory` + `excludeFromRecents` でタスクに一切残らないようにし、テキストだけプロセス内の `ShareIntake` に移して `MainActivity` を起動して即 `finish()` する。メインタスクの Intent は常に MAIN/LAUNCHER のままになり、再配達が起きなくなる。
- Flutter 側は `MainActivity` 起動後の post-frame と、`AppLifecycleState.resumed` のたびに `consumePendingSharedText` を叩いているので、コールド / ウォームどちらの経路でも中継 Activity 経由で拾える (Dart 側は無改修)。

## Android: file_selector の `openFiles` は選んだファイル全体を Java ヒープに読む (大きな動画で OOM)

`file_selector_android` は選択されたファイルを `new byte[size]` に丸ごと読み込み、Pigeon でバイト列として Dart に渡す (`FileSelectorApiImpl.toFileResponse`)。100MB 級の動画を選ぶと Java ヒープ (heapgrowthlimit) を超えて **`OutOfMemoryError` でアプリごと落ちる** ([Issue #9](https://github.com/demodemo0818/kurage/issues/9))。onActivityResult 内の Java 側で落ちるので Dart の try/catch では拾えず、サイズの事前チェックもできない。

- **対策**: Android の「ファイルを選択」は `image_picker` の `pickMultipleMedia` を `useAndroidPhotoPicker = false` で呼ぶ (ACTION_GET_CONTENT)。こちらはキャッシュへストリームでコピーして path を返すのでメモリに全量が載らない。種類では絞り込めないので、選択後に拡張子で弾く ([post_page.dart](../lib/pages/post_page.dart) `_pickMedia`)。デスクトップ / Web は従来どおり file_selector。
- 「ギャラリーから選択」は `pickMultiImage` だと**画像しか出ない**。`pickMultipleMedia` + `useAndroidPhotoPicker = true` (OS 標準フォトピッカー、画像 + 動画) を使う。`useAndroidPhotoPicker` は**既定 false** なので明示しないとフォトピッカーにならない。
- アップロードも `readAsBytes` で全量を読まず、`XFile.openRead()` を `http.MultipartFile` に流す ([mastodon_api.dart](../lib/services/mastodon_api.dart) `uploadMedia`)。選択中の全アカウントへ並行アップロードするので、全量読みだとアカウント数ぶんメモリに載る。

## Android: 音声を `Pictures/` に保存しようとすると EPERM (共有ストレージは種類ごとに置き場所が決まっている)

Android の共有ストレージは MediaProvider が MIME の種類ごとに置けるディレクトリを制限している。画像・動画は `Pictures/` に置けるが、**音声を `Pictures/` に `File.writeAsBytes` すると EPERM** で「保存に失敗」になる ([Issue #10](https://github.com/demodemo0818/kurage/issues/10))。Web は Blob ダウンロードなので種類を問わず通り、Android だけ壊れる。

- **対策**: 保存先は [media_filename.dart](../lib/utils/media_filename.dart) の `androidSaveDirectoryFor(ext)` で振り分ける (画像・動画 → `Pictures`、音声 → `Music`、その他 → どの種類でも置ける `Download`)。
- 同 Issue の「音声が再生できない」は、音声添付を画像として扱っていたのが原因。カバー画像の無い音声は `preview_url` が null で、`previewUrl` に**音声ファイルそのものの url** が入る (`MediaAttachment.fromJson` のフォールバック)。画像としてデコードさせないよう `MediaAttachment.audioCoverUrl` で判定し、再生は `VideoPlayerWidget(isAudio: true)` (video_player は映像の無いファイルも再生できる) に流す。
- 音声は `meta.original` に width/height が無いので、`aspectRatio` が既定の 1.0 だとタイムラインで正方形の大きな枠を取る。`MediaAttachment.fromJson` で音声だけ 16:9 に倒している。投稿画面の添付プレビューも MIME が audio なら画像デコードせずアイコンを出す。
- Mastodon (4.7 時点) は mp3 の埋め込みカバーを抽出しない。`preview_url` が付くのは `/api/v2/media` に `thumbnail` を明示して上げた時だけ。

## フォントのフォールバックは書記素クラスタ単位 (「両方の文字を持つフォント」が無いと両方豆腐)

Flutter (SkParagraph) のフォールバックは**書記素クラスタ単位**で「クラスタの全文字を描けるフォント」を探す。半角濁点 `ﾞ` (U+FF9E) / 半濁点 `ﾟ` (U+FF9F) は結合文字ではない (幅を持つ独立グリフ) のに Grapheme_Cluster_Break=Extend で直前の文字にくっつくため、`ᤖﾞ` (リンブ文字 + 半角濁点。「ズ」に見せる表示名の当て字) のように両方を収録したフォントが無い組み合わせだと**どちらのフォントも採用されず 2 文字とも豆腐**になる ([Issue #11](https://github.com/demodemo0818/kurage/issues/11))。ブラウザは文字単位でフォールバックするので Mastodon Web では普通に見える。

- **対策**: [html_text_utils.dart](../lib/utils/html_text_utils.dart) の `separateHalfwidthSoundMarks` が、直前が半角カナ以外の `ﾞ` `ﾟ` の前に WORD JOINER (U+2060) を挟んでクラスタを切る。`parseContentWithEmojis` の平文部分と、表示名を素の `Text` で出している一覧 (検索結果・フォロー一覧・ブロック/ミュート一覧) に掛けている。
- ZERO WIDTH SPACE ではなく WORD JOINER を使うのは改行機会を作らないため。ハッシュタグ等の検出より**前**に掛けると WORD JOINER がタグを途中で切るので、検出後の平文部分にだけ掛ける。
- 結合文字 (U+3099 等の Mn) はクラスタを切るとマークの位置決め (GPOS) が壊れうるので対象にしていない。
