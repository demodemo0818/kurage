# タイムライン内部実装の詳細 (SSE ストリーミング / スクロール / レンダリング)

[CLAUDE.md](../CLAUDE.md) から切り出した詳細ドキュメント。**[timeline_view.dart](../lib/widgets/timeline_view.dart) / [post_tile.dart](../lib/widgets/post_tile.dart) / [sse_client.dart](../lib/services/sse_client.dart) を変更する前に必読**。ここに書かれた不変条件を破ると、過去に実際に発生した回帰 (スクロール詰まり・位置飛び・ギャップボタン消失・未読バッジ残留など) を再発させる。

関連する罠は [pitfalls.md](pitfalls.md) も参照 (`scrollable_positioned_list` の State 再生成、スクロール通知中の setState、AppBar 自動隠し、gifv 自動再生、タブスワイプ罠)。

## SSE クライアントと再接続

自前の [sse_client.dart](../lib/services/sse_client.dart) (Web = ブラウザ標準 EventSource を `package:web` 経由 / Mobile・Desktop = `dart:io` HttpClient ベースの自前パーサ) 経由で以下の Stream を提供 (いずれもトップレベル関数):

- `subscribeNotifications` — `/api/v1/streaming/user` の `notification` イベント
- `subscribeTimelineUpdates(timelineType, listId)` — `/api/v1/streaming/{public,public:local,user,list,hashtag}` の `update` イベント
- 切断時の自動再接続は **呼び出し側** ([timeline_view.dart](../lib/widgets/timeline_view.dart) `_StreamConnection`) が責任を持つ。指数バックオフ (1s/2s/5s/10s/20s/30s) で再試行。
- **再接続時のギャップ復旧**: `_StreamConnection.everConnected` で「初回接続」と「切断→再接続」を区別し、再接続のときは `_connectStream` が **購読を開始する前に** `_refresh()` を await して切断中に取り逃した投稿を `since_id` 付きで埋める (先に購読すると「SSE の新着が先頭に入った後から間の投稿が下に挟まる」レースになるため)。複数ソースがほぼ同時に再接続しても `_refreshInFlight` で fetch は 1 回に合流する。
- **サイレント切断 watchdog**: TCP/プロキシの都合で `onError` / `onDone` が発火しないまま無音になる SSE 切断を検知するため、60 秒間隔の `_livenessCheckTimer` で各接続の `lastEventAt` を確認し、閾値以上無音なら強制再接続する。`lastEventAt` は update イベントに加え **`:thump` ハートビート** (io 実装の sse_client が `'heartbeat'` イベントとして流し、`subscribeTimelineUpdates` の `onHeartbeat` callback で受ける) でも更新される。ハートビート観測済みの接続は 90 秒 (`_livenessTimeoutWithHeartbeatSeconds`)、未観測 (Web はブラウザ EventSource がコメント行を露出しないため常にこちら) は 600 秒で死亡判定。

## ストリーミング・スクロール挙動

`ColumnTimelineView` ([timeline_view.dart](../lib/widgets/timeline_view.dart)) は SSE による即時更新と「下スクロール中の上方追加でも見ている位置がずれない」UX を両立するため、以下の仕組みを持つ:

