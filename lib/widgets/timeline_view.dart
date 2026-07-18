// lib/widgets/timeline_view.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../models/status.dart';
import '../models/timeline_item.dart';
import '../models/timeline_gap.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../services/mastodon_api.dart'
    show
        fetchTimelineForAccount,
        fetchBookmarksOrFavouritesWithPagination,
        subscribeTimelineUpdates;
import 'post_tile.dart';
import 'gap_tile.dart';
import 'timeline_post_decoration.dart';
import '../utils/snackbar_helpers.dart';
import '../utils/timeline_item_ops.dart';
import '../services/local_post_bus.dart';
import '../services/local_status_event_bus.dart';
import '../services/sound_service.dart';

/// 投稿とそのアカウント情報を保持するクラス
class PostWithAccount {
  final Status status;
  final String accountId;
  
  PostWithAccount({required this.status, required this.accountId});
}

/// 各カラムのタイムライン表示ウィジェット
class ColumnTimelineView extends ConsumerStatefulWidget {
  final Map<String, dynamic> column;

  /// 「ユーザーが今見ている」カラムか。`AutomaticKeepAliveClientMixin` で
  /// `TabBarView` の非アクティブタブも生かしっぱなしにしているため、何も
  /// しないと裏のカラムも全部 SSE 購読 + イベント処理 + setState を続けて
  /// しまい、見ているタブのスクロールに干渉する (連合 TL を裏に持っている
  /// と特に致命的)。アクティブでない間は SSE を購読解除して CPU を解放する。
  /// false の間に届いたイベントは取りこぼすが、復帰時に `_refresh` で
  /// 取りに行くので投稿は失われない。
  final bool isActive;

  const ColumnTimelineView({
    super.key,
    required this.column,
    this.isActive = true,
  });

  @override
  ColumnTimelineViewState createState() => ColumnTimelineViewState();
}