- **`_StreamConnection`**: カラムソース 1 本ごとの SSE 接続を表す内部クラス。`subscription` / `reconnectTimer` / `attempt` (バックオフ用) を保持。`onError` / `onDone` から `_scheduleReconnect` で指数バックオフ再接続。
- **`_pendingStreamUpdates` + 150ms バッチング**: 連合 TL 等の高頻度ソースで `_onStreamUpdate` ごとに `setState` + `jumpTo` していると競合するため、150ms バッファに溜めて 1 回でフラッシュする。
- **スクロール中はフラッシュ延期**: `NotificationListener<ScrollNotification>` で drag / ballistic を `_scrollDepth` で追跡し、スクロール中 (`_isUserScrolling`) は `_flushPendingStreamUpdates` を early-return + タイマー arming もスキップする。`ScrollEndNotification` で post-frame に再フラッシュ。フリック中に `jumpTo` を呼ぶと進行中の慣性スクロールが強制キャンセルされ「新着が来るたびにスクロールが止まる」体感の主因になるため。SSE 切断バナーも同様で、`_anyStreamDisconnected` (`ValueNotifier<bool>`) + `ValueListenableBuilder` 経由なので接続 up/down で本体は rebuild されない。`_markStreamConnected` / `_markStreamDisconnected` / `_unsubscribeFromStreams` は必ず `_syncStreamBanner()` を呼ぶ。
- **重複排除キャッシュ (`_knownStatusIds`)**: SSE は同期的に `_onStreamUpdate` を UI スレッドで叩くため、毎イベント `_items` (最大 1000 件) を走査して Set を組むと O(n) 走査がスクロールフレーム予算を食い潰す。`_knownIdsCache` を lazy 構築 + `_items` 変更時に `_invalidateKnownIds()` する方式で O(1) 化。差分 prepend 時は invalidate でなく incremental に追加 (ホットパスで再構築を避けるため)。`_items` を変更する全パス (initial / refresh / loadMore / fillGap / refreshWithGapDetection / cache 復元 / flush 全件ソートフォールバック) で必ず invalidate を呼ぶ。
- **`Status.fromJson` をフラッシュまで遅延**: `subscribeTimelineUpdates` は `Stream<String>` (生 JSON) を返す。`json.decode` + `Status.fromJson` (再帰オブジェクト構築) は 5KB 級 JSON で 1〜3ms かかり、SSE が UI スレッドで同期に `.map` を回すため毎イベントこのコストを払うとフレーム予算を直撃する ("新着受信の瞬間に止まる" の真因)。`_onStreamUpdate` は `_statusIdRegex` で id だけ先頭マッチ抽出 (~10μs) して dedup + buffer add で済ませ、`Status.fromJson` は `_flushPendingStreamUpdates` 内で `rawBatch` を回すときにまとめて実行する。フラッシュ自体が `_isUserScrolling` で延期されるので、結果としてパースは「ユーザーが指を離した後」しか走らない。
- **非アクティブタブの SSE 解除 (`isActive`)**: `TabBarView` + `AutomaticKeepAliveClientMixin` で裏のタブの State も生かしっぱなしになるため、何もしないと裏のカラムも全部 SSE 購読 + イベント処理 + setState を続けて表のスクロールに干渉する (連合 TL を裏に持っていると致命的)。`ColumnTimelineView.isActive` を [main_page.dart](../lib/pages/main_page.dart) のタブ index と突き合わせて、現在表示中のタブだけが SSE を購読するようにする。`didUpdateWidget` で false→true 遷移を検出して `_maybeStartStreaming` + `_refresh` で取りこぼしを回収。デスクトップは Row で全カラム同時表示なので全て active。`_onAppResumed` のギャップ検出 refresh も非アクティブタブでは skip (タブ復帰時に `_refresh` が走るので OK)。
- **差分 prepend**: `_flushPendingStreamUpdates` はバッチを `_items` の先頭に挿入するだけで、既存全件のソート / ギャップ再検出 / `TimelineItem` 再生成は行わない。バッチ末と既存先頭の境界ギャップだけ `_maybeBuildGap` で 1 回チェック。連合遅延等でバッチに既存より古い投稿が混じった稀なケースだけ全件ソートにフォールバック。旧実装は 1000 件規模のリストに対し 150ms ごとに O(n log n) を回しており、これがストリーミング中スクロール詰まりの主因だった。
- **`_items` 全再構築時のギャップ保全**: `_convertToTimelineItems` はギャップを再検出しない (時間ベース検出は過剰表示の原因で廃止済み) ため、`_items` を投稿ベースで全再構築する経路 (refresh / SSE フラッシュのフォールバック / loadMore / fillGap) は **必ず既存 `GapItem` を退避して `_rebuildItemsWithGaps` (実体は [timeline_item_ops.dart](../lib/utils/timeline_item_ops.dart) の `insertGapsByAnchor`、unit test あり) で挿し直す**。素通しすると「ストリーミング中にギャップボタンが消える」回帰になる。
- **アンカー復元**: setState 直前に live `itemPositions` から「topVisible item の id と alignment (`_captureScrollAnchor`)」を読み、setState 後に明示的に `jumpTo` して見えている位置をピン留めする。`_refresh` / `_loadMore` / `_fillGap` はこの方式。**先頭 (atTop) への `jumpTo(0, 0)` ピン留めは SSE フラッシュ (`_flushPendingStreamUpdates`) だけ**が行う (最上部で live 更新を眺める ticker 挙動。かつ atTop で何もしないとパッケージのデフォルト挙動で prepend のたびに数 px のズレが累積する)。**refresh 系に「atTop ならピン留め」を足してはいけない** — refresh はアプリ復帰・SSE 再接続時にも走るため、バックグラウンド中の新着をまとめて取得する復帰時に「見ていた位置」を失って最新へ飛ぶ回帰になる (fd6b1ed で一度発生し撤回済み)。refresh の新着はアンカーの上に積んで未読バッジで知らせるのが設計意図。**注意**: パッケージの `jumpTo` は `widget.itemCount - 1` で index をクランプするが、setState 直後の同期呼び出しでは SPL の widget はまだ**旧リストの itemCount** のまま。アンカーより上に大量挿入してアンカーの新 index が旧件数を超えるケース (`_fillGap` の下側キープが典型) では post-frame に遅延しないと挿入ブロックの途中へ飛ぶ。`_restoreScrollAnchor` が `_lastBuiltItemCount` との比較でこれを自動処理するので、復元は必ず `_restoreScrollAnchor` を経由すること (生 `jumpTo` を直接呼ばない)。
- **未読カウント**: 引っ張って更新やストリーム受信で得た新着の status ID を `_unreadIds` に積み、画面に入ったら順次取り除く。バッジ表示は `ValueListenableBuilder` + `_unreadCount` (`ValueNotifier<int>`) 経由で行うため、件数の増減でタイムライン本体は rebuild されない。`_unreadIds` を変更したら必ず `_syncUnreadCount()` を呼ぶこと。セマンティクスは **「未読 = 視点 (スクロールアンカー) より上にある新着」**。ソート再構築で視点より下に interleave された投稿 (統合カラムで遅れていたソースの取得分や連合遅延の SSE 投稿) を積むと上スクロールで通過せず可視判定で消えない (= バッジが減らないバグ) ため、再構築を伴う経路では `unreadIdsAboveAnchor` ([timeline_item_ops.dart](../lib/utils/timeline_item_ops.dart)) でアンカー上の id だけ積む。最上部到達時は `_onScrollPositions` が `_unreadIds` を全クリアする自己修復もある。
- **重複取得回避**: 引っ張って更新時にストリーム受信済みの ID を除外しないと二重表示されるため、`_items` と `_pendingStreamUpdates` 両方の ID と `removeWhere` で突合する。

## PostTile のレンダリングコスト

PostTile は本文 / 表示名 / CW / 引用 / 翻訳など最大 6〜8 箇所で `parseContentWithEmojis` (HTML 正規表現 + InlineSpan / TapGestureRecognizer / CachedNetworkImage 生成) を呼ぶ。ストリーミング中は親が SSE フラッシュごとに setState するため、メモ化なしだと秒間数百回の正規表現走査が発生する。

- **`_cachedParseSpans`**: tile の State に `Map<String, _ParsedSpansEntry>` を持ち、`(html.hashCode, fontSize, color, emojiSize, アニメ設定...)` の signature でキャッシュ。signature が同じなら前回の InlineSpan リストをそのまま返す。signature が変わったら旧 spans の `TapGestureRecognizer` を `dispose()` してから再パース。tile の `dispose()` でも全エントリを dispose する。
- **画像デコード抑制**: アバター / 引用アバター / メディアプレビューの `CachedNetworkImage` には `memCacheWidth` / `memCacheHeight` を、`CircleAvatar.backgroundImage` には `ResizeImage` を指定して `表示サイズ × DPR` 相当でデコードする。これがないと Mastodon サーバから来る 256〜1024px 級の元画像を丸ごとデコードして縮小描画することになり、メモリと CPU を浪費する。