/// State クラスを公開し、GlobalKey から scrollToTop を呼べるように
class ColumnTimelineViewState extends ConsumerState<ColumnTimelineView> 
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener = ItemPositionsListener.create();

  /// リストを先頭へスクロールする
  void scrollToTop() {
    if (_itemScrollController.isAttached) {
      _itemScrollController.scrollTo(
        index: 0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  /// Web のキーボードショートカット (j/k) 用。現在最上部に見えている item を
  /// 基点に `delta` 件ぶん進めて (j = +1) / 戻して (k = -1) その item を
  /// リスト先頭 (alignment 0) に揃える。フィードリーダ風の 1 投稿送り。
  /// `scrollToTop` と同じ `scrollTo` 機構なので、ストリーミング差分挿入や
  /// アンカー復元のロジックとは競合しない (ユーザー操作のスクロールと等価)。
  void scrollByItems(int delta) {
    if (!_itemScrollController.isAttached || _items.isEmpty) return;
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    // 画面内に見えている item のうち、上端が最も上 (= 最上部) のものを基点に。
    final top = positions
        .where((p) => p.itemTrailingEdge > 0)
        .fold<ItemPosition?>(null, (acc, p) {
      if (acc == null || p.itemLeadingEdge < acc.itemLeadingEdge) return p;
      return acc;
    });
    if (top == null) return;
    final target = (top.index + delta).clamp(0, _items.length - 1);
    _itemScrollController.scrollTo(
      index: target,
      alignment: 0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  /// 外部 (ColumnHeader の refresh ボタン等) から強制リフレッシュさせる入口。
  /// 既存の `_refresh` を呼ぶだけのラッパー (in-flight refresh が居れば
  /// それに乗る)。
  Future<void> refresh() => _refresh();

  List<TimelineItem> _items = [];
  Map<String, String> _sinceIds = {}; // 各ソースごとのsinceId
  Map<String, String> _maxIds = {};   // 各ソースごとのmaxId
  final Map<String, String?> _nextUrls = {}; // ブックマーク・お気に入り用のnextURL
  Map<String, DateTime> _oldestDisplayedTimes = {}; // 各ソースごとの最古表示時刻
  bool _loadingMore = false;
  bool _initialLoading = true; // 初期ロード中フラグ
  bool _hasStartedLoading = false; // ロード開始済みフラグ
  DateTime? _lastRefreshTime; // 最後のリフレッシュ時刻

  /// 直近の初期ロードで全ソースが失敗したかどうか。
  /// `_items.isEmpty && _allSourcesFailed` の場合、空リストではなく
  /// 「読み込みに失敗しました」エラー画面 + リトライボタンを出す。
  bool _allSourcesFailed = false;

  /// 進行中の `_refresh` を表す Future。完了で null に戻す。
  /// 並列に複数の呼び出し元 (pull-to-refresh / SSE 再接続 / アプリ復帰 /
  /// 自分の投稿後 bus / タブ切替) があるため、同じ in-flight refresh を全員が
  /// await して 1 回にまとめる。SSE 再接続パスでは `_connectStream` がこれを
  /// await してから新規購読を開始するため、「SSE で先に届いた post が
  /// 既存トップに pin され、refresh で取った "間の投稿" がその下に挟まる」
  /// レース条件を回避できる。
  Future<void>? _refreshInFlight;

  /// SSE 接続のサイレント切断 watchdog。一定間隔で各 _StreamConnection の
  /// `lastEventAt` を確認し、長時間無音なら強制再接続する。
  Timer? _livenessCheckTimer;
  static const _livenessCheckInterval = Duration(seconds: 60);

  /// ハートビート未観測の接続の無音死亡判定閾値。update イベントしか生存
  /// 材料が無いため、静かな TL を誤って切らないよう長め (Web / コメント行を
  /// 剥がすプロキシ / ハートビート非対応サーバのフォールバック)。
  static const _livenessTimeoutSeconds = 600;

  /// `:thump` ハートビート (通常 15〜30 秒間隔) を観測済みの接続の閾値。
  /// 数回連続で途絶えたら切断とみなして素早く再接続する。切断検知が
  /// 最大 10 分 → 約 1.5〜2.5 分に縮み、「切断中の取り逃しが再接続 refresh で
  /// まとめて未読に積まれる」量が大幅に減る。
  static const _livenessTimeoutWithHeartbeatSeconds = 90;

  /// 引っ張って更新で取得した新着投稿のうち、まだ画面に表示されていないものの ID。
  /// バッジに件数表示し、スクロールで画面に入った投稿を順次取り除く。
  ///
  /// バッジ表示は `_unreadCount` (`ValueNotifier`) を介して `ValueListenableBuilder`
  /// で行うため、件数が変わってもタイムライン全体の rebuild は走らない。
  /// ストリーミング受信や高頻度スクロール中に `setState` 連発でリスト全体が
  /// rebuild されることを防ぐ。`_unreadIds` を変更したら必ず
  /// `_unreadCount.value = _unreadIds.length` で同期すること。
  final Set<String> _unreadIds = {};
  final ValueNotifier<int> _unreadCount = ValueNotifier<int>(0);

  /// SSE 切断バナー表示用の Notifier。`_markStreamConnected` /
  /// `_markStreamDisconnected` から `_syncStreamBanner()` 経由で更新する。
  /// 旧実装はこれを `setState({})` で出していたためタイムライン全体が
  /// rebuild され、再接続が頻繁な不安定回線ではスクロール詰まりの一因に
  /// なっていた。`ValueListenableBuilder` で個別購読する方式へ。
  final ValueNotifier<bool> _anyStreamDisconnected = ValueNotifier<bool>(false);

  /// 直近の build で ScrollablePositionedList に渡した itemCount。
  /// `_restoreScrollAnchor` の同期 jumpTo はパッケージ側で
  /// `widget.itemCount - 1` (= まだ旧リストの件数) にクランプされるため、
  /// 新 index がこれを超える場合は post-frame に遅延する判定に使う。
  int _lastBuiltItemCount = 0;

  /// アクティブなスクロール (drag / ballistic) のネスト数。0 でない間は
  /// ストリーム差分の `setState` + `jumpTo` を抑止する。フリック中に
  /// `jumpTo` を呼ぶと進行中の慣性スクロールが強制キャンセルされて
  /// 「新着が来るたびにスクロールが止まる」体感の主因になるため。
  /// `NotificationListener<ScrollNotification>` で増減し、0 に戻った
  /// タイミングで保留中の更新を post-frame でフラッシュする。
  int _scrollDepth = 0;
  bool get _isUserScrolling => _scrollDepth > 0;

  /// 最後に ScrollNotification (depth 0) を受け取った時刻。ScrollEnd の
  /// 取り逃しで `_scrollDepth` がスタックした場合の自己修復判定
  /// (`_onStreamUpdate`) に使う。
  DateTime? _lastScrollNotificationAt;

  /// `_items` に含まれる PostItem.status.id のキャッシュ。
  /// SSE は同期的に `_onStreamUpdate` を UI スレッドで叩くため、毎回 1000
  /// 件規模の `_items` を走査して Set を組むと 1〜3ms × N/秒 の sync 処理が
  /// スクロールフレーム予算を食い潰す ("受信の瞬間に止まる" の主因)。
  /// lazy 構築 + `_items` 変更時に invalidate することで O(1) ルックアップに
  /// する。差分 prepend 時は incremental 追加で再構築コストも回避。
  Set<String>? _knownIdsCache;

  Set<String> get _knownStatusIds {
    return _knownIdsCache ??= {
      for (final item in _items)
        if (item is PostItem) item.status.id,
    };
  }

  void _invalidateKnownIds() {
    _knownIdsCache = null;
  }

  /// SSE 接続の管理リスト。各カラムソースごとに 1 本。
  /// 自動再接続のために subscription だけでなく接続パラメタも保持する。
  final List<_StreamConnection> _streamConns = [];

  /// 直近の `streamingEnabled` 設定値。`ref.listen` で変化検出するためのキャッシュ。
  bool? _lastStreamingEnabled;

  /// ストリーム受信のバッファ。連合 TL のような高頻度ソースで複数の更新を
  /// まとめて適用するため、150ms 単位でフラッシュする。
  /// 1 回のフラッシュ = 1 回の setState + 1 回の jumpTo にすることで、
  /// アンカー復元の競合・jumpTo 連打によるスクロール詰まりを抑える。
  ///
  /// バッファに積むのは **生 JSON 文字列**。`Status.fromJson` (5KB JSON で
  /// 1〜3ms かかる再帰的オブジェクト構築) はフラッシュ時にまとめて行う。
  /// SSE は UI スレッドで同期に listen を回すため、毎イベントごとにパース
  /// すると 5〜10 イベント/秒の高頻度ストリームでフレーム予算を食い潰し
  /// スクロールを止める ("受信の瞬間に止まる" の真因)。
  final List<({String id, String raw, String accountId})>
      _pendingStreamUpdates = [];
  Timer? _streamFlushTimer;
  static const _streamFlushInterval = Duration(milliseconds: 150);

  /// `local_post_bus` の購読。post_page で投稿が成功すると accountId が
  /// 流れてくるので、自カラムソースに含まれていれば debounce 経由で
  /// `_refresh()` を発火する。SSE 設定や `isActive` と無関係に常時購読
  /// しておく (裏のタブでも投稿が取り込まれるよう、タブ復帰時に「あれ、
  /// 出てない」とならないため)。
  StreamSubscription<String>? _localPostSub;
  Timer? _localPostRefreshTimer;

  /// `local_status_event_bus` の購読。自分の投稿の編集 / 削除を即時に
  /// 反映するため、`_localPostSub` と同様にライフサイクル全体で常時購読
  /// しておく (裏のタブでも _items を整合させたいため)。
  StreamSubscription<LocalStatusEvent>? _localStatusEventSub;

  /// SSE 生 JSON から status ID を抜き出す軽量正規表現。Mastodon の JSON は
  /// `{"id":"...",...}` で始まるので先頭マッチで O(1) に取れる。マッチ失敗時
  /// は `_onStreamUpdate` 側で `json.decode` フォールバック。
  static final _statusIdRegex =
      RegExp(r'^\s*\{\s*"id"\s*:\s*"([^"]+)"');

  // 静的キャッシュ（カラム設定をキーにしてタイムラインデータを保持）
  static final Map<String, List<TimelineItem>> _cachedItems = {};
  static final Map<String, Map<String, String>> _cachedSinceIds = {};
  static final Map<String, Map<String, String>> _cachedMaxIds = {};

  @override
  bool get wantKeepAlive => true;

  String get _columnKey => widget.column.toString();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _itemPositionsListener.itemPositions.addListener(_onScrollPositions);
    // 自分の投稿即時反映用 bus は SSE 設定や `isActive` と無関係に常時購読する。
    // 裏のタブでも投稿を取り込むことで、タブ切替時に「あれ、投稿出てない」と
    // ならないようにする。
    _localPostSub = localPostStream.listen(_onLocalPost);
    _localStatusEventSub = localStatusEventStream.listen(_onLocalStatusEvent);
    // 初期化は build メソッドで auth の状態を確認してから行う
  }

  @override
  void didUpdateWidget(ColumnTimelineView oldWidget) {
    super.didUpdateWidget(oldWidget);

    // カラム設定 (sources) が差し替わったときに、State を破棄して再ロードする。
    // MainPage の `_updateTabController` はカラム数が同じ場合 GlobalKey を
    // 再生成せず同じ State を使い回すため、ユーザーが ColumnSettingsPage で
    // timelineType (home → local など) や accountId を変更すると、widget.column
    // だけ新しくなり _items は古い home の投稿のまま固定される
    // → 「ローカルに変えたのにホームが出る、再起動で直る」バグの原因。
    // toString 比較は (title, sources の Map/List) の合成文字列が同一かを
    // 見るだけだが、column_settings_page.dart の save() が常に新しい Map を
    // 作るため十分な精度で「変更されたかどうか」を判定できる。
    if (oldWidget.column.toString() != widget.column.toString()) {
      _unsubscribeFromStreams();
      _streamFlushTimer?.cancel();
      _pendingStreamUpdates.clear();
      setState(() {
        _items = [];
        _sinceIds = {};
        _maxIds = {};
        _nextUrls.clear();
        _oldestDisplayedTimes = {};
        _initialLoading = true;
        _hasStartedLoading = false;
        _allSourcesFailed = false;
        _unreadIds.clear();
      });
      _invalidateKnownIds();
      _syncUnreadCount();
      // 次の build で _loadFromCacheOrInitial が走るのでここでは呼ばない。
      // (build 前に postFrame で呼んでもよいが、build 内のフックに任せた方が
      //  「_initialLoading が立っている間は spinner を出す」など UI 状態と
      //  整合が取りやすい)
    }

    if (oldWidget.isActive != widget.isActive) {
      if (widget.isActive) {
        // タブに戻ってきた → SSE 復帰 + 取りこぼし埋め
        _maybeStartStreaming();
        // 裏で何か buffer が残っていたら吐く + 切断中の取りこぼしを回収
        if (_pendingStreamUpdates.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _flushPendingStreamUpdates();
          });
        }
        _refresh();
      } else {
        // 裏に回った → SSE を解除して CPU を解放
        _unsubscribeFromStreams();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _localPostSub?.cancel();
    _localPostSub = null;
    _localPostRefreshTimer?.cancel();
    _localPostRefreshTimer = null;
    _localStatusEventSub?.cancel();
    _localStatusEventSub = null;
    _unsubscribeFromStreams();
    _unreadCount.dispose();
    _anyStreamDisconnected.dispose();
    super.dispose();
  }

  /// `_unreadIds` の中身が変わったら必ず呼んで `ValueNotifier` を同期。
  /// バッジは `ValueListenableBuilder` で個別購読しているので、ここで通知
  /// するだけで全リスト rebuild なしにバッジだけが更新される。
  void _syncUnreadCount() {
    if (_unreadCount.value != _unreadIds.length) {
      _unreadCount.value = _unreadIds.length;
    }
  }

  /// `_unreadIds` から `_items` に存在しない id を取り除く。
  ///
  /// 通常は `_unreadIds` に積む id は同じ setState で `_items` にも積まれる
  /// ので不要だが、引っ張って更新と SSE フラッシュが交差したり、初期化中の
  /// _items 入替えなどで `_unreadIds` にだけ id が残ることが稀にあり、その
  /// 場合 `_onScrollPositions` の可視判定では取り除けず「新着 N 件」バッジが
  /// 永続化してしまう。`_items` を変更する各 setState の直後と
  /// `_onScrollPositions` の末尾で呼ぶことで、そういった orphan を掃除する。
  ///
  /// `_knownStatusIds` は `_items` 由来の lazy セットで O(1) ルックアップ。
  /// 未読件数は通常数十なので、コストは無視できる。
  void _pruneOrphanUnreadIds() {
    if (_unreadIds.isEmpty) return;
    final known = _knownStatusIds;
    _unreadIds.removeWhere((id) => !known.contains(id));
  }

  /// 切断バナーの表示要否を再評価して `_anyStreamDisconnected` に反映する。
  /// 接続状態が変わったら必ず呼ぶ。`setState` を経由しないのでリスト本体は
  /// rebuild されない。
  void _syncStreamBanner() {
    final shouldShow = _streamConns.isNotEmpty &&
        _streamConns.any((c) => !c.isConnected) &&
        (_lastStreamingEnabled ?? false);
    if (_anyStreamDisconnected.value != shouldShow) {
      _anyStreamDisconnected.value = shouldShow;
    }
  }

  // =================== SSE ストリーミング ===================

  /// 設定が ON のとき、各カラムソース (home/local/federated/list) に対し
  /// `update` イベントを購読して新着投稿を即時 prepend する。
  ///
  /// 各購読は `_StreamConnection` で管理され、エラー / 切断時は指数バック
  /// オフ (1s/2s/5s/10s/20s/30s) で自動再接続する。アプリの復帰時にも
  /// 全接続を作り直して OS による接続強制終了から復帰できるようにしている。
  void _subscribeToStreams() {
    _unsubscribeFromStreams(); // 二重購読防止

    final authState = ref.read(authProvider);
    if (authState.accounts.isEmpty) return;
    final sources = widget.column['sources'] as List;

    for (final source in sources) {
      final accId = source['accountId'] as String?;
      if (accId == null) continue;

      final tlType = source['timelineType'] as String? ?? 'home';
      // streaming 非対応のタイムラインタイプはスキップ
      if (tlType == 'bookmarks' || tlType == 'favourites') continue;

      final account = authState.accounts.firstWhere(
        (a) => a.id == accId,
        orElse: () => authState.accounts.first,
      );

      String? listId;
      String actualType = tlType;
      if (tlType.startsWith('list_')) {
        listId = tlType.substring(5);
        actualType = 'lists';
      }

      final conn = _StreamConnection(
        accountId: accId,
        instanceUrl: account.instanceUrl,
        accessToken: account.accessToken,
        timelineType: actualType,
        listId: listId,
      );
      _streamConns.add(conn);
      _connectStream(conn);
    }

    // サイレント切断検知 watchdog を起動 (購読が 1 つでもあれば回す)
    if (_streamConns.isNotEmpty) {
      _startLivenessChecker();
    }
  }

  /// 単一接続の購読開始 (再接続にも使う)。
  ///
  /// **再接続時 (= `conn.everConnected == true`) は購読を始める前に
  /// `_refresh()` を await する**。SSE は接続前のイベントを配信しないので、
  /// 切断中にサーバ側で起きた投稿は SSE では届かない。先に since_id ベースで
  /// fetch して "間の投稿" を埋めてから新規購読を始めることで、
  /// 「SSE で先に届いた新着が既存トップに pin され、後から refresh で
  /// 取った "間の投稿" がその下に挟まる」レース条件 (= 一番上に居るのに
  /// 未読バッジが消えない現象) を回避する (先行クライアントで実績のある方式)。
  ///
  /// 複数ソースがほぼ同時に再接続しても、`_refresh()` は `_refreshInFlight`
  /// で in-flight Future を共有するため fetch は 1 回にまとまる。
  ///
  /// 同じ conn に対する重複起動も `conn.connectInFlight` で合流させる。
  /// (forceReconnect / watchdog / scheduleReconnect が同時に同じ conn を
  /// 再接続しに来ても、二度目以降は最初の処理の完了を待つだけ。)
  Future<void> _connectStream(_StreamConnection conn) {
    return conn.connectInFlight ??=
        _doConnectStream(conn).whenComplete(() {
      conn.connectInFlight = null;
    });
  }

  Future<void> _doConnectStream(_StreamConnection conn) async {
    if (!mounted || !_streamConns.contains(conn)) return;
    if (!ref.read(settingsProvider).streamingEnabled) return;

    // 既存リソースをクリア
    conn.subscription?.cancel();
    conn.subscription = null;
    conn.reconnectTimer?.cancel();
    conn.reconnectTimer = null;

    // 再接続パス: 購読開始前に取り逃した投稿を取りに行く。
    // 初回接続 (everConnected == false) では `_loadInitial` 等で最新まで
    // 取れているので不要。
    if (conn.everConnected) {
      try {
        await _refresh();
      } catch (e) {
        debugPrint('[Stream] pre-subscribe refresh failed ${conn.key}: $e');
        // refresh 失敗でも購読は試みる (落ちる方が体験悪い)
      }
      if (!mounted || !_streamConns.contains(conn)) return;
      if (!ref.read(settingsProvider).streamingEnabled) return;
    }

    try {
      final stream = await subscribeTimelineUpdates(
        instanceUrl: conn.instanceUrl,
        accessToken: conn.accessToken,
        timelineType: conn.timelineType,
        listId: conn.listId,
        onHeartbeat: () {
          // `:thump` 受信 = 接続は生きている。watchdog のサイレント切断
          // 判定をリセットし、以降この接続には短い閾値
          // (_livenessTimeoutWithHeartbeatSeconds) を使わせる。
          conn.lastEventAt = DateTime.now();
          conn.sawHeartbeat = true;
        },
      );
      if (!mounted || !_streamConns.contains(conn)) {
        // conn 破棄後に接続が確立したケース。SSE の底の接続は listener が
        // 0 になった時の onCancel でしか閉じないため、listen → 即 cancel で
        // close を発火させる (放置すると HttpClient がリークする)。
        unawaited(stream.listen(null).cancel());
        return;
      }
      conn.subscription = stream.listen(
        (rawJson) {
          conn.attempt = 0; // 受信成功でバックオフリセット
          conn.lastEventAt = DateTime.now(); // watchdog 用
          _onStreamUpdate(rawJson, conn.accountId);
        },
        onError: (e) {
          debugPrint('[Stream] error ${conn.key}: $e');
          _markStreamDisconnected(conn);
          _scheduleReconnect(conn);
        },
        onDone: () {
          debugPrint('[Stream] closed ${conn.key}');
          _markStreamDisconnected(conn);
          _scheduleReconnect(conn);
        },
        cancelOnError: false,
      );
      debugPrint('[Stream] connected ${conn.key}');
      _markStreamConnected(conn);
    } catch (e) {
      debugPrint('[Stream] subscribe failed ${conn.key}: $e');
      _markStreamDisconnected(conn);
      _scheduleReconnect(conn);
    }
  }

  /// 接続状態が変わったので UI を再描画させる。バナー表示に使用。
  /// 再接続時の取り逃した投稿の埋め込みは `_connectStream` 側で
  /// 購読開始前に `_refresh()` を await することで対応している。
  void _markStreamConnected(_StreamConnection conn) {
    if (conn.isConnected) return;
    conn.isConnected = true;
    conn.everConnected = true;
    conn.lastEventAt = DateTime.now(); // watchdog: 接続確立も「生存」として扱う
    _syncStreamBanner();
  }

  void _markStreamDisconnected(_StreamConnection conn) {
    if (!conn.isConnected) return;
    conn.isConnected = false;
    _syncStreamBanner();
  }

  /// サイレント切断 watchdog を開始する。`_subscribeToStreams` から呼ばれる。
  /// 一定間隔で `_checkStreamLiveness` が走り、無音時間が閾値を超えた接続を
  /// 強制再接続する。
  void _startLivenessChecker() {
    _livenessCheckTimer?.cancel();
    _livenessCheckTimer = Timer.periodic(_livenessCheckInterval, (_) {
      _checkStreamLiveness();
    });
  }

  void _stopLivenessChecker() {
    _livenessCheckTimer?.cancel();
    _livenessCheckTimer = null;
  }

  void _checkStreamLiveness() {
    if (!mounted) return;
    if (!ref.read(settingsProvider).streamingEnabled) return;
    final now = DateTime.now();
    for (final conn in _streamConns) {
      // バックオフ中 (isConnected = false) は通常の再接続フローに任せる
      if (!conn.isConnected) continue;
      final last = conn.lastEventAt;
      if (last == null) continue; // 接続したばかりはスキップ
      // ハートビート観測済みなら「heartbeat が数回途絶えたら死亡」と素早く
      // 判定できる。未観測は update イベントしか材料が無いので長い閾値のまま。
      final timeoutSeconds = conn.sawHeartbeat
          ? _livenessTimeoutWithHeartbeatSeconds
          : _livenessTimeoutSeconds;
      final silentSeconds = now.difference(last).inSeconds;
      if (silentSeconds < timeoutSeconds) continue;

      debugPrint(
          '[Stream] silent for ${silentSeconds}s, force-reconnecting ${conn.key}');
      conn.attempt = 0; // バックオフをリセット
      // _connectStream は既存購読を中で cancel し、再接続時 (everConnected)
      // は購読開始前に `_refresh()` を await して取り逃した投稿を埋める。
      _markStreamDisconnected(conn);
      _connectStream(conn);
    }
  }

  static const _backoffSeconds = [1, 2, 5, 10, 20, 30];

  void _scheduleReconnect(_StreamConnection conn) {
    conn.subscription?.cancel();
    conn.subscription = null;
    conn.reconnectTimer?.cancel();

    if (!mounted || !_streamConns.contains(conn)) return;
    if (!ref.read(settingsProvider).streamingEnabled) return;

    conn.attempt++;
    final wait = _backoffSeconds[
        (conn.attempt - 1).clamp(0, _backoffSeconds.length - 1)];
    debugPrint(
        '[Stream] reconnect ${conn.key} in ${wait}s (attempt ${conn.attempt})');
    conn.reconnectTimer = Timer(Duration(seconds: wait), () {
      _connectStream(conn);
    });
  }

  /// 全接続を解除してリストもクリア。バッファ・フラッシュタイマもリセット。
  void _unsubscribeFromStreams() {
    for (final c in _streamConns) {
      c.subscription?.cancel();
      c.reconnectTimer?.cancel();
    }
    _streamConns.clear();
    _streamFlushTimer?.cancel();
    _streamFlushTimer = null;
    _pendingStreamUpdates.clear();
    _stopLivenessChecker();
    _syncStreamBanner(); // 接続が無くなったのでバナーを下げる
  }

  /// アプリ復帰時に接続を強制リセット。OS が裏でソケット切断していても
  /// 確実に再接続できるようにする。
  ///
  /// **`_pendingStreamUpdates` を必ずクリアする**。再接続前に SSE で届いて
  /// 未フラッシュのまま残っていた投稿を持ち越すと、続く `_connectStream` →
  /// `_refresh()` が since_id ベースで同じ範囲を取り直して `_items` に入れた
  /// 後、遅れて発火する `_flushPendingStreamUpdates` がそれらを `_items` に
  /// 再 prepend したり、ソート fallback 経路でユーザーの現在位置より下に
  /// interleave した投稿まで `_unreadIds` に積んでしまう (= バッジ件数 > 実際
  /// の未読、下スクロールで余剰分が消化される現象)。refresh が拾い直すので
  /// 投稿のロストはない。
  void _forceReconnectAllStreams() {
    if (!ref.read(settingsProvider).streamingEnabled) return;
    _pendingStreamUpdates.clear();
    _streamFlushTimer?.cancel();
    _streamFlushTimer = null;
    for (final c in _streamConns) {
      c.attempt = 0; // バックオフをリセット
      _connectStream(c); // 既存購読は中で cancel される
    }
  }

  /// 診断ログのオンオフ。スクロール詰まりの原因切り分け用。
  /// 通常は false。問題報告時のみ true にして実行ログを採取してもらう。
  static const bool _streamDebugLog = false;

  /// SSE で受信した新着投稿の **生 JSON** をバッファに積む。
  ///
  /// `Status.fromJson` (再帰的なオブジェクト構築) は重いのでここではやらず、
  /// 軽量正規表現で id だけ抜いて重複排除と buffer add で済ませる。フラッシュ
  /// 時にまとめて `json.decode` + `Status.fromJson` する。これで SSE 高頻度
  /// 受信のフレームコストが 1〜3ms/event → < 0.1ms/event 程度に下がり、
  /// スクロール中の "受信の瞬間に止まる" が解消する。
  void _onStreamUpdate(String rawJson, String accountId) {
    if (!mounted) return;
    final t0 = _streamDebugLog ? DateTime.now() : null;

    // 軽量正規表現で id を抜く。Mastodon の status JSON は `{"id":"..."` で
    // 始まるので先頭マッチで O(1)。マッチ失敗時のみ json.decode フォールバック。
    String? id = _statusIdRegex.firstMatch(rawJson)?.group(1);
    if (id == null) {
      try {
        final m = json.decode(rawJson) as Map<String, dynamic>;
        id = m['id'] as String?;
      } catch (_) {
        return; // malformed JSON は捨てる
      }
      if (id == null) return;
    }

    // 既存リスト・バッファ両方で重複排除。`_knownStatusIds` は lazy キャッシュ
    // なので、`_items` 変更後の初回だけ O(n)、以降は O(1)。
    if (_knownStatusIds.contains(id)) return;
    if (_pendingStreamUpdates.any((u) => u.id == id)) return;

    _pendingStreamUpdates
        .add((id: id, raw: rawJson, accountId: accountId));

    if (_streamDebugLog) {
      final dt = DateTime.now().difference(t0!).inMicroseconds;
      final pending = _pendingStreamUpdates.length;
      debugPrint('[Stream] recv id=$id scrolling=$_isUserScrolling '
          'depth=$_scrollDepth pending=$pending cost=$dt us');
    }

    // ユーザーがスクロール中はタイマーを armed しない (フリックを `jumpTo`
    // で潰さないため)。`ScrollEnd` 検出側でまとめてフラッシュする。
    if (_isUserScrolling) {
      // ScrollEnd の取り逃し (fling 中のバックグラウンド移行等) で
      // `_scrollDepth` がスタックすると、フラッシュの再アームが ScrollEnd
      // 頼みのため恒久停止する (復帰時のリセットだけではセッション中の
      // スタックを救えない)。スクロール通知が 10 秒以上途絶えているのに
      // 「スクロール中」はスタックとみなして自己修復する。指を置いたまま
      // 静止し続けるドラッグでは誤発動し得るが、その場合もフラッシュが
      // 1 回走るだけでフラッシュ恒久停止よりはるかに軽微。
      final last = _lastScrollNotificationAt;
      final stuck = last == null ||
          DateTime.now().difference(last) > const Duration(seconds: 10);
      if (!stuck) return;
      debugPrint(
          '[Stream] _scrollDepth stuck at $_scrollDepth, self-healing');
      _scrollDepth = 0;
    }

    // タイマー未起動なら 150ms 後にフラッシュを予約
    _streamFlushTimer ??= Timer(_streamFlushInterval, _flushPendingStreamUpdates);
  }

  /// `local_post_bus` から受け取った「自分が今投稿した Status」を
  /// 該当カラムに即時反映する。
  ///
  /// SSE が生きているケースは、サーバ側が同じ Status を SSE で配信して
  /// `local_post_bus` から「自分が投稿した accountId」を受け取って、
  /// 自カラムソースに該当アカウントが含まれていれば `_refresh()` を発火する。
  ///
  /// debounce 250ms: 連投 (複数アカウント同時投稿など) のとき、最後の
  /// 投稿から 250ms 待ってまとめて 1 回 refresh する。`_refresh()` 自身が
  /// `since_id` ベースなので 1 回で取り溢しなく拾える。
  ///
  /// timelineType 別フィルタは敢えて持たない: home / public / list / hashtag
  /// それぞれで「この投稿が乗るか」をクライアント側で正しく判定するのは
  /// 不可能 (特に hashtag/list)。サーバ側真実に任せた方が網羅性が高く、
  /// 余計な refresh も dedup でコストが抑えられる。
  void _onLocalPost(String accountId) {
    if (!mounted) return;
    final sources = widget.column['sources'] as List;
    final matches = sources.any((s) => (s['accountId'] as String?) == accountId);
    if (!matches) return;

    _localPostRefreshTimer?.cancel();
    _localPostRefreshTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _refresh();
    });
  }

  /// `local_status_event_bus` から「自分が編集/削除した」イベントを受けて
  /// `_items` の対応する PostItem を直接書き換える。
  ///
  /// 編集: id 一致の PostItem の status を `updated` に差し替える。
  ///       id は変わらないので `_knownIdsCache` の invalidate は不要。
  /// 削除: id 一致の PostItem を `_items` から取り除き、未読バッジの
  ///       orphan も掃除する。`_items` の集合が変わるので
  ///       `_invalidateKnownIds()` 必須。
  ///
  /// accountId は PostItem.accountId と照合する。別アカウントの TL に
  /// 同じ status が乗っている場合 (連合経由など)、そちらは別 id を持つので
  /// この event では触らない (= サーバ間で削除/編集が連合する分は、後で
  /// SSE の status.delete / status.update を購読する仕組みでカバーする
  /// 余地あり)。
  void _onLocalStatusEvent(LocalStatusEvent event) {
    if (!mounted) return;
    // 自カラムが操作元アカウントを含まないなら早期 return。
    final sources = widget.column['sources'] as List;
    final matches =
        sources.any((s) => (s['accountId'] as String?) == event.accountId);
    if (!matches) return;

    switch (event) {
      case LocalStatusDeleted():
        final before = _items.length;
        _items = _items
            .where((item) => !(item is PostItem &&
                item.accountId == event.accountId &&
                item.status.id == event.statusId))
            .toList();
        if (_items.length == before) return; // 該当なし

        _invalidateKnownIds();
        _unreadIds.remove(event.statusId);
        _syncUnreadCount();
        setState(() {});

      case LocalStatusEdited():
        var changed = false;
        _items = [
          for (final item in _items)
            if (item is PostItem &&
                    item.accountId == event.accountId &&
                    item.status.id == event.updated.id)
              () {
                changed = true;
                return PostItem(status: event.updated, accountId: item.accountId);
              }()
            else
              item,
        ];
        if (changed) setState(() {});
    }
  }

  /// バッファ内の全更新をまとめて適用する。
  ///
  /// **パフォーマンス**: 既存 `_items` を **再生成しない** 差分 prepend。
  /// 旧実装は 150ms ごとに「全 PostItem を `PostWithAccount` に変換 → 全件
  /// `createdAt` ソート → 全件ギャップ再検出 → 新 `_items` 生成」を回しており、
  /// `_items` が 1000 件まで貯まる本アプリではストリーミング中に
  /// 6〜7 回/秒の O(n log n) を背負っていた。差分 prepend に切り替えることで
  /// バッチサイズ k に対して O(k) で済む (典型的に k≦5)。
  ///
  /// **位置ずれ対策**:
  /// - `setState` の直前に live `itemPositions` から「最上部か」「topVisible
  ///   item の id と alignment」を読み取る。
  /// - 復元は `atTop` ケースでも **明示的に** `jumpTo` する。`atTop` 時に
  ///   何もしないで `ScrollablePositionedList` のデフォルト挙動に任せると、
  ///   prepend のたびに 1〜数ピクセルのズレが累積していく既知の問題がある。
  /// 1 回のフラッシュで処理する最大件数。これを超える分は次回フラッシュへ
  /// 持ち越し、catch-up 時の単発スタッターを抑える。10 件 × 1〜3ms parse =
  /// 10〜30ms 程度に収まるよう調整。
  static const int _maxBatchPerFlush = 10;

  void _flushPendingStreamUpdates() {
    _streamFlushTimer = null;
    if (_pendingStreamUpdates.isEmpty || !mounted) return;

    // スクロール中は setState + jumpTo を延期。`_onScrollEnd` が再開する。
    if (_isUserScrolling) {
      if (_streamDebugLog) {
        debugPrint('[Stream] flush skipped (scrolling, depth=$_scrollDepth, '
            'pending=${_pendingStreamUpdates.length})');
      }
      return;
    }

    final tFlushStart = _streamDebugLog ? DateTime.now() : null;

    // バッチ上限まで取り出す。残りは次回フラッシュへ。
    final take = _pendingStreamUpdates.length > _maxBatchPerFlush
        ? _maxBatchPerFlush
        : _pendingStreamUpdates.length;
    final rawBatch =
        _pendingStreamUpdates.sublist(0, take).toList(growable: false);
    _pendingStreamUpdates.removeRange(0, take);

    // ここで初めて重い `Status.fromJson` を実行 (= スクロール終了後 / アイドル
    // 時にしか走らない)。1 件あたり 1〜3ms かかるが、フラッシュは ScrollEnd
    // 経由でしか到達しないので慣性スクロール中のフレーム予算は食わない。
    // パース失敗 (malformed) は黙って捨てる。
    final batch = <({Status status, String accountId})>[];
    for (final entry in rawBatch) {
      try {
        final m = json.decode(entry.raw) as Map<String, dynamic>;
        batch.add(
            (status: Status.fromJson(m), accountId: entry.accountId));
      } catch (e) {
        debugPrint('[Stream] failed to parse status ${entry.id}: $e');
      }
    }
    if (batch.isEmpty) return;

    // setState 直前の live ポジションから状態を読む
    final atTop = _isAtTop();
    final anchor = atTop ? null : _captureScrollAnchor();

    // バッチ内だけソート (件数が少ないので軽い)。
    // サーバ側フィルタで hide 指定されたものはここで取り除く (SSE 経路用)。
    final batchPosts = batch
        .where((u) => !_isHiddenByFilter(u.status))
        .map((u) =>
            PostWithAccount(status: u.status, accountId: u.accountId))
        .toList();
    if (batchPosts.isEmpty) return;
    if (!_shouldDisableTimeSorting()) {
      batchPosts
          .sort((a, b) => b.status.createdAt.compareTo(a.status.createdAt));
    }

    // 既存リストの先頭 PostItem を取得 (差分 prepend の境界判定用)
    PostItem? firstExisting;
    for (final item in _items) {
      if (item is PostItem) {
        firstExisting = item;
        break;
      }
    }

    // 「全バッチ item が既存先頭より新しい」または「ソート無効」なら高速 prepend。
    // 連合遅延等でバッチに既存より古い投稿が混じる稀なケースだけ全ソートに
    // フォールバック。
    final canFastPrepend = firstExisting == null ||
        _shouldDisableTimeSorting() ||
        batchPosts.every((p) =>
            !p.status.createdAt.isBefore(firstExisting!.status.createdAt));

    setState(() {
      if (canFastPrepend) {
        // バッチ内の隣接ペアでギャップ検出 + バッチ末と既存先頭の境界ギャップ検出
        final newItems = <TimelineItem>[];
        for (int i = 0; i < batchPosts.length; i++) {
          final cur = batchPosts[i];
          newItems.add(PostItem(status: cur.status, accountId: cur.accountId));
          if (i < batchPosts.length - 1) {
            final gap = _maybeBuildGap(cur, batchPosts[i + 1]);
            if (gap != null) newItems.add(gap);
          }
        }
        if (firstExisting != null && batchPosts.isNotEmpty) {
          final boundary = _maybeBuildGap(
            batchPosts.last,
            PostWithAccount(
                status: firstExisting.status,
                accountId: firstExisting.accountId),
          );
          if (boundary != null) newItems.add(boundary);
        }
        _items = [...newItems, ..._items];
        // ホットパス: invalidate ではなく incremental に追加することで
        // 次回の `_onStreamUpdate` で O(n) 再構築を避ける。
        final cache = _knownIdsCache;
        if (cache != null) {
          for (final item in newItems) {
            if (item is PostItem) cache.add(item.status.id);
          }
        }
      } else {
        // フォールバック: 全件ソート再構築。既存の GapItem は
        // `_convertToTimelineItems` がギャップを再検出しない設計のため、
        // 退避して `_rebuildItemsWithGaps` で挿し直さないと全消失する
        // (= 「ストリーミング中にギャップボタンが消える」バグの原因)。
        final preservedGaps = _items.whereType<GapItem>().toList();
        final postsWithAccount = <PostWithAccount>[];
        postsWithAccount.addAll(batchPosts);
        for (final item in _items) {
          if (item is PostItem) {
            postsWithAccount.add(PostWithAccount(
                status: item.status, accountId: item.accountId));
          }
        }
        if (!_shouldDisableTimeSorting()) {
          postsWithAccount.sort(
              (a, b) => b.status.createdAt.compareTo(a.status.createdAt));
        }
        _items = _rebuildItemsWithGaps(postsWithAccount, const [], preservedGaps);
        _invalidateKnownIds();
      }

      // 最上部にいない場合のみ未読バッジに反映 (最上部時は即見えるので不要)。
      // フォールバック経路ではバッチに古い投稿が混じっており、ソートで
      // アンカー (= 視点) より下に interleave された分は上スクロールで通過
      // しないため未読に積まない (積むとバッジが減らなくなる)。
      // 高速 prepend 経路は全件が定義上アンカーより上なので全件追加で等価
      // (ホットパスなので O(アンカー位置) の走査を避けて従来通り)。
      if (!atTop) {
        if (canFastPrepend) {
          for (final u in batch) {
            _unreadIds.add(u.status.id);
          }
        } else {
          _unreadIds.addAll(unreadIdsAboveAnchor(
            items: _items,
            anchorKey: anchor?.id,
            candidateIds: {for (final u in batch) u.status.id},
          ));
        }
      }
    });
    _pruneOrphanUnreadIds();
    _syncUnreadCount();
    _saveToCache();

    // どのケースでも明示的に jumpTo して、パッケージのデフォルト挙動による
    // 位置ズレ累積を防ぐ。
    if (_itemScrollController.isAttached) {
      if (atTop) {
        // 最上部にいたなら新着が見えるよう先頭にピン留め
        _itemScrollController.jumpTo(index: 0, alignment: 0);
      } else if (anchor != null) {
        _restoreScrollAnchor(anchor);
      }
    }

    if (_streamDebugLog) {
      final dt = DateTime.now().difference(tFlushStart!).inMicroseconds;
      debugPrint('[Stream] flush done batch=${batch.length} '
          'parsed/${rawBatch.length} took=$dt us '
          'remaining=${_pendingStreamUpdates.length} '
          'atTop=$atTop scrolling=$_isUserScrolling');
    }

    // バッファに残りがあれば次回フラッシュを arming (スクロール中でなければ)。
    if (_pendingStreamUpdates.isNotEmpty && !_isUserScrolling) {
      _streamFlushTimer ??=
          Timer(_streamFlushInterval, _flushPendingStreamUpdates);
    }
  }

  /// 隣接 2 投稿間にギャップを挿入すべきなら GapItem を返す。
  /// `_convertToTimelineItems` 内のロジックを抽出したもの。
  GapItem? _maybeBuildGap(PostWithAccount newer, PostWithAccount older) {
    if (_shouldDisableGapDetection()) return null;
    if (newer.accountId != older.accountId) return null;
    final timeDiff =
        newer.status.createdAt.difference(older.status.createdAt);
    if (timeDiff.inMinutes <= 30) return null;

    final sources = widget.column['sources'] as List;
    final source = sources.firstWhere(
      (s) => s['accountId'] == newer.accountId,
      orElse: () => sources.first,
    );
    final timelineType = (source['timelineType'] ?? 'home') as String;

    // バッチ内の連続 2 投稿の時間ギャップは、検出方法の都合上「同一ソース内」
    // でしか出ない (newer.accountId == older.accountId)。なので perSource は
    // この 1 ソースのみ。他ソースの境界は fillGap 時に時間幅から派生させる
    // (現状の "派生" 経路と互換)。
    final gap = TimelineGap(
      id: 'gap_${newer.status.id}_${older.status.id}',
      anchorNewerStatusId: newer.status.id,
      perSource: {
        newer.accountId: SourceGapBounds(
          newerStatusId: newer.status.id,
          olderStatusId: older.status.id,
          timelineType: timelineType,
        ),
      },
      newerDate: newer.status.createdAt,
      olderDate: older.status.createdAt,
    );
    if (!gap.isSignificant) return null;
    return GapItem(gap: gap);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _onAppResumed();
    }
  }

  /// アプリ復帰時の処理
  void _onAppResumed() {
    // バックグラウンド中にユーザースクロールは有り得ないので、スクロール
    // 深度を強制リセットする。ScrollEndNotification を取り逃して
    // `_isUserScrolling` が true のまま残ると、SSE フラッシュの再アーム
    // 経路が ScrollEnd 頼みのため永遠にフラッシュされなくなる。
    _scrollDepth = 0;

    // ストリーミング接続は OS によって裏で切られている可能性が高いので
    // 復帰のたびに強制再接続する (バックオフはリセット)。非アクティブ
    // タブは購読そのものを持たないので no-op になる。
    // 再接続時は `_connectStream` が購読開始前に `_refresh()` を await する
    // ので、取り逃した投稿の埋め込みもこの経路で行われる。
    _forceReconnectAllStreams();

    // 非アクティブタブはユーザーに見えていないので、ここで重い refresh は
    // しない。タブに復帰した瞬間 (`didUpdateWidget`) で `_refresh` が走るので
    // 取りこぼしはそこで埋まる。
    if (!widget.isActive) return;

    // ストリーミングが無効 / 接続が無いケースでは `_forceReconnectAllStreams`
    // が no-op なので、5 分以上経過していれば明示的に refresh を発火する。
    // ストリーミング有効時も呼んで構わない (`_refreshInFlight` で dedup される)。
    if (_lastRefreshTime != null) {
      final timeSinceLastRefresh = DateTime.now().difference(_lastRefreshTime!);
      if (timeSinceLastRefresh.inMinutes > 5) {
        debugPrint(
            'App resumed after ${timeSinceLastRefresh.inMinutes} minutes, refreshing');
        _refresh();
      }
    }
  }

  /// タイムラインタイプをチェックする統合メソッド
  bool _hasTimelineType(String type) {
    final sources = widget.column['sources'] as List;
    return sources.any((source) {
      final timelineType = source['timelineType'] as String? ?? 'home';
      return timelineType == type;
    });
  }

  /// ブックマークまたはお気に入りを含むかチェック
  bool _hasBookmarksOrFavorites() {
    return _hasTimelineType('bookmarks') || _hasTimelineType('favourites');
  }

  /// ギャップ検出を無効化すべきタイムラインタイプかチェック
  bool _shouldDisableGapDetection() {
    final sources = widget.column['sources'] as List;
    return sources.any((source) {
      final timelineType = source['timelineType'] as String? ?? 'home';
      return timelineType == 'bookmarks' || 
             timelineType == 'favourites' || 
             timelineType.startsWith('list_');
    });
  }

  /// 時系列ソートを無効化すべきタイムラインタイプかチェック
  bool _shouldDisableTimeSorting() {
    return _hasBookmarksOrFavorites();
  }

  /// キャッシュから復元するか、初回読み込みを行う
  void _loadFromCacheOrInitial() {
    // build の postframe や他の非同期経路から呼ばれるため、発火時点で
    // 既に dispose 済みなら setState / ref.read が投げる。入口で弾く。
    if (!mounted) return;
    final cachedItems = _cachedItems[_columnKey];
    final cachedSinceIds = _cachedSinceIds[_columnKey];
    final cachedMaxIds = _cachedMaxIds[_columnKey];

    if (cachedItems != null && cachedItems.isNotEmpty) {
      // キャッシュから復元
      setState(() {
        _items = List.from(cachedItems);
        _sinceIds = Map.from(cachedSinceIds ?? {});
        _maxIds = Map.from(cachedMaxIds ?? {});
        _initialLoading = false; // キャッシュがあるので初期ロード完了
      });
      _invalidateKnownIds();
      _maybeStartStreaming();
      // 新しい投稿があるかチェック
      _refresh();
    } else {
      // 初回読み込み - アプリ起動時やキャッシュがない場合は必ず実行
      _loadInitial();
    }
  }

  /// 設定が ON ならストリーミング購読を開始する。データロード完了直後に呼ぶ。
  void _maybeStartStreaming() {
    if (!mounted) return;
    if (!widget.isActive) return; // 非アクティブタブは購読しない
    final enabled = ref.read(settingsProvider).streamingEnabled;
    if (enabled) {
      _subscribeToStreams();
    }
  }

  Future<void> _loadInitial() async {
    if (!mounted) return;
    final authState = ref.read(authProvider);
    final sources = widget.column['sources'] as List;
    
    if (sources.isEmpty) {
      setState(() {
        _items = [];
      });
      _invalidateKnownIds();
      return;
    }
    
    final List<PostWithAccount> allPosts = [];
    
    // 各ソースから並行して取得
    final futures = sources.map((source) async {
      final accId = source['accountId'] as String?;
      if (accId == null) {
        return const _SourceLoadResult(posts: [], failed: false);
      }

      if (authState.accounts.isEmpty) {
        return const _SourceLoadResult(posts: [], failed: false);
      }
      
      final account = authState.accounts.firstWhere(
        (a) => a.id == accId,
        orElse: () {
          return authState.accounts.first;
        },
      );
      final tlType = source['timelineType'] as String? ?? 'home';
      
      try {
        debugPrint('Fetching timeline for account $accId, type: $tlType');

        List<Status> posts;
        if (tlType == 'bookmarks' || tlType == 'favourites') {
          // Use new pagination function for bookmarks/favourites
          final result = await fetchBookmarksOrFavouritesWithPagination(
            instanceUrl: account.instanceUrl,
            accessToken: account.accessToken,
            timelineType: tlType,
            nextUrl: null, // Initial load
            limit: 20,
          );
          posts = result['statuses'] as List<Status>;

          // Store the nextUrl for pagination
          final sourceKey = '$accId-$tlType';
          _nextUrls[sourceKey] = result['nextUrl'] as String?;
        } else {
          // Use general timeline function for other types
          // リストの場合はtimelineTypeからlistIdを取得
          String? listId;
          String actualTimelineType = tlType;
          if (tlType.startsWith('list_')) {
            listId = tlType.substring(5);
            actualTimelineType = 'lists';
          }

          posts = await fetchTimelineForAccount(
            instanceUrl: account.instanceUrl,
            accessToken: account.accessToken,
            accountId: account.id,
            timelineType: actualTimelineType,
            listId: listId,
          );
        }


        if (posts.isNotEmpty) {
          final sourceKey = '$accId-$tlType';
          _sinceIds[sourceKey] = posts.first.id;
          _maxIds[sourceKey] = posts.last.id;
          _oldestDisplayedTimes[sourceKey] = posts.last.createdAt;
          debugPrint('Set maxId for $sourceKey: ${posts.last.id}');
        } else {
          debugPrint('No posts returned for $accId-$tlType');
        }

        return _SourceLoadResult(
          posts: posts.map((s) => PostWithAccount(status: s, accountId: accId)).toList(),
          failed: false,
        );
      } catch (e) {
        debugPrint('Failed to fetch timeline for $accId-$tlType: $e');
        return const _SourceLoadResult(posts: [], failed: true);
      }
    });

    final results = await Future.wait(futures);
    int failedCount = 0;
    // 同一アカウントの home + local を 1 カラムに統合した場合など、自分の
    // 公開投稿やローカルのフォロイーの投稿が複数ソースに重複して乗るため、
    // status id で重複排除する。`_refresh()` / SSE 受信側は既に dedup 済みで、
    // 初回ロードのこのパスだけ未対応だったので「起動時だけ二重表示される」
    // 状態になっていた。最初に出てきたソースの分を採用する。
    final seenStatusIds = <String>{};
    for (final result in results) {
      for (final p in result.posts) {
        if (seenStatusIds.add(p.status.id)) {
          allPosts.add(p);
        }
      }
      if (result.failed) failedCount++;
    }
    final allFailed = failedCount > 0 && failedCount == results.length;
    final partialFailure = failedCount > 0 && !allFailed;


    // 日時で降順ソート（ブックマークとお気に入りは除く）
    final shouldSort = !_shouldDisableTimeSorting();
    if (shouldSort) {
      allPosts.sort((a, b) => b.status.createdAt.compareTo(a.status.createdAt));
    }

    // PostWithAccountをTimelineItemに変換
    final items = _convertToTimelineItems(allPosts);

    if (mounted) {
      setState(() {
        _items = items;
        _initialLoading = false; // 初期ロード完了
        _allSourcesFailed = allFailed && items.isEmpty;
      });
      _invalidateKnownIds();
      // `_runRefresh` 経由 (_items が空のとき) で呼ばれた場合、旧 _items に
      // しか居なかった未読 id が残り得るので掃除する。
      _pruneOrphanUnreadIds();
      _syncUnreadCount();
      _maybeStartStreaming();

      debugPrint('_loadInitial complete: ${items.length} items, maxIds: $_maxIds');

      // 失敗時のフィードバック:
      // - allFailed なら全画面エラーで出るので SnackBar はスキップ (二重通知回避)
      // - partialFailure (一部のみ失敗) のときは控えめに SnackBar 通知
      if (partialFailure) {
        showErrorSnackBar(context, '一部のタイムラインの取得に失敗しました');
      }

      // キャッシュに保存
      _saveToCache();
    }
  }

  /// `ScrollNotification` ハンドラ。drag / ballistic の開始と終了を `_scrollDepth`
  /// の増減で追跡し、スクロール終了時に保留中のストリーム差分をフラッシュする。
  /// `notification.depth != 0` (内部の横スクロール等) は無視。
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    _lastScrollNotificationAt = DateTime.now();
    if (notification is ScrollStartNotification) {
      _scrollDepth++;
      if (_streamDebugLog) {
        debugPrint('[Stream] scroll START depth=$_scrollDepth '
            'pending=${_pendingStreamUpdates.length}');
      }
    } else if (notification is ScrollEndNotification) {
      _scrollDepth = (_scrollDepth - 1).clamp(0, 100);
      if (_streamDebugLog) {
        debugPrint('[Stream] scroll END depth=$_scrollDepth '
            'pending=${_pendingStreamUpdates.length}');
      }
      if (_scrollDepth == 0 && _pendingStreamUpdates.isNotEmpty) {
        // 通知ハンドラ内で同期に setState を呼ぶと build/paint 中に
        // 衝突しうるので、次フレームに逃がす。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_isUserScrolling) _flushPendingStreamUpdates();
        });
      }
    }
    return false;
  }

  void _onScrollPositions() {
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return;

    // `_lastKnownAtTop` をスクロールのたびに更新しておく (positions が
    // 空になったときのフォールバック値を新鮮に保つ)。
    _isAtTop();

    // 画面に少しでも見えている投稿を未読セットから取り除く。
    // バッジは ValueListenableBuilder で個別に購読しているので setState
    // は不要 (旧実装はスクロール毎に setState を撃ってリスト全体を rebuild
    // させており、これがスクロール詰まりの主因の一つだった)。
    if (_unreadIds.isNotEmpty) {
      for (final p in positions) {
        if (p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1 &&
            p.index >= 0 && p.index < _items.length) {
          final item = _items[p.index];
          if (item is PostItem) {
            _unreadIds.remove(item.status.id);
          }
        }
      }
      // 自己修復: 「未読 = 視点より上の新着」のセマンティクス上、最上部に
      // 居るのに未読が残っているのは定義矛盾 (ソート再構築で視点より下に
      // interleave された残骸など)。どんな経路で混入しても最上部到達で
      // 自然消滅させる。バッジタップ (scrollToTop + 全クリア) とも整合。
      if (_isAtTop()) {
        _unreadIds.clear();
      }
      _pruneOrphanUnreadIds();
      _syncUnreadCount();
    }

    // 既存: 末尾まで近づいたら追加読み込み
    if (_loadingMore) return;
    final maxIndex = positions.map((p) => p.index).reduce((a, b) => a > b ? a : b);
    if (maxIndex >= _items.length - 2) {
      _loadMore();
    }
  }

  /// キャッシュに保存
  void _saveToCache() {
    // キャッシュサイズ制限（最大1000件のアイテムを保持してギャップ補完に対応）
    final itemsToCache = _items.length > 1000 ? _items.take(1000).toList() : _items;
    _cachedItems[_columnKey] = List.from(itemsToCache);
    _cachedSinceIds[_columnKey] = Map.from(_sinceIds);
    _cachedMaxIds[_columnKey] = Map.from(_maxIds);
    
    // 古いキャッシュをクリア（最大15カラム分を保持してアプリ復帰時の体験向上）
    if (_cachedItems.length > 15) {
      final keys = _cachedItems.keys.toList();
      keys.take(keys.length - 15).forEach((key) {
        _cachedItems.remove(key);
        _cachedSinceIds.remove(key);
        _cachedMaxIds.remove(key);
      });
    }
  }

  /// PostWithAccountのリストをTimelineItemに変換し、ギャップを検出
  /// `PostWithAccount` のリストを `TimelineItem` のリストに単純変換する。
  ///
  /// **時間ベースのギャップ判定は行わない**。流れの遅い TL では「単に投稿が
  /// 少ない時間帯」と「実際に取り逃した区間」を時間間隔だけで区別するのは
  /// 不可能で、過剰な GapItem 表示の原因になっていた。
  ///
  /// 代わりに、本当にギャップがある可能性の高い局面 (SSE 切断後の再接続で
  /// 新着バッチが既存トップから大きく飛んだ時、引っ張って更新で limit 件
  /// めいっぱい返ってきた時) で、呼び出し側が明示的に GapItem を挿入する
  /// 設計に変更している。
  List<TimelineItem> _convertToTimelineItems(List<PostWithAccount> posts) {
    if (posts.isEmpty) return [];
    return [
      for (final p in posts)
        if (!_isHiddenByFilter(p.status))
          PostItem(status: p.status, accountId: p.accountId),
    ];
  }

  /// サーバ側フィルタ (Filters v2) の `filter_action: hide` に該当するか。
  /// ブースト投稿は元投稿 (reblog) 側のフィルタもチェックする。
  bool _isHiddenByFilter(Status s) {
    if (s.isFilterHidden) return true;
    final inner = s.reblog;
    if (inner != null && inner.isFilterHidden) return true;
    return false;
  }

  /// 各ソースが「limit 件めいっぱい返してきたソース」について、
  /// 「fetched の最古」と「既存 _items の最新」の間に GapItem を作る。
  ///
  /// 「めいっぱい返ってきた」=「もっとあるかもしれない」という Mastodon API の
  /// セマンティクスを使った確度の高いギャップ検出。アプリを長時間
  /// バックグラウンドにした後の復帰や、SSE 切断中の取りこぼしで
  /// 取りきれなかった分をユーザーに明示する。
  List<GapItem> _buildBoundaryGaps(
    List<({String accountId, String tlType, List<Status> fetched})>
        perSourceResults,
    int limit,
  ) {
    if (_shouldDisableGapDetection()) return const [];
    final gaps = <GapItem>[];
    for (final r in perSourceResults) {
      if (r.fetched.length < limit) continue;
      // newest-first で fetch しているので末尾が最古
      final oldestFetched = r.fetched.last;
      // _items は newest-first ソート済みなので、同ソースの最初の PostItem が
      // 「既存の最新」
      Status? newestExisting;
      for (final item in _items) {
        if (item is! PostItem) continue;
        if (item.accountId != r.accountId) continue;
        newestExisting = item.status;
        break;
      }
      if (newestExisting == null) continue;
      // 念のための健全性チェック: oldestFetched は newestExisting より新しい
      // はず (since_id ベースで取っているので)。逆転していたらギャップ無し。
      if (!oldestFetched.createdAt.isAfter(newestExisting.createdAt)) continue;

      final gap = TimelineGap(
        id: 'gap_${oldestFetched.id}_${newestExisting.id}',
        anchorNewerStatusId: oldestFetched.id,
        perSource: {
          r.accountId: SourceGapBounds(
            newerStatusId: oldestFetched.id,
            olderStatusId: newestExisting.id,
            timelineType: r.tlType,
          ),
        },
        newerDate: oldestFetched.createdAt,
        olderDate: newestExisting.createdAt,
      );
      gaps.add(GapItem(gap: gap));
    }
    return gaps;
  }

  /// 投稿リストを TimelineItem に変換しつつ、新規境界ギャップと既存ギャップを
  /// それぞれの newerStatusId 直下に再挿入する。`_items` を投稿ベースで
  /// 全再構築する経路 (refresh / SSE フラッシュのフォールバック / loadMore)
  /// は必ずこれを通してギャップを保全すること (`_convertToTimelineItems` は
  /// ギャップを再検出しないため、素通しすると既存 GapItem が全消失する)。
  /// 挿入ロジック本体は [insertGapsByAnchor] (純関数、unit test あり)。
  List<TimelineItem> _rebuildItemsWithGaps(
    List<PostWithAccount> allPosts,
    List<GapItem> newGaps,
    List<GapItem> preservedGaps,
  ) {
    return insertGapsByAnchor(
        _convertToTimelineItems(allPosts), newGaps, preservedGaps);
  }

  /// in-flight Future を共有して dedup する公開エントリ。
  /// pull-to-refresh / SSE 再接続 / アプリ復帰 / 自分の投稿後 bus / タブ切替
  /// など複数の呼び出し元があり、ほぼ同時に呼ばれても fetch は 1 回に
  /// まとまる。複数呼び出し元はすべて同じ Future を await できる。
  Future<void> _refresh() {
    return _refreshInFlight ??= _runRefresh().whenComplete(() {
      _refreshInFlight = null;
    });
  }

  Future<void> _runRefresh() async {
    // 更新前: 画面上端付近にあるアイテムの「ID と alignment」を記録しておき、
    // 更新後に同じ ID のアイテムを同じ alignment へ jumpTo することで
    // 視覚的な位置を完全にキープする (先行クライアントで実績のある方式)。
    // **最上部にいる場合も先頭へはピン留めしない**。refresh はアプリ復帰・
    // SSE 再接続・引っ張って更新で走り、特に復帰時は「見ていた位置から
    // 再開する」のが設計意図のため。新着はアンカーの上に積み、未読バッジで
    // 知らせる (バッジタップで最新へ)。最上部ピン留め (ticker 挙動) は SSE
    // フラッシュ (_flushPendingStreamUpdates) だけが行う。安易に「atTop なら
    // ピン留め」を足すと、バックグラウンド中の新着をまとめて取得する復帰時
    // refresh で読んでいた位置を失い最新へ飛ぶ回帰になる (fd6b1ed で一度発生)。
    final anchor = _captureScrollAnchor();

    final authState = ref.read(authProvider);
    final sources = widget.column['sources'] as List;

    if (_items.isEmpty) {
      await _loadInitial();
    } else if (_hasBookmarksOrFavorites()) {
      // bookmarks/favourites は Mastodon が「ブックマーク/お気に入り追加順」で
      // 返すため since_id (status_id ベース) による差分取得が機能しない
      // (古い投稿を新たにブックマークしても since_id で弾かれて表示されない)。
      // 列の先頭ページを取り直して置き換える。
      await _refreshNonChronological(authState, sources, anchor);
    } else {
      const limit = 40;
      // ソースごとの結果を保持し、境界ギャップ検出に使う
      final perSourceResults =
          <({String accountId, String tlType, List<Status> fetched})>[];

      final futures = sources.map((source) async {
        final accId = source['accountId'] as String?;
        if (accId == null || authState.accounts.isEmpty) {
          return (accountId: '', tlType: '', fetched: const <Status>[]);
        }

        final account = authState.accounts.firstWhere(
          (a) => a.id == accId,
          orElse: () => authState.accounts.first,
        );
        final tlType = source['timelineType'] as String;
        final sourceKey = '$accId-$tlType';

        try {
          // リストの場合はtimelineTypeからlistIdを取得
          String? listId;
          String actualTimelineType = tlType;
          if (tlType.startsWith('list_')) {
            listId = tlType.substring(5);
            actualTimelineType = 'lists';
          }

          final newer = await fetchTimelineForAccount(
            instanceUrl: account.instanceUrl,
            accessToken: account.accessToken,
            accountId: account.id,
            timelineType: actualTimelineType,
            listId: listId,
            sinceId: _sinceIds[sourceKey],
            limit: limit,
          );

          if (newer.isNotEmpty) {
            _sinceIds[sourceKey] = newer.first.id;
          }

          return (accountId: accId, tlType: tlType, fetched: newer);
        } catch (e) {
          debugPrint('Error refreshing timeline for $accId: $e');
          return (accountId: accId, tlType: tlType, fetched: const <Status>[]);
        }
      });

      final results = await Future.wait(futures);
      perSourceResults.addAll(results);

      // ストリーミングで既に取り込んだ投稿とバッファ内の投稿の両方に
      // 対して重複排除する。これを怠ると引っ張って更新で同じ投稿が
      // タイムラインに二重に並ぶ。
      final knownIds = <String>{
        ..._items.whereType<PostItem>().map((p) => p.status.id),
        ..._pendingStreamUpdates.map((u) => u.id),
      };
      final newPosts = <PostWithAccount>[];
      for (final r in perSourceResults) {
        for (final s in r.fetched) {
          if (knownIds.add(s.id)) {
            newPosts.add(PostWithAccount(status: s, accountId: r.accountId));
          }
        }
      }

      if (newPosts.isNotEmpty) {
        newPosts
            .sort((a, b) => b.status.createdAt.compareTo(a.status.createdAt));

        // 境界ギャップ検出: limit 件めいっぱい返したソースについて、新着の
        // 最古と既存の最新の間にギャップを挿入。
        final boundaryGaps = _buildBoundaryGaps(perSourceResults, limit);

        setState(() {
          // 既存の投稿リストとギャップを取り出し
          final existingPosts = <PostWithAccount>[];
          final preservedGaps = <GapItem>[];
          for (final item in _items) {
            if (item is PostItem) {
              existingPosts.add(PostWithAccount(
                  status: item.status, accountId: item.accountId));
            } else if (item is GapItem) {
              preservedGaps.add(item);
            }
          }

          // 新旧の投稿を結合
          final allPosts = [...newPosts, ...existingPosts];
          // ブックマークとお気に入り以外の場合のみソート
          if (!_shouldDisableTimeSorting()) {
            allPosts.sort(
                (a, b) => b.status.createdAt.compareTo(a.status.createdAt));
          }

          _items = _rebuildItemsWithGaps(
            allPosts,
            boundaryGaps,
            preservedGaps,
          );

          // 新着分のうち「視点 (アンカー) より上に入ったもの」だけを未読
          // バッジに追加する。複数アカウント統合カラムでは遅れていたソースの
          // 取得分がソートで視点より下に interleave されることがあり、それを
          // 未読に積むと上スクロールで通過せず可視判定で消えない
          // (= バッジ件数が実際と合わなくなる) ため。
          _unreadIds.addAll(unreadIdsAboveAnchor(
            items: _items,
            anchorKey: anchor?.id,
            candidateIds: newPosts.map((p) => p.status.id).toSet(),
          ));
        });
        _invalidateKnownIds();
        _pruneOrphanUnreadIds();
        _syncUnreadCount();
        _saveToCache(); // キャッシュ更新
        _restoreScrollAnchor(anchor);
      }
    }

    _lastRefreshTime = DateTime.now();
  }

  /// bookmarks/favourites 専用の引っ張って更新。先頭ページを取り直して
  /// `_items` を完全に置き換える。`_nextUrls` / `_maxIds` / `_sinceIds` /
  /// `_oldestDisplayedTimes` も初期ロード相当に再設定。
  Future<void> _refreshNonChronological(
    AuthState authState,
    List sources,
    ({String id, double alignment})? anchor,
  ) async {
    final futures = sources.map((source) async {
      final accId = source['accountId'] as String?;
      if (accId == null || authState.accounts.isEmpty) {
        return const _SourceLoadResult(posts: [], failed: false);
      }

      final account = authState.accounts.firstWhere(
        (a) => a.id == accId,
        orElse: () => authState.accounts.first,
      );
      final tlType = source['timelineType'] as String? ?? 'home';
      final sourceKey = '$accId-$tlType';

      try {
        final result = await fetchBookmarksOrFavouritesWithPagination(
          instanceUrl: account.instanceUrl,
          accessToken: account.accessToken,
          timelineType: tlType,
          nextUrl: null,
          limit: 20,
        );
        final posts = result['statuses'] as List<Status>;
        _nextUrls[sourceKey] = result['nextUrl'] as String?;
        if (posts.isNotEmpty) {
          _sinceIds[sourceKey] = posts.first.id;
          _maxIds[sourceKey] = posts.last.id;
          _oldestDisplayedTimes[sourceKey] = posts.last.createdAt;
        }
        return _SourceLoadResult(
          posts: posts
              .map((s) => PostWithAccount(status: s, accountId: accId))
              .toList(),
          failed: false,
        );
      } catch (e) {
        debugPrint('Failed to refresh $tlType for $accId: $e');
        return const _SourceLoadResult(posts: [], failed: true);
      }
    });

    final results = await Future.wait(futures);
    final allPosts = <PostWithAccount>[];
    int failedCount = 0;
    for (final r in results) {
      allPosts.addAll(r.posts);
      if (r.failed) failedCount++;
    }
    final partialFailure = failedCount > 0 && failedCount < results.length;

    if (!mounted) return;
    final items = _convertToTimelineItems(allPosts);
    setState(() {
      _items = items;
    });
    _invalidateKnownIds();
    _pruneOrphanUnreadIds();
    _syncUnreadCount();
    _saveToCache();
    _restoreScrollAnchor(anchor);

    if (partialFailure) {
      showErrorSnackBar(context, '一部のタイムラインの取得に失敗しました');
    }
  }

  /// `_isAtTop` が最後に positions から実測できた値。positions が空 (復帰
  /// 直後などレイアウト未確定) のときのフォールバックに使う。初期値は
  /// true (タイムラインは先頭から始まるため)。
  bool _lastKnownAtTop = true;

  /// 現在「最上部にいる」とみなせるか。index 0 が画面に存在し、leading edge が
  /// -0.05 以上 (= ほぼ視界の上端まで来ている) なら true。
  /// 引っ張って更新時のオーバースクロール程度のズレは true 扱い。
  /// positions が空のときは最後に実測できた値を返す (false 固定だと
  /// 最上部にいてもアンカー復元経路に落ちて先頭ピン留めが剥がれる)。
  bool _isAtTop() {
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return _lastKnownAtTop;
    final atTop = positions.any(
      (p) => p.index == 0 && p.itemLeadingEdge >= -0.05,
    );
    _lastKnownAtTop = atTop;
    return atTop;
  }

  /// 指定 index 以降にある「画面に見えているアイテム」のうち、画面上端に
  /// 最も近いものの ID と alignment を記録する。`_fillGap(keepBottom: true)`
  /// で「ギャップ下のアイテムを画面位置に固定する」ために使う。
  ///
  /// 該当が無ければ null を返す。呼び出し側で `_captureScrollAnchor()` への
  /// フォールバックを行う想定。
  ({String id, double alignment})? _captureAnchorAtOrAfter(int fromIndex) {
    final positions = _itemPositionsListener.itemPositions.value;
    ItemPosition? best;
    for (final p in positions) {
      if (p.index < fromIndex) continue;
      if (p.itemTrailingEdge <= 0) continue; // 画面上端より上 = 不可視
      if (best == null || p.itemLeadingEdge < best.itemLeadingEdge) {
        best = p;
      }
    }
    if (best == null) return null;
    if (best.index >= _items.length) return null;

    final item = _items[best.index];
    final id = switch (item) {
      PostItem(:final status) => 'post:${status.id}',
      GapItem(:final gap) => 'gap:${gap.id}',
      _ => null,
    };
    if (id == null) return null;
    return (id: id, alignment: best.itemLeadingEdge);
  }

  /// 現在画面に表示中のアイテムのうち、画面上端に最も近いものの
  /// 「ID と alignment」を記録する。
  ///
  /// alignment は `scrollable_positioned_list` の itemLeadingEdge と同じ意味で、
  /// 0.0 が画面最上端、1.0 が画面最下端。負の値はアイテムが上に隠れた状態。
  ({String id, double alignment})? _captureScrollAnchor() {
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return null;

    // 画面内に見えている (= trailing edge が画面上端より下) アイテムの中で、
    // 上端に最も近い (= leading edge が最小) ものを選ぶ
    final topVisible = positions
        .where((p) => p.itemTrailingEdge > 0)
        .fold<ItemPosition?>(null, (best, p) {
      if (best == null) return p;
      return p.itemLeadingEdge < best.itemLeadingEdge ? p : best;
    });
    if (topVisible == null) return null;
    if (topVisible.index >= _items.length) return null;

    final item = _items[topVisible.index];
    final id = switch (item) {
      PostItem(:final status) => 'post:${status.id}',
      GapItem(:final gap) => 'gap:${gap.id}',
      _ => null,
    };
    if (id == null) return null;
    return (id: id, alignment: topVisible.itemLeadingEdge);
  }

  /// タップされた投稿を新しいスクロールアンカーに移し替える。
  ///
  /// `ScrollablePositionedList` はアンカー位置を保持するため、アンカーより
  /// 上のアイテムが伸縮すると上方向に伸びる挙動になる。投稿アクションバー
  /// 表示の際は、その投稿自身をアンカーにすることで下方向に伸びるようにする。
  /// alignment は変えないので画面上の見た目は一切動かない。
  ///
  /// 注: 同期で `jumpTo` を呼ぶとスリバー再構成で PostTile の State が
  /// dispose / recreate されるが、`_showActions` は static map で保持して
  /// いるので新 State でも値は失われない。同一フレーム内でアンカー変更と
  /// `_showActions = true` を反映させることで「一瞬上に伸びて下に直る」
  /// フリッカが起きないようにしている。
  void _setAnchorToPost(String statusId) {
    if (!_itemScrollController.isAttached) return;
    final idx = _items.indexWhere(
      (item) => item is PostItem && item.status.id == statusId,
    );
    if (idx < 0) return;
    final positions = _itemPositionsListener.itemPositions.value
        .where((p) => p.index == idx);
    if (positions.isEmpty) return;
    _itemScrollController.jumpTo(
      index: idx,
      alignment: positions.first.itemLeadingEdge,
    );
  }

  /// 記録しておいたアンカーを使って、更新後のリストでも同じ視覚位置にスクロール。
  ///
  /// 注: `setState` 直後に **同期で** 呼ぶこと。
  ///   `addPostFrameCallback` で次フレームに回すと、リスト更新と `jumpTo` の
  ///   反映タイミングがズレ、1 フレーム間「古いアンカーインデックス + 新リスト」
  ///   の組み合わせで誤った投稿が一瞬表示される (チカチカの原因)。
  ///   同期で `jumpTo` すれば、次の build/layout で `_items` と controller の
  ///   target が両方新しい状態のまま一回で描画される。
  void _restoreScrollAnchor(({String id, double alignment})? anchor) {
    if (anchor == null) return;
    if (!mounted || !_itemScrollController.isAttached) return;
    final newIndex = _indexOfAnchorId(anchor.id);
    if (newIndex < 0) return; // アンカーが消えていた場合は何もしない

    // パッケージの `_jumpTo` は `index > widget.itemCount - 1` のとき index を
    // 旧末尾へクランプする。同期呼び出し時点では ScrollablePositionedList の
    // widget はまだ旧リスト (旧 itemCount) のままなので、「アンカーより上に
    // 大量挿入」してアンカーの新 index が旧件数を超えるケース
    // (_fillGap の下側キープが典型。最大 200 件/ソース挿入する) では、
    // クランプされた index = 挿入ブロックの途中へ飛んでしまい「位置キープの
    // はずがだいぶ上にずれる」になる。この場合だけ次フレーム (新 itemCount で
    // rebuild 済み) に遅延して jumpTo する。1 フレームだけズレた位置が描画
    // される代償はあるが、位置が失われたままになるよりよい。
    if (newIndex >= _lastBuiltItemCount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_itemScrollController.isAttached) return;
        // フレームを跨いだので index を id から取り直す
        final idx = _indexOfAnchorId(anchor.id);
        if (idx < 0) return;
        _itemScrollController.jumpTo(index: idx, alignment: anchor.alignment);
      });
      return;
    }
    _itemScrollController.jumpTo(
      index: newIndex,
      alignment: anchor.alignment,
    );
  }

  /// `_captureScrollAnchor` 形式のアンカー id (`post:<id>` / `gap:<id>`) を
  /// 現在の `_items` の index に解決する。見つからなければ -1。
  int _indexOfAnchorId(String anchorId) {
    return _items.indexWhere((item) {
      return switch (item) {
        PostItem(:final status) => 'post:${status.id}' == anchorId,
        GapItem(:final gap) => 'gap:${gap.id}' == anchorId,
        _ => false,
      };
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore) {
      debugPrint('Already loading more, skipping');
      return;
    }
    
    if (_maxIds.isEmpty) {
      debugPrint('No maxIds available, cannot load more');
      return;
    }
    
    _loadingMore = true;

    final auth = ref.read(authProvider);
    final sources = widget.column['sources'] as List;
    List<PostWithAccount> olderPosts = [];
    
    
    final futures = sources.map((source) async {
      final accId = source['accountId'] as String?;
      if (accId == null) return <PostWithAccount>[];
      
      if (auth.accounts.isEmpty) {
        return <PostWithAccount>[];
      }
      
      final account = auth.accounts.firstWhere(
        (a) => a.id == accId,
        orElse: () => auth.accounts.first,
      );
      final tlType = source['timelineType'] as String;
      final sourceKey = '$accId-$tlType';
      
      if (!_maxIds.containsKey(sourceKey)) {
        // Try to initialize maxId from currently visible posts
        final lastVisiblePost = _items
            .whereType<PostItem>()
            .where((item) => item.accountId == accId)
            .lastOrNull;
        if (lastVisiblePost != null) {
          _maxIds[sourceKey] = lastVisiblePost.status.id;
        } else {
          return <PostWithAccount>[];
        }
      }
      
      
      try {
        List<Status> older;
        if (tlType == 'bookmarks' || tlType == 'favourites') {
          // Use new pagination function with nextUrl
          final nextUrl = _nextUrls[sourceKey];
          if (nextUrl != null) {
            final result = await fetchBookmarksOrFavouritesWithPagination(
              instanceUrl: account.instanceUrl,
              accessToken: account.accessToken,
              timelineType: tlType,
              nextUrl: nextUrl,
              limit: 20,
            );
            older = result['statuses'] as List<Status>;
            
            // Update nextUrl for next pagination
            _nextUrls[sourceKey] = result['nextUrl'] as String?;
          } else {
            older = [];
          }
        } else {
          // Use general timeline function for other types
          // リストの場合はtimelineTypeからlistIdを取得
          String? listId;
          String actualTimelineType = tlType;
          if (tlType.startsWith('list_')) {
            listId = tlType.substring(5);
            actualTimelineType = 'lists';
          }
          
          debugPrint('Fetching older posts: accountId=$accId, timelineType=$actualTimelineType, listId=$listId, maxId=${_maxIds[sourceKey]}');
          
          older = await fetchTimelineForAccount(
            instanceUrl: account.instanceUrl,
            accessToken: account.accessToken,
            accountId: account.id,
            timelineType: actualTimelineType,
            listId: listId,
            maxId: _maxIds[sourceKey],
            limit: 40,
          );
          
          debugPrint('API returned ${older.length} posts for $sourceKey');
        }
        
        debugPrint('Checking if older.isNotEmpty: ${older.isNotEmpty} (length: ${older.length})');
        
        if (older.isNotEmpty) {
          if (tlType == 'bookmarks' || tlType == 'favourites') {
            // For bookmarks/favourites, the dedicated function already handles duplicates
            // Simply use the last post ID for next pagination
            debugPrint('Updating maxId for $sourceKey: ${_maxIds[sourceKey]} -> ${older.last.id}');
            _maxIds[sourceKey] = older.last.id;
            _oldestDisplayedTimes[sourceKey] = older.last.createdAt;
          } else {
            // For other timelines, find the chronologically oldest post
            final chronOldest = older.reduce((a, b) => 
              a.createdAt.isBefore(b.createdAt) ? a : b);
            debugPrint('Updating maxId for $sourceKey: ${_maxIds[sourceKey]} -> ${chronOldest.id}');
            _maxIds[sourceKey] = chronOldest.id;
          }
        } else {
          // For bookmarks/favourites, if we get no results, we might have reached the end
          // Don't remove the maxId as we might retry later
          debugPrint('No older posts returned for $sourceKey');
        }
        
        return older.map((s) => PostWithAccount(status: s, accountId: accId)).toList();
      } catch (e) {
        debugPrint('Error in _loadMore future for $accId: $e');
        return <PostWithAccount>[];
      }
    });
    
    final results = await Future.wait(futures);
    for (final result in results) {
      olderPosts.addAll(result);
    }
    
    
    if (olderPosts.isNotEmpty) {
      
      // フィルタリング: ブックマーク/お気に入りは時刻フィルタをスキップ
      final filteredPosts = <PostWithAccount>[];
      
      for (final post in olderPosts) {
        final source = widget.column['sources'].firstWhere(
          (s) => s['accountId'] == post.accountId,
          orElse: () => null,
        );
        
        if (source != null) {
          final tlType = source['timelineType'] as String? ?? 'home';
          
          if (tlType == 'bookmarks' || tlType == 'favourites') {
            filteredPosts.add(post);
          } else {
            final sourceKey = '${post.accountId}-$tlType';
            final oldestTime = _oldestDisplayedTimes[sourceKey];
            if (oldestTime == null || post.status.createdAt.isBefore(oldestTime)) {
              filteredPosts.add(post);
            }
          }
        }
      }
      
      
      if (filteredPosts.isNotEmpty) {
        
        // 重複チェック: `_items` だけでなく未フラッシュの SSE バッファ
        // (`_pendingStreamUpdates`) も突合する。bookmarks/favourites のように
        // 時系列順でないタイムラインでは SSE 由来の新着と loadMore の取得が
        // ID 空間で衝突しうるため、両方見ないと二重表示になる。
        final existingIds = <String>{
          ..._items.whereType<PostItem>().map((item) => item.status.id),
          ..._pendingStreamUpdates.map((u) => u.id),
        };
        final uniquePosts = filteredPosts.where((post) => !existingIds.contains(post.status.id)).toList();
        
        if (uniquePosts.isEmpty) {
          _loadingMore = false;
          return;
        }

        // setState 直前にアンカーを capture。下方 append とはいえ、
        // `_convertToTimelineItems` がリスト全体を再構築 → ギャップ検出も再走
        // するため、上方の item 数が変わって ScrollablePositionedList 内部
        // アンカー index がズレうる。明示的に復元してドリフトを防ぐ。
        final anchor = _captureScrollAnchor();

        setState(() {
          // 既存の投稿とギャップを取得 (ギャップは再構築後に挿し直して保全する)
          final existingPosts = _items.whereType<PostItem>().toList();
          final preservedGaps = _items.whereType<GapItem>().toList();

          // 新しい投稿をPostItemに変換
          final newPostItems = uniquePosts.map((p) =>
            PostItem(status: p.status, accountId: p.accountId)
          ).toList();

          // 既存と新規を結合してソート
          final allPosts = [...existingPosts, ...newPostItems];
          if (!_shouldDisableTimeSorting()) {
            allPosts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
          }

          // PostWithAccountリストに変換
          final sortedPostsWithAccount = allPosts.map((item) =>
            PostWithAccount(status: item.status, accountId: item.accountId)
          ).toList();

          // 投稿ベースで再構築し、既存ギャップを元のアンカー直下に挿し直す
          _items = _rebuildItemsWithGaps(
              sortedPostsWithAccount, const [], preservedGaps);

          // 各アカウントの最古表示時刻を更新（全体から）
          final accountOldestMap = <String, DateTime>{};
          for (final item in _items) {
            if (item is PostItem) {
              final source = widget.column['sources'].firstWhere(
                (s) => s['accountId'] == item.accountId,
                orElse: () => null,
              );

              if (source != null) {
                final sourceKey = '${item.accountId}-${source['timelineType']}';
                final currentTime = item.createdAt;

                if (!accountOldestMap.containsKey(sourceKey) ||
                    currentTime.isBefore(accountOldestMap[sourceKey]!)) {
                  accountOldestMap[sourceKey] = currentTime;
                }
              }
            }
          }

          // 更新された最古時刻を設定
          _oldestDisplayedTimes = accountOldestMap;
        });
        _invalidateKnownIds();
        _pruneOrphanUnreadIds();
        _syncUnreadCount();
        _saveToCache(); // キャッシュ更新

        if (anchor != null) {
          _restoreScrollAnchor(anchor);
        }
      }
    }

    _loadingMore = false;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin用

    // ストリーミング設定の変化を捕捉して購読 ON/OFF を切り替える
    final streamingEnabled =
        ref.watch(settingsProvider.select((s) => s.streamingEnabled));

    // タイムラインの区切り方 (line / card)。.select で限定購読しているので
    // 他の Settings 変更で本ビルドが re-render されることはない。
    final timelineLayout =
        ref.watch(settingsProvider.select((s) => s.timelineLayout));
    if (_lastStreamingEnabled != streamingEnabled) {
      _lastStreamingEnabled = streamingEnabled;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (streamingEnabled &&
            !_initialLoading &&
            _items.isNotEmpty &&
            widget.isActive) {
          _subscribeToStreams();
        } else if (!streamingEnabled) {
          _unsubscribeFromStreams();
        }
      });
    }

    // auth の状態を監視
    final authState = ref.watch(authProvider);
    
    // アカウントがまだロードされていない場合
    if (authState.accounts.isEmpty) {
      debugPrint('No accounts loaded yet for timeline, column: $_columnKey');
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('アカウント情報を読み込み中...'),
          ],
        ),
      );
    }

    // カラムのソースをチェック
    final sources = widget.column['sources'] as List?;
    if (sources == null || sources.isEmpty) {
      return const Center(
        child: Text('このカラムにはソースが設定されていません'),
      );
    }

    // 初回のみデータロードを開始
    if (!_hasStartedLoading &&
        _initialLoading &&
        _items.isEmpty &&
        _refreshInFlight == null) {
      _hasStartedLoading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _loadFromCacheOrInitial();
      });
    }
    
    // 初期ロード中の表示
    if (_initialLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    // 全ソースが取得失敗 + キャッシュ無し → エラー画面 + リトライ
    if (_allSourcesFailed && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 56, color: Colors.grey),
              const SizedBox(height: 12),
              const Text('タイムラインの取得に失敗しました',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                'ネットワーク接続を確認して再試行してください',
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('再試行'),
                onPressed: () {
                  setState(() {
                    _allSourcesFailed = false;
                    _initialLoading = true;
                  });
                  _loadInitial();
                },
              ),
            ],
          ),
        ),
      );
    }

    // `_restoreScrollAnchor` のクランプ判定用に、今回 SPL へ渡す itemCount を
    // 記録しておく (build 後も SPL の widget.itemCount はこの値のまま)。
    _lastBuiltItemCount = _items.length + (_loadingMore ? 1 : 0);

    final Widget timelineList = RefreshIndicator(
      // 効果音 (フォアグラウンドのみ・既定 OFF) は手動プルの入口でだけ鳴らす。
      // `_refresh()` 本体は再接続・タブ復帰・ギャップ復旧でも呼ばれるため、
      // そこには差さない (意図しない発音を避ける)。
      onRefresh: () async {
        if (ref.read(settingsProvider).soundOnRefresh) {
          SoundService.instance.refresh();
        }
        await _refresh();
      },
      child: Stack(
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: ScrollablePositionedList.separated(
              itemCount: _lastBuiltItemCount,
              itemBuilder: (ctx, i) {
                if (i >= _items.length) {
                  // 「もっと読み込み中」スピナーは投稿ではないので
                  // 区切りスタイルに関わらず常にプレーン表示。
                  return const Padding(
                    padding: EdgeInsets.all(8),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final item = _items[i];
                Widget? content;
                if (item is PostItem) {
                  final Widget tile = PostTile(
                    key: ValueKey('post_${item.status.id}'),
                    status: item.status,
                    accountId: item.accountId,
                    onBeforeSizeChange: () =>
                        _setAnchorToPost(item.status.id),
                  );
                  // 注: 以前は Web で各タイルを個別 SelectionArea で包んで本文を
                  // ドラッグ選択できるようにしていたが、ScrollablePositionedList と
                  // SelectionArea は非互換 (flutter/flutter#111572) で、SPL の独自
                  // viewport を通したスクロール中に選択機構が干渉し『タイムラインを
                  // 遡れない (ホイール/トラックパッドでもスクロールが止まる)』不具合を
                  // 起こしていた。コア機能のスクロールを優先し、タイル内選択は外す。
                  // タイムライン全体は下の SelectionContainer.disabled でルートの
                  // SelectionArea (main.dart) からも切り離し、SPL に選択機構が一切
                  // 干渉しないようにしている。
                  content = RepaintBoundary(child: tile);
                } else if (item is GapItem) {
                  content = RepaintBoundary(
                    child: GapTile(
                      key: ValueKey('gap_${item.gap.id}'),
                      gap: item.gap,
                      onTapKeepTop: () =>
                          _fillGap(item.gap, keepBottom: false),
                      onTapKeepBottom: () =>
                          _fillGap(item.gap, keepBottom: true),
                    ),
                  );
                }
                if (content == null) return const SizedBox.shrink();
                return wrapForTimelineLayout(ctx, content, timelineLayout);
              },
              separatorBuilder: (_, _) => timelineSeparator(timelineLayout),
              itemScrollController: _itemScrollController,
              itemPositionsListener: _itemPositionsListener,
            ),
          ),
          // ストリーミング切断バナー。`_anyStreamDisconnected` を個別購読
          // するので、接続状態の up/down でタイムライン本体は rebuild されない。
          ValueListenableBuilder<bool>(
            valueListenable: _anyStreamDisconnected,
            builder: (ctx, show, _) {
              if (!show) return const SizedBox.shrink();
              return const Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: Center(
                  child: _StreamReconnectBanner(),
                ),
              );
            },
          ),
          // 新着未読カウンター。引っ張って更新やストリーム受信で取得した投稿の
          // うち、まだ画面に出てきていないものの件数を上端に表示する。タップで
          // 一気に最上部までスクロールしてカウンターを 0 にする。
          //
          // `ValueListenableBuilder` で個別購読することで、件数の増減時に
          // タイムライン本体 (ScrollablePositionedList) は rebuild されない。
          ValueListenableBuilder<int>(
            valueListenable: _unreadCount,
            builder: (ctx, count, _) {
              if (count == 0) return const SizedBox.shrink();
              return Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: Center(
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () {
                        scrollToTop();
                        _unreadIds.clear();
                        _syncUnreadCount();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: Theme.of(ctx).colorScheme.primary,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black26,
                              blurRadius: 6,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.arrow_upward,
                                size: 16, color: Colors.white),
                            const SizedBox(width: 4),
                            Text(
                              '未読 $count 件',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );

    // Web: タイムライン全体を SelectionContainer.disabled で包み、アプリ全体の
    // SelectionArea (root, MaterialApp.home) の選択対象から外す。
    // ScrollablePositionedList と SelectionArea は非互換 (flutter/flutter#111572)
    // で、SPL を root の SelectableRegion 配下に置いたままにすると選択ジオメトリ
    // 計算が SPL の独自 viewport を通して走り、スクロール (ホイール/トラックパッド
    // 含む) が止まって『タイムラインを遡れない』不具合になる。disabled で切り離す
    // ことで SPL に選択機構が一切干渉しないようにする (TL 内テキスト選択は不可。
    // プロフィール等 ListView ベースの他ページは root SelectionArea のまま選択可)。
    return kIsWeb
        ? SelectionContainer.disabled(child: timelineList)
        : timelineList;
  }

  /// ギャップを埋める。
  ///
  /// **改善点**:
  /// - **ページング対応**: 1 回の API 取得で `limit` 件埋まらない場合は
  ///   `max_id` を進めて最大 N ページ取りに行く (上限あり、安全装置)。
  /// - **マルチソース対応**: 統合タイムラインで他アカウントのソースが
  ///   ある場合、ギャップの時間幅に重なる範囲を各ソースから取得して
  ///   一緒に挿入する。各ソースの ID 境界はそのソースが現在 `_items` に
  ///   残している投稿日付から推定する。
  /// - **位置ピン留め**: `keepBottom: true` ならギャップ下の最も近い
  ///   可視投稿を記録し、setState 後に同じ alignment で `jumpTo` する
  ///   (アニメーションなし)。引っ張って更新と同等の挙動。
  /// - **既存ギャップの保全**: 旧実装は `_convertToTimelineItems` の
  ///   再ビルドで `_items` 内の他のギャップを失っていた。今回は
  ///   ターゲットギャップ以外の `GapItem` を一旦退避し、最後に元の
  ///   newerStatusId 直下に挿し直す。
  Future<void> _fillGap(TimelineGap gap, {bool keepBottom = false}) async {
    final gapIndex =
        _items.indexWhere((item) => item is GapItem && item.gap.id == gap.id);
    if (gapIndex == -1) return;

    // ----- スクロール位置ピン留め用のアンカーを記録 -----
    // keepBottom: ギャップ下にある可視アイテムを優先 (= 下を維持)。
    // それ以外: 画面上端に最も近い可視アイテム (= 上を維持)。
    ({String id, double alignment})? anchor;
    if (keepBottom) {
      anchor = _captureAnchorAtOrAfter(gapIndex + 1);
    }
    anchor ??= _captureScrollAnchor();

    // ローディング状態に切替
    setState(() {
      final gapItem = _items[gapIndex] as GapItem;
      _items[gapIndex] = GapItem(gap: gapItem.gap.copyWith(isLoading: true));
    });

    try {
      final auth = ref.read(authProvider);
      if (auth.accounts.isEmpty) return;

      final sources =
          (widget.column['sources'] as List).cast<Map<String, dynamic>>();

      debugPrint(
          'Filling gap: anchor=${gap.anchorNewerStatusId} '
          'newerDate=${gap.newerDate} olderDate=${gap.olderDate} '
          'perSource=${gap.perSource.length} columnSources=${sources.length} '
          'keepBottom=$keepBottom');

      // ----- フェッチ対象ソース一覧を構築 -----
      //
      // 「ギャップが明示的に持っているソース」(`gap.perSource`) はそのまま使う。
      // 「ギャップが明示的に持っていないが同カラムに居るソース」は、時間幅と
      // 重なる既存投稿の id を境界に派生させて map に追加する (現状のロジックと
      // 同等)。片側だけでも見つかれば境界として使う。
      final fetchTargets = <String, SourceGapBounds>{
        for (final e in gap.perSource.entries) e.key: e.value,
      };
      for (final source in sources) {
        final accId = source['accountId'] as String?;
        if (accId == null) continue;
        if (fetchTargets.containsKey(accId)) continue;
        if (gap.newerDate == null && gap.olderDate == null) continue;

        Status? aboveExisting; // 時間幅より新しい側で「最も古い」既存投稿
        Status? belowExisting; // 時間幅より古い側で「最も新しい」既存投稿
        for (final item in _items) {
          if (item is! PostItem) continue;
          if (item.accountId != accId) continue;
          final d = item.status.createdAt;
          if (gap.newerDate != null && !d.isBefore(gap.newerDate!)) {
            if (aboveExisting == null ||
                d.isBefore(aboveExisting.createdAt)) {
              aboveExisting = item.status;
            }
          }
          if (gap.olderDate != null && !d.isAfter(gap.olderDate!)) {
            if (belowExisting == null ||
                d.isAfter(belowExisting.createdAt)) {
              belowExisting = item.status;
            }
          }
        }
        if (aboveExisting == null && belowExisting == null) continue;
        final tlType = (source['timelineType'] as String?) ?? 'home';
        fetchTargets[accId] = SourceGapBounds(
          newerStatusId: aboveExisting?.id,
          olderStatusId: belowExisting?.id,
          timelineType: tlType,
        );
      }

      // ----- 各ソースから投稿を取得 (ページング込み) -----
      //
      // 各ソースの「ページング後の状態」を記録する。`exhausted = true` (範囲を
      // 取り切った) のソースは残ギャップに含めない。`exhausted = false` の
      // ソースは「次ページの開始地点」(= 今回フェッチした最古の id) を新しい
      // `newerStatusId` として残ギャップに引き継ぐ。
      final List<PostWithAccount> fetched = [];
      final perSourceState = <String, _SourcePagingState>{};

      for (final entry in fetchTargets.entries) {
        final accId = entry.key;
        final bounds = entry.value;

        final account = auth.accounts.firstWhere(
          (a) => a.id == accId,
          orElse: () => auth.accounts.first,
        );

        // timelineType + listId 分解 (list_xxx → tlType=lists + listId=xxx)
        var tlType = bounds.timelineType;
        String? listId;
        if (tlType.startsWith('list_')) {
          listId = tlType.substring(5);
          tlType = 'lists';
        }

        // ページング: 最大 5 ページ (= 最大 200 件) まで取りに行く
        const limit = 40;
        const maxPages = 5;
        String? currentMaxId = bounds.newerStatusId;
        bool sourceExhausted = false;
        String? oldestFetchedId;
        DateTime? oldestFetchedDate;
        for (int page = 0; page < maxPages; page++) {
          try {
            final batch = await fetchTimelineForAccount(
              instanceUrl: account.instanceUrl,
              accessToken: account.accessToken,
              accountId: account.id,
              timelineType: tlType,
              listId: listId,
              sinceId: bounds.olderStatusId,
              maxId: currentMaxId,
              limit: limit,
            );
            if (batch.isEmpty) {
              sourceExhausted = true;
              break;
            }
            for (final s in batch) {
              fetched.add(PostWithAccount(status: s, accountId: accId));
              if (oldestFetchedDate == null ||
                  s.createdAt.isBefore(oldestFetchedDate)) {
                oldestFetchedId = s.id;
                oldestFetchedDate = s.createdAt;
              }
            }
            // limit 未満なら全部取り切った (それ以上は無い)
            if (batch.length < limit) {
              sourceExhausted = true;
              break;
            }
            // 次ページ: maxId を「今回バッチの最古」に進める
            // (Mastodon は newest-first で返すので末尾が最古)
            currentMaxId = batch.last.id;
          } catch (e) {
            debugPrint(
                'Gap fill paging error for source $accId page $page: $e');
            break;
          }
        }
        perSourceState[accId] = _SourcePagingState(
          bounds: bounds,
          exhausted: sourceExhausted,
          oldestFetchedId: oldestFetchedId,
          oldestFetchedDate: oldestFetchedDate,
        );
      }

      debugPrint('Gap fill: fetched ${fetched.length} posts total, '
          'perSourceState=${perSourceState.map((k, v) => MapEntry(k, "${v.exhausted ? "done" : "more"}@${v.oldestFetchedId}"))}');

      // 全ソースが 1 ページも取得できずに終わった (通信エラー等)。
      // ページングループ内の catch は握りつぶして break するだけなので、
      // ここで判定しないと「ネットワーク断でギャップをタップ → 0 件扱いで
      // ギャップ削除」になってしまう。外側の catch パスと同様に isLoading
      // だけ解除してギャップを温存する (再タップでリトライ可能)。
      // exhausted = true は「空応答で取り切った」なので成功扱い。
      final anySourceSucceeded = perSourceState.values
          .any((s) => s.exhausted || s.oldestFetchedId != null);
      if (perSourceState.isNotEmpty && !anySourceSucceeded) {
        setState(() {
          final idx = _items.indexWhere(
            (item) => item is GapItem && item.gap.id == gap.id,
          );
          if (idx >= 0) {
            final gapItem = _items[idx] as GapItem;
            _items[idx] =
                GapItem(gap: gapItem.gap.copyWith(isLoading: false));
          }
        });
        return;
      }

      // ----- 既存リストとマージ + ギャップ位置補正 -----
      // 既存の他のギャップは保全し、ターゲットギャップだけ消す
      final preservedGaps = <GapItem>[];
      final existingPosts = <PostWithAccount>[];
      final existingIds = <String>{};
      for (final item in _items) {
        if (item is GapItem && item.gap.id != gap.id) {
          preservedGaps.add(item);
        } else if (item is PostItem) {
          existingPosts.add(
              PostWithAccount(status: item.status, accountId: item.accountId));
          existingIds.add(item.status.id);
        }
      }
      // 未フラッシュの SSE バッファも含めて dedup。fillGap の取得範囲と
      // たまたま重なる新着が `_pendingStreamUpdates` に積まれている時、
      // 両方を `_items` に挿入してしまわないように。
      existingIds.addAll(_pendingStreamUpdates.map((u) => u.id));

      // 重複除外
      final newPosts =
          fetched.where((p) => !existingIds.contains(p.status.id)).toList();

      // 残ギャップ (ページング上限で取り切れず、続きが残っているソースが
      // ある場合) を構築する。
      //
      // perSource 設計の肝: **「取り切れていない」ソースだけ** を残ギャップの
      // perSource に含める。取り切ったソースは含めない (= 次回タップ時に
      // 再フェッチしない)。これでソース間の取得数の非対称 (A は 200 件残り、
      // B は 5 件で完了 等) を素直に表現できる。
      //
      // 各ソースの新しい `newerStatusId` はそのソースが今回取得した最古の
      // id (= 次ページの開始点)。`olderStatusId` は元の境界を継承する。
      // 「元の olderStatusId にまだ到達していない」サニティチェックは
      // ID 比較が文字列順では不正確なので時刻ベースの代替判定はせず、
      // 「exhausted じゃない && oldestFetchedId が取れた」だけで残す。
      final residualPerSource = <String, SourceGapBounds>{};
      String? residualAnchorCandidate; // 残ギャップ挿入位置の候補 (取れた最古)
      DateTime? residualAnchorDate;
      DateTime? residualNewerDate;
      for (final entry in perSourceState.entries) {
        final state = entry.value;
        if (state.exhausted) continue;
        if (state.oldestFetchedId == null) continue;
        residualPerSource[entry.key] = state.bounds.copyWith(
          newerStatusId: state.oldestFetchedId,
        );
        // 残ギャップの newerDate は「残ソース達の最古 fetch」の最新側 (= ギャップ
        // のすぐ上の post 群のうち最も古いもの)。挿入アンカーはその id。
        final d = state.oldestFetchedDate;
        if (d != null) {
          if (residualAnchorDate == null || d.isAfter(residualAnchorDate)) {
            residualAnchorDate = d;
            residualAnchorCandidate = state.oldestFetchedId;
            residualNewerDate = d;
          }
        }
      }
      GapItem? residualGap;
      if (residualPerSource.isNotEmpty && residualAnchorCandidate != null) {
        residualGap = GapItem(
          gap: TimelineGap(
            id: 'gap_${residualAnchorCandidate}_${gap.olderDate?.microsecondsSinceEpoch ?? "open"}',
            anchorNewerStatusId: residualAnchorCandidate,
            perSource: residualPerSource,
            newerDate: residualNewerDate,
            olderDate: gap.olderDate,
          ),
        );
      }

      if (newPosts.isEmpty) {
        // 何も新たに取れなかった: ターゲットギャップだけ削る (空応答の
        // 0 件パス。残ギャップの挿し場所も無いので諦める)。
        // 冒頭で取った gapIndex は await を跨いでおり、その間の SSE
        // フラッシュ prepend 等で index がずれている可能性があるため、
        // id で取り直してから消す (stale index で無関係な item を消さない)。
        setState(() {
          final idx = _items.indexWhere(
            (item) => item is GapItem && item.gap.id == gap.id,
          );
          if (idx >= 0) _items.removeAt(idx);
        });
        _restoreScrollAnchor(anchor);
        _saveToCache();
        return;
      }

      // マージ + ソート (ブックマーク/お気に入りを除く)
      final allPosts = <PostWithAccount>[...existingPosts, ...newPosts];
      if (!_shouldDisableTimeSorting()) {
        allPosts
            .sort((a, b) => b.status.createdAt.compareTo(a.status.createdAt));
      }

      // 投稿のみで再構築
      final rebuilt = _convertToTimelineItems(allPosts);

      // 残ギャップを `anchorNewerStatusId` の直下に挿入する。
      // (= 残ソース群が今回取った最古投稿のすぐ下、ユーザーが keepBottom で
      //  アンカーしたポストのすぐ上、に位置することになる)
      if (residualGap != null) {
        final anchorId = residualGap.gap.anchorNewerStatusId;
        final idx = rebuilt.indexWhere(
          (it) => it is PostItem && it.status.id == anchorId,
        );
        if (idx >= 0) {
          rebuilt.insert(idx + 1, residualGap);
        }
      }

      // 保全したギャップを元の位置に挿し直す。各ギャップは anchorNewerStatusId の
      // すぐ下にあったので、その投稿がまだリストにあれば直後に挿入する。
      for (final gapItem in preservedGaps) {
        final newerId = gapItem.gap.anchorNewerStatusId;
        final idx = rebuilt.indexWhere(
          (it) => it is PostItem && it.status.id == newerId,
        );
        if (idx >= 0) {
          rebuilt.insert(idx + 1, gapItem);
        }
        // 見つからない = 境界投稿が消えている (極端なケース)。サイレントに drop。
      }

      setState(() => _items = rebuilt);
      _invalidateKnownIds();
      // keepBottom のとき、フェッチした投稿はアンカー (ギャップ下の可視投稿)
      // より上に積まれるためユーザーの視界外。未読バッジに加算してユーザーが
      // 上方向にスクロールアップして読むまで件数で示す (ソートでアンカーより
      // 下に入った分は上スクロールで通過しないため対象外)。
      // keepBottom: false (上側をキープ) はアンカー下に展開＝視界内〜下スクロール
      // で素直に読まれるため未読カウントしない。
      if (keepBottom) {
        _unreadIds.addAll(unreadIdsAboveAnchor(
          items: _items,
          anchorKey: anchor?.id,
          candidateIds: newPosts.map((p) => p.status.id).toSet(),
        ));
      }
      _restoreScrollAnchor(anchor); // 同期 jumpTo で位置ピン留め
      _pruneOrphanUnreadIds();
      _syncUnreadCount();
      _saveToCache();

      // ユーザーへのフィードバック: 部分的にしか埋められなかった場合は
      // 続きを取れることを伝える。
      if (residualGap != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                '${newPosts.length} 件読み込みました。続きはギャップから再取得できます'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error filling gap: $e');
      // ローディング状態を解除
      setState(() {
        final idx = _items.indexWhere(
          (item) => item is GapItem && item.gap.id == gap.id,
        );
        if (idx >= 0) {
          final gapItem = _items[idx] as GapItem;
          _items[idx] = GapItem(gap: gapItem.gap.copyWith(isLoading: false));
        }
      });
    }
  }

  /// 特定のカラムのキャッシュをクリア
  static void clearCacheForColumn(String columnKey) {
    _cachedItems.remove(columnKey);
    _cachedSinceIds.remove(columnKey);
    _cachedMaxIds.remove(columnKey);
  }

  /// すべてのキャッシュをクリア
  static void clearAllCache() {
    _cachedItems.clear();
    _cachedSinceIds.clear();
    _cachedMaxIds.clear();
  }
}

// ===========================================================================
// SSE 接続の状態を保持するハンドル。再接続のために接続パラメタを保持する。
// ===========================================================================

/// 各ソースのロード結果。失敗判定を呼び出し側で集計するため。
class _SourceLoadResult {
  final List<PostWithAccount> posts;
  final bool failed;
  const _SourceLoadResult({required this.posts, required this.failed});
}

/// `_fillGap` でソースごとのページング結果を集約するための内部 record。
/// fillGap 完了後、`exhausted == false` のソースだけを残ギャップに引き継ぐ。
class _SourcePagingState {
  final SourceGapBounds bounds;
  final bool exhausted;
  final String? oldestFetchedId;
  final DateTime? oldestFetchedDate;

  const _SourcePagingState({
    required this.bounds,
    required this.exhausted,
    required this.oldestFetchedId,
    required this.oldestFetchedDate,
  });
}

class _StreamConnection {
  final String accountId;
  final String instanceUrl;
  final String accessToken;
  final String timelineType;
  final String? listId;

  /// アクティブな購読 (再接続中は null)。生 JSON 文字列を流すストリーム。
  StreamSubscription<String>? subscription;

  /// 再接続予約タイマー (バックオフ中のみ非 null)
  Timer? reconnectTimer;

  /// 連続失敗回数。受信成功で 0 にリセット。
  int attempt = 0;

  /// 現在 SSE 購読が確立しているか。`subscribe` 成功で true、
  /// 失敗 / done / バックオフ中 false。UI バナー判定に使う。
  bool isConnected = false;

  /// 過去に一度でも `subscribe` が成功したか。初回接続と再接続を区別して、
  /// 再接続時にだけギャップ検出付き再取得を走らせるための判定に使う。
  bool everConnected = false;

  /// 直近に何らかのイベント (status 受信・`:thump` ハートビート・接続確立)
  /// を検知した時刻。SSE は TCP/プロキシの都合で onError / onDone が発火
  /// しないまま無音になる「サイレント切断」が起きうる。watchdog
  /// (`_livenessCheckTimer`) がこの時刻と現在時刻の差を見て一定以上
  /// 経っていたら強制再接続する。
  DateTime? lastEventAt;

  /// この接続で `:thump` ハートビートを一度でも観測したか。観測済みなら
  /// watchdog は短い閾値 (`_livenessTimeoutWithHeartbeatSeconds`) で無音を
  /// 死亡と判定できる (ハートビートが来なくなった = 本当に死んでいる)。
  /// io 実装のみ true になり得る (Web の EventSource はコメント行を露出
  /// しない)。再接続を跨いでも保持する (同一サーバなら対応は変わらない)。
  bool sawHeartbeat = false;

  /// この conn に対する `_connectStream` の in-flight Future。
  /// 同じ conn に対して `_forceReconnectAllStreams` / watchdog /
  /// `_scheduleReconnect` が並行して `_connectStream` を呼びうるため、
  /// `_refresh()` と同様に Future を共有して二重実行を防ぐ。これがないと
  /// 後発の呼び出しが `subscribeTimelineUpdates` の await から先に戻った
  /// 場合に `conn.subscription` が先発側に上書きされ、後発の購読がリーク
  /// する (UI dedup でフィルタはされるが、SSE 接続が無駄に 2 本になる)。
  Future<void>? connectInFlight;

  _StreamConnection({
    required this.accountId,
    required this.instanceUrl,
    required this.accessToken,
    required this.timelineType,
    required this.listId,
  });

  String get key => '$accountId:$timelineType:${listId ?? ""}';
}

/// ストリーミング再接続中バナー。`const` で構築できる定数 widget なので、
/// `ValueListenableBuilder` の builder から繰り返し返しても新規アロケート
/// が発生しない。
class _StreamReconnectBanner extends StatelessWidget {
  const _StreamReconnectBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.orange.shade700,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          ),
          SizedBox(width: 8),
          Text(
            'ストリーミング再接続中…',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
