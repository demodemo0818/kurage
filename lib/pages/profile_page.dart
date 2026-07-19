// lib/pages/profile_page.dart

import 'dart:ui' as ui;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'dart:async';

import '../l10n/l10n.dart';
import '../models/auth_account.dart';
import '../models/account.dart';
import '../models/emoji.dart';
import '../models/profile_field.dart';
import '../models/status.dart';
import '../models/relationship.dart';
import '../providers/settings_provider.dart';
import '../services/mastodon_api.dart';
import '../services/local_status_event_bus.dart';
import '../utils/html_parser.dart';
import '../utils/instance_utils.dart';
import '../utils/snackbar_helpers.dart';
import '../widgets/post_tile.dart';
import '../widgets/mute_dialog.dart';
import '../widgets/add_to_list_sheet.dart';
import '../widgets/network_image_x.dart';
import '../widgets/timeline_post_decoration.dart';
import '../widgets/user_avatar.dart';
import '../providers/auth_provider.dart';
import '../models/collection.dart';
import '../utils/open_profile.dart';
import 'profile_edit_page.dart';
import 'collection_detail_page.dart';
import 'collection_form_page.dart';

/// ProfilePage の build / helper 群が必要とする Settings フィールドのスライス。
/// `ref.watch(settingsProvider.select(...))` の戻り型と _buildHeader 等の
/// 引数型をこの一箇所に集約することで、Settings 全 39 フィールドを watch して
/// 全画面 rebuild するのを避ける。
typedef _ProfileSettingsSlice = ({
  double fontSize,
  double lineHeight,
  double emojiScale,
  double emojiScaleInDisplayName,
  bool disableCustomEmojiAnimationInContent,
  bool disableCustomEmojiAnimationInDisplayName,
  TimelineLayout timelineLayout,
});

class ProfilePage extends ConsumerStatefulWidget {
  final AuthAccount user;
  final String? targetAccountId; // 表示対象のアカウントID
  final String? targetUsername;  // 表示対象のユーザー名
  final String? targetInstanceUrl; // 表示対象のインスタンスURL

  /// Deck (ワイド) のマイプロフィールポップアップで開かれた時に渡される戻る (←)
  /// コールバック。null (通常 push 時) のときは AppBar の戻る矢印は既定の挙動
  /// (push されているなら自動で戻る矢印) に任せる。
  final VoidCallback? onDeckBack;

  const ProfilePage({
    super.key,
    required this.user,
    this.targetAccountId,
    this.targetUsername,
    this.targetInstanceUrl,
    this.onDeckBack,
  });

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage>
    // 4.6 未満のサーバ判定でコレクションタブの有無 (5↔4) が変わると
    // TabController を作り直すため、複数 Ticker を許す TickerProviderStateMixin
    // を使う (SingleTicker は 2 個目の Ticker 生成で例外を投げる)。古い
    // TabController は _ensureTabController で dispose してからの差し替え。
    with TickerProviderStateMixin {
  Account? _account;
  Relationship? _rel;
  List<Status> _pinned = [];
  List<Status> _statuses = [];
  List<Status> _mediaStatuses = [];
  List<Account> _following = [];
  List<Account> _followers = [];
  /// 共通のフォロワー (= 自分のフォロー中で、このアカウントもフォローしている人)。
  /// 自分のプロフィールを開いている時は概念的に空、リクエストもしない。
  List<Account> _familiarFollowers = [];
  /// プロフィール読み込みの状態。`bool _loading` + `Object? _error` の
  /// 2 変数表現は (loading=true & errored の同時セット) のような矛盾組み合わせ
  /// が起きうるので enum で正規化。`_loadingMore` (= タブ内の追加ロード中) は
  /// loaded 状態に重なる overlay なので別の bool のまま。
  _ProfileLoadStatus _status = _ProfileLoadStatus.loading;
  /// 直近の `_reloadAll` で握った例外。`_status == errored` のときだけ意味を
  /// 持つ。エラー画面で種別判定 (404 / 403 / ネットワーク等) と詳細表示に使う。
  Object? _errorObj;
  bool _loadingMore = false;
  String? _maxId;
  String? _mediaMaxId;

  /// 投稿タブで DM (visibility=direct) を一覧から除外するか (4.6+)。
  /// 自分のプロフィールの投稿タブにトグルを出して、その場で切り替える。
  /// 既定は除外 (= 投稿一覧をすっきり見せ、必要なときだけ DM を出す)。
  bool _excludeDirect = true;

  /// 自インスタンスが Mastodon 4.6 世代のプロフィール機能 (コレクション /
  /// 投稿タブの DM 除外フィルタ) に対応しているか。`fetchInstanceConfig` の
  /// `configuration.accounts` の有無で判定する。取得前 / 判定失敗時は楽観的に
  /// true (従来挙動)。4.6 未満ではコレクションタブ・作成導線・DM トグルを隠す。
  bool _supportsV46Features = true;

  /// 自分自身のプロフィールを開いているか (DM 表示トグルを出す条件)。
  bool get _isOwnProfile =>
      widget.targetAccountId == null || _account?.id == widget.user.id;

  // ── 相手サーバー公開ビュー (「相手サーバーから最新を読み込む」) ──
  // リモートアカウントを自インスタンス経由で見ると連合スナップショットの
  // 古い/部分的なカウント・投稿しか得られないため、相手インスタンスの公開
  // API を認証なしで直接叩いて正確な値に切り替える。匿名アクセス扱いになる
  // ので公開/未収載投稿のみ (フォロワー限定は含まれない) で、バナーで明示する。
  //
  // 重要: 表示だけをリモートに差し替え、フォロー/ミュート等の操作は従来通り
  // home インスタンス経由 (`_account` とその id) で行う。`_remoteAccount.id`
  // はリモートサーバー上の ID なので操作に使うと home で不整合になる。
  bool _remoteView = false;
  Account? _remoteAccount;
  List<Status> _remoteStatuses = [];
  List<Status> _remoteMediaStatuses = [];
  List<Status> _remotePinned = [];
  String? _remoteHost; // 'https://host' (_loadMore のリモート分岐で使用)
  String? _remoteMaxId;
  String? _remoteMediaMaxId;

  /// 表示に使うアカウント。リモートビュー中は相手サーバーの lookup 結果
  /// (正確なカウント/bio/fields/url)、それ以外は home 解決済みの `_account`。
  Account get _displayAccount =>
      (_remoteView && _remoteAccount != null) ? _remoteAccount! : _account!;
  List<Status> get _displayStatuses =>
      _remoteView ? _remoteStatuses : _statuses;
  List<Status> get _displayMediaStatuses =>
      _remoteView ? _remoteMediaStatuses : _mediaStatuses;
  List<Status> get _displayPinned => _remoteView ? _remotePinned : _pinned;

  /// PostTile に渡す status 取得元サーバー。リモートビュー中は相手サーバー
  /// (= status.id がそのサーバー上の ID であることを PostTile に伝え、
  /// リアクション前のホーム ID 解決を有効にする)。通常時は null。
  String? get _statusSource => _remoteView ? _remoteHost : null;

  /// フォロー / フォロワータブで「まだ続きがある」かのフラグ。
  /// 初回ロード時に「ページサイズ (80) ぴったり返ってきた = まだあるかも」で
  /// true、未満なら false (= 終端) にする。`_loadMore*` の中でも更新する。
  /// `_following` / `_followers` が空 (まだ初期ロード前 or 本当に 0 件) の
  /// ときは false 起点にして無駄な fetch をしない。
  bool _hasMoreFollowing = false;
  bool _hasMoreFollowers = false;
  /// API のページサイズ (`fetchAccountFollowing/Followers` の limit と揃える)。
  static const int _accountListPageSize = 80;
  late TabController _tabController;

  /// `NestedScrollView` の **外側** (sliver header 側) のスクロール位置を
  /// 観測するための controller。各タブ内 `RefreshIndicator` の
  /// `notificationPredicate` でこれを参照し、「外側が完全に top に戻った
  /// 時 (= ヘッダがフル展開) だけ pull-to-refresh を有効化」する。
  ///
  /// 旧実装のように単純に各タブ内 `RefreshIndicator` だけを置くと、
  /// 内側 ListView は大半の時間オフセット 0 なので、ヘッダ sliver を少し
  /// 動かしただけのジェスチャでも refresh に倒れる。逆に
  /// `RefreshIndicator` を NestedScrollView の外側に置くと、内側のオーバ
  /// スクロール通知が外側ラッパーに伝わらず refresh が一切走らない。
  /// その間を取って「内側に置く + 外側 0 のとき限定」が一番期待挙動に
  /// 近い。
  final ScrollController _outerScrollController = ScrollController();

  /// `parseContentWithEmojis` のメモ化キャッシュ。`_buildHeader` 内で displayName /
  /// note / 各 fields[].name / 各 fields[].value で計 2+2N 回呼ばれており、
  /// プロフィールが大きい人 (fields 4 件等) では 1 build あたり 10 回ほどの
  /// 正規表現走査 + InlineSpan / TapGestureRecognizer 生成が走る。
  ///
  /// 設定変更 / メモ編集 / フォロー切替などで build が走るたびに全部やり直す
  /// のは無駄なので、入力 (html, style, emoji size, アニメ設定) が同じなら
  /// 前回の InlineSpan を再利用する。signature が変わったエントリは置換時に
  /// dispose される (recognizer リーク防止)。
  final Map<String, _ParsedSpansEntry> _parseCache = {};

  /// `local_status_event_bus` の購読。自分の投稿の編集 / 削除を即時に
  /// プロフィール上の投稿リスト (`_statuses` / `_pinned` / `_mediaStatuses`)
  /// にも反映する。
  StreamSubscription<LocalStatusEvent>? _localStatusEventSub;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _localStatusEventSub = localStatusEventStream.listen(_onLocalStatusEvent);
    _reloadAll();
  }

  /// タブ数を [length] に合わせる。Mastodon 4.6 未満のサーバではコレクション
  /// タブを出さないため (length=4)、判定確定後に length が変わったときだけ
  /// TabController を作り直す。`SingleTickerProviderStateMixin` だが古い
  /// controller を dispose してから新しいものを作るので Ticker は 1 つに収まる。
  /// 本体 (TabBar/TabBarView) は loaded 遷移後に初めて build されるので、初回
  /// loading→loaded で 1 度作り直しても表示中の controller は差し替わらない。
  void _ensureTabController(int length) {
    if (_tabController.length == length) return;
    final old = _tabController;
    _tabController = TabController(length: length, vsync: this);
    old.dispose();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _outerScrollController.dispose();
    _localStatusEventSub?.cancel();
    _localStatusEventSub = null;
    for (final entry in _parseCache.values) {
      entry.dispose();
    }
    _parseCache.clear();
    super.dispose();
  }

  /// 自分の操作 (編集 / 削除) によるローカルイベントをプロフィール内の
  /// 投稿リストに反映する。プロフィールページは「操作元アカウント =
  /// `widget.user.id`」のときだけ意味があるので、別アカウントの操作は無視。
  /// (= 別アカウントが自分の投稿を編集/削除しても、ここで表示しているのは
  /// `widget.user` の view なので無関係)
  void _onLocalStatusEvent(LocalStatusEvent event) {
    if (!mounted) return;
    if (event.accountId != widget.user.id) return;

    switch (event) {
      case LocalStatusDeleted():
        final before = _statuses.length + _pinned.length + _mediaStatuses.length;
        _statuses.removeWhere((s) => s.id == event.statusId);
        _pinned.removeWhere((s) => s.id == event.statusId);
        _mediaStatuses.removeWhere((s) => s.id == event.statusId);
        final after = _statuses.length + _pinned.length + _mediaStatuses.length;
        if (after != before) setState(() {});

      case LocalStatusEdited():
        var changed = false;
        for (var i = 0; i < _statuses.length; i++) {
          if (_statuses[i].id == event.updated.id) {
            _statuses[i] = event.updated;
            changed = true;
          }
        }
        for (var i = 0; i < _pinned.length; i++) {
          if (_pinned[i].id == event.updated.id) {
            _pinned[i] = event.updated;
            changed = true;
          }
        }
        for (var i = 0; i < _mediaStatuses.length; i++) {
          if (_mediaStatuses[i].id == event.updated.id) {
            _mediaStatuses[i] = event.updated;
            changed = true;
          }
        }
        if (changed) setState(() {});
    }
  }

  /// `parseContentWithEmojis` をメモ化付きで呼び出す。
  /// 同じ key & 同じ signature (= 入力 HTML / スタイル / emoji size 等) なら
  /// 前回の `List<InlineSpan>` をそのまま返す。signature が変わったときは
  /// 旧 spans の TapGestureRecognizer を dispose してから再パースする。
  ///
  /// `key` は呼び出し箇所ごとに固定文字列を渡す ("displayName" / "note" /
  /// "fieldName:0" / "fieldValue:1" 等)。同一 key で signature だけ変わると
  /// LRU 的に古いものが捨てられる。
  List<InlineSpan> _cachedParseSpans({
    required String key,
    required String html,
    required List<Emoji> emojis,
    required TextStyle baseStyle,
    required Color linkColor,
    required double emojiSize,
    required bool disableEmojiAnimation,
    bool enableInlineLinks = true,
  }) {
    final sig = '${html.hashCode}|'
        '${baseStyle.fontSize}|${baseStyle.height}|${baseStyle.fontFamily}|'
        '${baseStyle.color?.toARGB32() ?? 0}|'
        '${baseStyle.fontWeight?.value ?? 0}|'
        '${linkColor.toARGB32()}|$emojiSize|$disableEmojiAnimation|'
        '$enableInlineLinks';
    final cached = _parseCache[key];
    if (cached != null && cached.signature == sig) {
      return cached.spans;
    }
    cached?.dispose();
    final spans = parseContentWithEmojis(
      contentHtml: html,
      emojis: emojis,
      baseStyle: baseStyle,
      linkColor: linkColor,
      emojiSize: emojiSize,
      context: context,
      disableEmojiAnimation: disableEmojiAnimation,
      enableInlineLinks: enableInlineLinks,
    );
    _parseCache[key] = _ParsedSpansEntry(sig, spans);
    return spans;
  }

  /// 外側 (sliver header 側) が top に戻っているか (= ヘッダがフル展開)。
  /// 各タブ内 `RefreshIndicator.notificationPredicate` から呼んで
  /// pull-to-refresh の発火条件を絞る。
  bool _isOuterAtTop() {
    if (!_outerScrollController.hasClients) return true; // まだ attach 前
    return _outerScrollController.position.pixels <= 0;
  }

  /// `targetUsername` (+ `targetInstanceUrl`) を `acct` 形式に組み立てて
  /// `searchAccounts` で解決する。同一インスタンスならローカル名のまま、
  /// 別インスタンスなら `user@host` 形式にする。本文中のメンションタップ
  /// (`html_parser._navigateToProfile`) や、ID で fetch に失敗したときの
  /// fallback で使う。見つからなければ例外を投げる。
  Future<Account> _resolveByUsername(AuthAccount auth) async {
    final username = widget.targetUsername!;
    final instanceUrl = widget.targetInstanceUrl;
    final fullAcct = (instanceUrl == null || instanceUrl == auth.instanceUrl)
        ? username
        : '$username@${Uri.parse(instanceUrl).host}';

    debugPrint('Searching for user: $fullAcct');

    final searchResults = await searchAccounts(
      instanceUrl: auth.instanceUrl,
      accessToken: auth.accessToken,
      query: fullAcct,
      limit: 1,
    );

    if (searchResults.isEmpty) {
      throw Exception(l10n.profUserNotFound(fullAcct));
    }
    debugPrint('Found user via search: ${searchResults.first.acct}');
    return searchResults.first;
  }

  Future<void> _reloadAll() async {
    setState(() {
      _status = _ProfileLoadStatus.loading;
      _errorObj = null;
      // home からの再読み込みは常に相手サーバービューを抜ける。これにより
      // バナーの「自インスタンスに戻す」は `_reloadAll()` 呼び出しで実現でき、
      // relationship も含め home データが新鮮に再取得される。
      _remoteView = false;
      _remoteAccount = null;
      _remoteHost = null;
      _remoteStatuses = [];
      _remoteMediaStatuses = [];
      _remotePinned = [];
      _remoteMaxId = null;
      _remoteMediaMaxId = null;
    });
    try {
      final auth = widget.user;
      
      // 表示対象が自分か他のユーザーかで処理を分ける。
      // 優先順:
      //   1. targetAccountId が指定されていれば ID で fetch (失敗時は
      //      targetUsername があれば検索 fallback)。search_page など
      //      ID をすでに知っている呼び出し元向け。
      //   2. targetUsername が指定されていれば検索で解決。本文中の
      //      メンション (html_parser._navigateToProfile) からの遷移は
      //      ID を持たないのでこちら。
      //   3. どちらも無ければ自分のプロフィール。
      Account acct;
      if (widget.targetAccountId != null) {
        try {
          acct = await fetchAccount(
            instanceUrl: auth.instanceUrl,
            accessToken: auth.accessToken,
            accountId: widget.targetAccountId!,
          );
        } catch (e) {
          // IDで失敗した場合、ユーザー名で検索を試す
          if (widget.targetUsername == null) rethrow;
          acct = await _resolveByUsername(auth);
        }
      } else if (widget.targetUsername != null) {
        acct = await _resolveByUsername(auth);
      } else {
        // 自分のプロフィールの場合
        acct = await fetchAccount(
          instanceUrl: auth.instanceUrl,
          accessToken: auth.accessToken,
          accountId: auth.id,
        );
      }
      
      final targetId = acct.id;
      final isOwn = acct.id == widget.user.id;

      // ── 並列化 ──
      // acct が解決できれば残りの 7 本の API は互いに独立しているので、
      // 直列に await すると 7 RTT 分待つことになる。Future を 7 個一気に
      // 生成すると Dart は生成と同時に実行を開始するので、その後で順に
      // await すれば全体は最も遅い 1 本ぶん (≒1 RTT) で済む。
      // リモートインスタンス相手のプロフィール表示で体感差が一番大きい。
      final relFuture = fetchRelationship(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        accountId: targetId,
      );
      final pinnedFuture = fetchPinnedStatuses(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        accountId: targetId,
      );
      final fetchedFuture = fetchAccountStatuses(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        accountId: targetId,
        // 投稿タブの DM 除外はトグル連動 (既定は除外)。
        excludeDirect: _excludeDirect,
      );
      final mediaFetchedFuture = fetchAccountStatuses(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        accountId: targetId,
        onlyMedia: true,
      );
      final followingFuture = fetchAccountFollowing(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        accountId: targetId,
      );
      final followersFuture = fetchAccountFollowers(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        accountId: targetId,
      );
      // 共通のフォロワー: 自分のプロフィールでは概念的に空なので呼ばない。
      // Future.wait でなく個別 await のため、形を合わせる Future.value で
      // ラップ (await の並びを揃えてコードを単純化するため)。
      // 自分以外でも fetchFamiliarFollowers が 404 等を内部で握り潰すので
      // throw しない (=他の 6 本が orphan エラーになる心配はない)。
      final familiarFollowersFuture = isOwn
          ? Future<List<Account>>.value(const <Account>[])
          : fetchFamiliarFollowers(
              instanceUrl: auth.instanceUrl,
              accessToken: auth.accessToken,
              accountId: targetId,
            );
      // 自インスタンスが 4.6 世代のプロフィール機能 (コレクション / DM 除外
      // フィルタ) に対応しているか。コレクション / DM の API は表示対象が誰で
      // あれ自インスタンス経由なので、見るのは常に自インスタンス。失敗時は
      // 楽観的に true (従来挙動) に倒す。fetchInstanceConfig はプロセス内
      // キャッシュ付きなので 2 回目以降は RTT 0。
      final supportsV46Future = fetchInstanceConfig(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
      ).then<bool>((c) => c.supportsV46AccountFeatures).catchError((_) => true);

      // 全部キックした後に gather する。await の順番が結果の到着順と
      // 一致しなくても問題ない (どれかが先に完了したら次の await まで
      // 待機なしで済むだけ、最終的には全 Future が解決して setState に到達)。
      final rel = await relFuture;
      final pinned = await pinnedFuture;
      final fetched = await fetchedFuture;
      final mediaFetched = await mediaFetchedFuture;
      final following = await followingFuture;
      final followers = await followersFuture;
      final familiarFollowers = await familiarFollowersFuture;
      final supportsV46 = await supportsV46Future;

      setState(() {
        _account      = acct;
        _rel          = rel;
        _pinned       = pinned;
        _statuses     = fetched;
        _mediaStatuses = mediaFetched;
        _following    = following;
        _followers    = followers;
        _familiarFollowers = familiarFollowers;
        _supportsV46Features = supportsV46;
        // 4.6 未満ではコレクションタブを出さない (5→4 タブ)。判定確定後に
        // length が変わったときだけ TabController を作り直す。
        _ensureTabController(supportsV46 ? 5 : 4);
        _maxId        = fetched.isNotEmpty ? fetched.last.id : null;
        _mediaMaxId   = mediaFetched.isNotEmpty ? mediaFetched.last.id : null;
        // ページサイズちょうど返ってきていたら「まだあるかも」。
        // 未満ならその時点で終端確定。
        _hasMoreFollowing = following.length >= _accountListPageSize;
        _hasMoreFollowers = followers.length >= _accountListPageSize;
        // 全部入れてから loaded に遷移 (= UI が新データに切り替わる瞬間)
        _status = _ProfileLoadStatus.loaded;
      });
    } catch (e) {
      debugPrint('Profile load error: $e');
      if (!mounted) return;
      setState(() {
        _errorObj = e;
        _status = _ProfileLoadStatus.errored;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;

    // タブ index → 種別を _ProfileTab で一旦受けてから switch する。
    // 旧: switch (_tabController.index) ── タブ並び順を変えるとサイレント
    //     に壊れる (例: case 0 が posts のままなのに UI 順が media を先に
    //     する変更を加えたら、media タブで posts の loadMore が走る)。
    // 新: enum.values の並び順 = タブ並び順 = TabBarView.children の並び順
    //     という 1 つの不変条件に紐付くので、index と意味が分離する。
    final tab = _ProfileTab.values[_tabController.index];
    switch (tab) {
      case _ProfileTab.posts:
        await _loadMorePosts();
      case _ProfileTab.media:
        await _loadMoreMedia();
      case _ProfileTab.following:
        await _loadMoreFollowing();
      case _ProfileTab.followers:
        await _loadMoreFollowers();
      case _ProfileTab.collections:
        // コレクションタブは自前で読み込む _CollectionsTab が担うため no-op。
        break;
    }
  }
  
  /// DM 表示トグルの切り替え。投稿一覧だけ再取得する (他タブには触らない)。
  Future<void> _setExcludeDirect(bool exclude) async {
    if (_excludeDirect == exclude) return;
    setState(() {
      _excludeDirect = exclude;
      // 即座にクリアして「切り替わった」感を出す + 旧 DM の残留を防ぐ。
      _statuses = [];
      _maxId = null;
      _loadingMore = false;
    });
    await _reloadPosts();
  }

  /// 投稿タブだけを現在の [_excludeDirect] で取り直す。
  Future<void> _reloadPosts() async {
    final acct = _account;
    if (acct == null) return;
    final auth = widget.user;
    try {
      final fetched = await fetchAccountStatuses(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        accountId: acct.id,
        excludeDirect: _excludeDirect,
      );
      if (!mounted) return;
      setState(() {
        _statuses = fetched;
        _maxId = fetched.isNotEmpty ? fetched.last.id : null;
      });
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, l10n.profStatusRefetchFailed('$e'));
    }
  }

  Future<void> _loadMorePosts() async {
    // リモートビュー中は相手サーバー (認証なし) からページングする。
    if (_remoteView) {
      if (_remoteMaxId == null || _loadingMore || _remoteHost == null) return;
      setState(() => _loadingMore = true);
      try {
        final older = await fetchAccountStatuses(
          instanceUrl: _remoteHost!,
          accessToken: null,
          accountId: _displayAccount.id,
          maxId: _remoteMaxId,
          excludeDirect: _excludeDirect,
        );
        if (older.isNotEmpty) {
          setState(() {
            _remoteStatuses.addAll(older);
            _remoteMaxId = older.last.id;
          });
        }
      } catch (_) {
        // ignore
      } finally {
        setState(() => _loadingMore = false);
      }
      return;
    }
    if (_maxId == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final auth = widget.user;
      final targetId = widget.targetAccountId ?? widget.user.id;
      final older = await fetchAccountStatuses(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        accountId: targetId,
        maxId: _maxId,
        excludeDirect: _excludeDirect,
      );
      if (older.isNotEmpty) {
        setState(() {
          _statuses.addAll(older);
          _maxId = older.last.id;
        });
      }
    } catch (_) {
      // ignore
    } finally {
      setState(() => _loadingMore = false);
    }
  }

  Future<void> _loadMoreMedia() async {
    // リモートビュー中は相手サーバー (認証なし) からページングする。
    if (_remoteView) {
      if (_remoteMediaMaxId == null || _loadingMore || _remoteHost == null) {
        return;
      }
      setState(() => _loadingMore = true);
      try {
        final older = await fetchAccountStatuses(
          instanceUrl: _remoteHost!,
          accessToken: null,
          accountId: _displayAccount.id,
          maxId: _remoteMediaMaxId,
          onlyMedia: true,
        );
        if (older.isNotEmpty) {
          setState(() {
            _remoteMediaStatuses.addAll(older);
            _remoteMediaMaxId = older.last.id;
          });
        }
      } catch (_) {
        // ignore
      } finally {
        setState(() => _loadingMore = false);
      }
      return;
    }
    if (_mediaMaxId == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final auth = widget.user;
      final targetId = widget.targetAccountId ?? widget.user.id;
      final older = await fetchAccountStatuses(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        accountId: targetId,
        maxId: _mediaMaxId,
        onlyMedia: true,
      );
      if (older.isNotEmpty) {
        setState(() {
          _mediaStatuses.addAll(older);
          _mediaMaxId = older.last.id;
        });
      }
    } catch (_) {
      // ignore
    } finally {
      setState(() => _loadingMore = false);
    }
  }

  /// フォロー一覧の続きをロード。`_following.last.id` を `max_id` に渡して
  /// 続きの 1 ページ (最大 `_accountListPageSize` 件) を取り、後ろに連結する。
  /// 返ってきた数が pageSize 未満ならそれ以上は無いので `_hasMoreFollowing`
  /// を false にして以降の追加 fetch を打ち切る。
  Future<void> _loadMoreFollowing() async {
    final accountId = _account?.id;
    if (accountId == null ||
        !_hasMoreFollowing ||
        _following.isEmpty ||
        _loadingMore) {
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final older = await fetchAccountFollowing(
        instanceUrl: widget.user.instanceUrl,
        accessToken: widget.user.accessToken,
        accountId: accountId,
        maxId: _following.last.id,
      );
      if (!mounted) return;
      setState(() {
        if (older.isNotEmpty) {
          // 同一 ID の重複が混じった場合は二重表示を避けるため弾く
          // (Mastodon 仕様上は出ないはずだが、派生実装での差異対策)。
          final known = _following.map((a) => a.id).toSet();
          _following = [
            ..._following,
            ...older.where((a) => !known.contains(a.id)),
          ];
        }
        _hasMoreFollowing = older.length >= _accountListPageSize;
      });
    } catch (_) {
      // ignore (次回試行可能)
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// フォロワー一覧の続きをロード。仕様は `_loadMoreFollowing` と同じ。
  Future<void> _loadMoreFollowers() async {
    final accountId = _account?.id;
    if (accountId == null ||
        !_hasMoreFollowers ||
        _followers.isEmpty ||
        _loadingMore) {
      return;
    }
    setState(() => _loadingMore = true);
    try {
      final older = await fetchAccountFollowers(
        instanceUrl: widget.user.instanceUrl,
        accessToken: widget.user.accessToken,
        accountId: accountId,
        maxId: _followers.last.id,
      );
      if (!mounted) return;
      setState(() {
        if (older.isNotEmpty) {
          final known = _followers.map((a) => a.id).toSet();
          _followers = [
            ..._followers,
            ...older.where((a) => !known.contains(a.id)),
          ];
        }
        _hasMoreFollowers = older.length >= _accountListPageSize;
      });
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _onFollowPressed() async {
    if (_rel == null) return;
    final isFollowing = _rel!.following;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isFollowing ? ctx.l10n.unfollow : ctx.l10n.follow),
        content: Text(isFollowing
            ? ctx.l10n.profUnfollowConfirm
            : ctx.l10n.profFollowConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final auth = widget.user;
      final updated = isFollowing
        ? await unfollowAccount(
            instanceUrl: auth.instanceUrl,
            accessToken: auth.accessToken,
            accountId: widget.targetAccountId ?? widget.user.id,
          )
        : await followAccount(
            instanceUrl: auth.instanceUrl,
            accessToken: auth.accessToken,
            accountId: widget.targetAccountId ?? widget.user.id,
            notify: _rel!.notifications,
          );
      setState(() => _rel = updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.profFollowActionFailed('$e'))),
        );
      }
    }
  }

  Future<void> _onNotifyPressed() async {
    if (_rel == null) return;
    final isNotifying = _rel!.notifications;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isNotifying ? ctx.l10n.profNotifyOff : ctx.l10n.profNotifyOn),
        content: Text(isNotifying
            ? ctx.l10n.profNotifyOffConfirm
            : ctx.l10n.profNotifyOnConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final auth = widget.user;
      final updated = await followAccount(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        accountId: widget.targetAccountId ?? widget.user.id,
        notify: !isNotifying,
      );
      setState(() => _rel = updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.profNotifyChangeFailed('$e'))),
        );
      }
    }
  }

  /// 登録日ラベル。年月日の並び順の locale 差は .arb 側で吸収する。
  String _joinedOnLabel(DateTime d) =>
      context.l10n.profJoinedOn(d.year, d.month, d.day);

  bool _hasValidHeader(String? headerUrl) {
    if (headerUrl == null || headerUrl.trim().isEmpty) return false;
    final url = headerUrl.toLowerCase();
    if (url.contains('/headers/original/missing.png') ||
        (url.contains('/assets/') && url.contains('missing')) ||
        url.endsWith('/missing.png') ||
        (url.contains('default') && url.contains('header'))) {
      return false;
    }
    return true;
  }

  Future<void> _handleMenuAction(String action, Account account) async {
    final auth = widget.user;

    switch (action) {
      case 'add_to_list':
        await showAddToListSheet(
          context: context,
          auth: auth,
          target: account,
        );
        break;
      case 'add_to_collection':
        await _showAddToCollectionSheet(auth, account);
        break;
      case 'mute':
        await _toggleMute(auth, account);
        break;
      case 'block':
        await _toggleBlock(auth, account);
        break;
      case 'domain_block':
        await _blockDomain(auth, account);
        break;
      case 'server_info':
        await _showServerInfoDialog(auth, account);
        break;
      case 'remove_from_followers':
        await _removeFromFollowers(account);
        break;
      case 'open_in_browser':
        // 表示中のアカウント (リモートビュー中は相手サーバーの url) を開く。
        await _openInBrowser(_displayAccount);
        break;
      case 'load_from_remote':
        await _loadFromRemote();
        break;
    }
  }

  /// 「コレクションに追加」: 自分の作成したコレクション一覧をボトムシートで
  /// 出し、選んだコレクションに [target] を addCollectionItem する。
  Future<void> _showAddToCollectionSheet(
      AuthAccount auth, Account target) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AddToCollectionSheet(user: auth, target: target),
    );
  }

  /// 表示中アカウントのプロフィールを外部ブラウザで開く。`account.url`
  /// (正規 URL) を優先し、無ければ acct から組み立てた fallback を使う。
  Future<void> _openInBrowser(Account account) async {
    final url =
        account.url.isNotEmpty ? account.url : _fallbackProfileUrl(account);
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
    } catch (_) {
      // 下の snackbar にフォールスルー
    }
    if (mounted) showErrorSnackBar(context, l10n.profBrowserOpenFailed);
  }

  /// `account.url` が空のときの fallback プロフィール URL。リモートは
  /// `https://host/@user`、ローカルは自インスタンス上の `/@user`。
  String _fallbackProfileUrl(Account account) {
    if (account.acct.contains('@')) {
      final parts = account.acct.split('@');
      return 'https://${parts.last}/@${parts.first}';
    }
    return '${widget.user.instanceUrl}/@${account.username}';
  }

  /// アカウントの **実サーバー** のベース URL (`https://host`) を返す。
  ///
  /// webfinger ドメイン (acct の `@` 以降) と実サーバーのホストが異なる
  /// インスタンスがある (Mastodon の `WEB_DOMAIN` ≠ `LOCAL_DOMAIN` 構成。
  /// 例: handle `@u@vivaldi.net` でも実体は `social.vivaldi.net`)。この場合
  /// acct ドメインに API を投げると 404 / 接続失敗になるため、`account.url`
  /// (正規プロフィール URL = origin) の host を優先する。url が無いときだけ
  /// acct ドメインに、それも無ければ自インスタンスにフォールバックする。
  String _serverBaseForAccount(Account account) {
    if (account.url.isNotEmpty) {
      final host = Uri.tryParse(account.url)?.host;
      if (host != null && host.isNotEmpty) return 'https://$host';
    }
    if (account.acct.contains('@')) {
      return 'https://${account.acct.split('@').last}';
    }
    return widget.user.instanceUrl;
  }

  /// 相手インスタンスの公開 API を **認証なし** で直接叩き、連合スナップ
  /// ショットでない正確なカウント / bio / fields と公開投稿に表示を切り替える。
  /// 匿名アクセス扱いになるため公開 / 未収載投稿のみで、フォロワー限定投稿は
  /// 含まれない (バナーで明示)。フォロー等の操作は従来通り home 経由 (`_account`)。
  Future<void> _loadFromRemote() async {
    final account = _account;
    // リモート (acct に @ を含む) のときだけ。ローカルは自インスタンスが
    // すでに正なので意味がない。
    if (account == null || !account.acct.contains('@')) return;
    // 実サーバーは acct ドメインでなく url の host から取る (WEB_DOMAIN ≠
    // LOCAL_DOMAIN 構成対策)。lookup は相手サーバー上のローカル名で行う。
    final remoteBase = _serverBaseForAccount(account);
    final username = account.username;
    final remoteHostLabel = Uri.parse(remoteBase).host;

    // 進捗ダイアログ。Deck (ワイド) ではこのページが nested Navigator に
    // 載るため、`showDialog` (既定で root navigator へ push) と
    // `Navigator.pop(context)` (= nearest = nested を pop) がズレてダイアログが
    // 閉じず「永遠に終わらない」状態になる。ダイアログ自身の context を捕まえ、
    // その Navigator を pop することで、どの navigator に載っていても確実に閉じる。
    BuildContext? dialogContext;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogContext = ctx;
        return AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(ctx.l10n.profFetchingRemoteProfile(remoteHostLabel)),
            ],
          ),
        );
      },
    );
    void closeProgress() {
      final dc = dialogContext;
      if (dc != null && dc.mounted) {
        Navigator.of(dc).pop();
      }
      dialogContext = null;
    }

    // 無応答な相手サーバーで無限待ちにならないようタイムアウトを付ける。
    const timeout = Duration(seconds: 20);
    try {
      final remoteAcct = await lookupAccount(
        instanceUrl: remoteBase,
        accessToken: null,
        acct: username,
      ).timeout(timeout);
      final id = remoteAcct.id;
      // 互いに独立なので並列にキックして gather する (_reloadAll と同方針)。
      final statusesFuture = fetchAccountStatuses(
        instanceUrl: remoteBase,
        accessToken: null,
        accountId: id,
        excludeDirect: true,
      );
      final mediaFuture = fetchAccountStatuses(
        instanceUrl: remoteBase,
        accessToken: null,
        accountId: id,
        onlyMedia: true,
      );
      final pinnedFuture = fetchPinnedStatuses(
        instanceUrl: remoteBase,
        accessToken: null,
        accountId: id,
      );
      // lookup さえ成功すれば「正確なカウント / bio」は得られる。投稿系は
      // インスタンスが認証なしアクセスを制限していると失敗しうる (例: vivaldi)
      // が、それで全体を倒すとカウントすら見られないので、投稿系の失敗は
      // 各々空に倒して非致命扱いにする (lookup の失敗だけが致命)。
      List<Status> statuses;
      try {
        statuses = await statusesFuture.timeout(timeout);
      } catch (_) {
        statuses = const [];
      }
      List<Status> media;
      try {
        media = await mediaFuture.timeout(timeout);
      } catch (_) {
        media = const [];
      }
      List<Status> pinned;
      try {
        pinned = await pinnedFuture.timeout(timeout);
      } catch (_) {
        pinned = const [];
      }

      closeProgress();
      if (!mounted) return;
      setState(() {
        // 相手サーバー上の acct はローカル名 (ドメイン無し) なので、表示で
        // home ドメインが補完されてしまう。home 側のフルハンドルを被せて
        // 正しい `user@origin` を表示する (#ドメイン置換対策)。
        _remoteAccount = remoteAcct.copyWith(acct: account.acct);
        _remoteStatuses = statuses;
        _remoteMediaStatuses = media;
        _remotePinned = pinned;
        _remoteMaxId = statuses.isNotEmpty ? statuses.last.id : null;
        _remoteMediaMaxId = media.isNotEmpty ? media.last.id : null;
        _remoteHost = remoteBase;
        _remoteView = true;
      });
    } catch (e) {
      // 失敗原因を切り分けてメッセージを出し分ける。Misskey 系は Mastodon API
      // (lookup / statuses) を持たないので必ずここに落ちる。検出は進捗ダイアログ
      // を出したまま行う (まだ「取得中」の延長扱い。isMisskeyInstance は内部で
      // 例外を握って false を返すので throw しない)。
      final misskey = await isMisskeyInstance(remoteBase);
      closeProgress();
      if (!mounted) return;
      final msg = misskey
          ? l10n.profRemoteMisskeyNote
          : l10n.profRemoteFetchFailedNote;
      // SnackBar はアクションを 1 つしか持てず「閉じる」を併置できない (かつ
      // デスクトップではスワイプ解除も効かない) ため、確実に閉じられるダイアログ
      // にする。ダイアログ自身の context で pop するので Deck でも確実に閉じる。
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(msg),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(ctx.l10n.close),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _openInBrowser(account);
              },
              child: Text(ctx.l10n.profOpenInBrowser),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _toggleMute(AuthAccount auth, Account account) async {
    if (_rel == null) return;
    
    final isMuting = _rel!.muting;

    // ミュート解除は従来どおりのシンプルな確認。新規ミュートは期間/通知を
    // 選べる共通ダイアログ ([showMuteDialog]) を使う。
    MuteChoice? muteChoice;
    if (isMuting) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ctx.l10n.unmuteTitle),
          content: Text(ctx.l10n.profUnmuteConfirm(account.acct)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ctx.l10n.cancel),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(ctx.l10n.unmuteTitle),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    } else {
      muteChoice = await showMuteDialog(context, acct: account.acct);
      if (muteChoice == null) return;
    }

    try {
      final updated = isMuting
        ? await unmuteAccount(
            instanceUrl: auth.instanceUrl,
            accessToken: auth.accessToken,
            accountId: account.id,
          )
        : await muteAccount(
            instanceUrl: auth.instanceUrl,
            accessToken: auth.accessToken,
            accountId: account.id,
            notifications: muteChoice!.hideNotifications,
            duration: muteChoice.duration,
          );

      setState(() => _rel = updated);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isMuting ? l10n.profUnmuted : l10n.profMuted)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.profActionFailed('$e'))),
        );
      }
    }
  }

  Future<void> _toggleBlock(AuthAccount auth, Account account) async {
    if (_rel == null) return;
    
    final isBlocking = _rel!.blocking;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isBlocking ? ctx.l10n.unblockTitle : ctx.l10n.profBlock),
        content: Text(isBlocking
            ? ctx.l10n.profUnblockConfirm(account.acct)
            : ctx.l10n.profBlockConfirm(account.acct)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: isBlocking ? null : Colors.red,
            ),
            child:
                Text(isBlocking ? ctx.l10n.unblockTitle : ctx.l10n.profBlock),
          ),
        ],
      ),
    );
    
    if (confirmed != true) return;
    
    try {
      final updated = isBlocking
        ? await unblockAccount(
            instanceUrl: auth.instanceUrl,
            accessToken: auth.accessToken,
            accountId: account.id,
          )
        : await blockAccount(
            instanceUrl: auth.instanceUrl,
            accessToken: auth.accessToken,
            accountId: account.id,
          );
      
      setState(() => _rel = updated);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text(isBlocking ? l10n.profUnblocked : l10n.profBlocked)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.profActionFailed('$e'))),
        );
      }
    }
  }

  Future<void> _blockDomain(AuthAccount auth, Account account) async {
    final domain = account.acct.split('@').last;
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.profDomainBlockTitle),
        content: Text(ctx.l10n.profDomainBlockConfirm(domain)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text(ctx.l10n.profBlock),
          ),
        ],
      ),
    );
    
    if (confirmed != true) return;
    
    try {
      await blockDomain(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        domain: domain,
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.profDomainBlocked(domain))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.profDomainBlockFailed('$e'))),
        );
      }
    }
  }

  /// サーバー情報ダイアログを表示
  Future<void> _showServerInfoDialog(AuthAccount auth, Account account) async {
    // アカウントのサーバーURLを取得
    String authorServerUrl;
    if (account.acct.contains('@')) {
      // 外部サーバーのユーザー。webfinger ドメイン (acct の @ 以降) と実
      // サーバーのホストが異なるインスタンスがある (例: @u@vivaldi.net でも
      // 実体は social.vivaldi.net)。acct ドメインに API を投げると接続失敗
      // するので、url の host から実サーバーを取る (_serverBaseForAccount)。
      authorServerUrl = _serverBaseForAccount(account);
    } else {
      // ローカルユーザーの場合は現在のアカウントのサーバー
      authorServerUrl = auth.instanceUrl;
    }
    
    // ローディングダイアログを表示。Deck (ワイド) ではこのページが nested
    // Navigator に載るため、`showDialog` (既定で root navigator へ push) を
    // `Navigator.pop(context)` (= nearest = nested を pop) で閉じようとすると
    // ズレてローディングが残り続け、上のサーバー情報ダイアログを閉じた後に
    // 「取得中」が露出してしまう。ダイアログ自身の context を捕まえて、その
    // Navigator を pop することで、どの navigator に載っていても確実に閉じる。
    BuildContext? loadingContext;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        loadingContext = ctx;
        return AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(ctx.l10n
                  .profFetchingServerInfo(Uri.parse(authorServerUrl).host)),
            ],
          ),
        );
      },
    );
    void closeLoading() {
      final lc = loadingContext;
      if (lc != null && lc.mounted) {
        Navigator.of(lc).pop();
      }
      loadingContext = null;
    }

    try {
      final serverInfo = await fetchServerInfo(
        instanceUrl: authorServerUrl,
        // 外部サーバーの場合は認証なしで取得
        accessToken: authorServerUrl == auth.instanceUrl ? auth.accessToken : null,
      );

      closeLoading();
      if (mounted) {
        // サーバー情報ダイアログを表示
        await showDialog(
          context: context,
          builder: (context) => _ProfileServerInfoDialog(
            serverInfo: serverInfo,
            instanceUrl: authorServerUrl,
            authorAccount: account,
          ),
        );
      }
    } catch (e) {
      closeLoading();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.profServerInfoFailed('$e'))),
        );
      }
    }
  }

  /// `_reloadAll` が失敗したときの画面。
  ///
  /// 例外メッセージ (`_errorObj.toString()`) をパターンマッチして「ユーザー
  /// が見つからない / アクセス制限 / 認証エラー / ネットワーク」の 4 種に
  /// 分類し、ユーザー向けの分かりやすい日本語を出す。元のメッセージも
  /// `ExpansionTile` で展開すれば SelectableText で確認できるので、
  /// 派生実装やリモート問い合わせ起因の謎エラーをデバッグするときに役立つ。
  Widget _buildErrorScreen() {
    final theme = Theme.of(context);
    final raw = _errorObj?.toString() ?? '';

    // 種別判定。`Exception('xxx: 404')` の文字列にも当たるよう小細工なし
    // で contains で見る (派生実装の I18n エラー本文に合わせるのは諦める)。
    String friendly;
    IconData icon = Icons.error_outline;
    if (raw.contains('404') ||
        raw.contains('Not Found') ||
        raw.contains(context.l10n.profUserNotFound(''))) {
      friendly = context.l10n.profErrUserNotFound;
      icon = Icons.person_off_outlined;
    } else if (raw.contains('403')) {
      friendly = context.l10n.profErrRestricted;
      icon = Icons.lock_outline;
    } else if (raw.contains('401')) {
      friendly = context.l10n.profErrAuth;
      icon = Icons.no_accounts_outlined;
    } else if (raw.contains('SocketException') ||
        raw.contains('TimeoutException') ||
        raw.contains('Connection') ||
        raw.contains('Network is') ||
        raw.contains('Failed host lookup') ||
        raw.contains('No address associated')) {
      friendly = context.l10n.profErrNetwork;
      icon = Icons.wifi_off;
    } else if (raw.isEmpty) {
      friendly = context.l10n.profErrLoadFailed;
    } else {
      friendly = context.l10n.profErrLoadFailedHint;
    }

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.profErrorTitle)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(icon, size: 56, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text(
                friendly,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              if (raw.isNotEmpty) ...[
                const SizedBox(height: 24),
                Theme(
                  // ExpansionTile の divider が出ないよう transparent
                  data: theme.copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      context.l10n.profShowDetails,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.hintColor,
                      ),
                    ),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SelectableText(
                          raw,
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: theme.hintColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _reloadAll,
                icon: const Icon(Icons.refresh),
                label: Text(context.l10n.retry),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(context.l10n.profBack),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final acct     = _account;
    final rel      = _rel;
    final settings = ref.watch(settingsProvider.select((s) => (
      fontSize: s.fontSize,
      lineHeight: s.lineHeight,
      emojiScale: s.emojiScale,
      emojiScaleInDisplayName: s.emojiScaleInDisplayName,
      disableCustomEmojiAnimationInContent:
          s.disableCustomEmojiAnimationInContent,
      disableCustomEmojiAnimationInDisplayName:
          s.disableCustomEmojiAnimationInDisplayName,
      timelineLayout: s.timelineLayout,
    )));

    switch (_status) {
      case _ProfileLoadStatus.loading:
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      case _ProfileLoadStatus.errored:
        return _buildErrorScreen();
      case _ProfileLoadStatus.loaded:
        // データが揃わない不測ケースに備えて防御チェック (本来は到達しない)
        if (acct == null || rel == null) {
          return _buildErrorScreen();
        }
        break;
    }

    // `acct` (= home の `_account`) は識別 / 操作用。表示 (ヘッダ・投稿一覧) は
    // リモートビュー中は相手サーバーの値に切り替わる `display` を使う。
    final display = _displayAccount;

    return Scaffold(
      appBar: AppBar(
        // Deck のマイプロフィールポップアップで開かれた時だけ戻る (←) を出す。
        // それ以外は null = 既定 (push 時は自動の戻る矢印)。
        leading: widget.onDeckBack == null
            ? null
            : BackButton(onPressed: widget.onDeckBack),
        title: _buildAccountSwitcher(),
        actions: [
          // 自分のプロフィールの場合は編集ボタンを表示
          if (widget.targetAccountId == null || acct.id == widget.user.id) ...[
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: context.l10n.profEditTooltip,
              onPressed: () async {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ProfileEditPage(
                      user: widget.user,
                      profile: acct,
                    ),
                  ),
                );
                
                // 更新された場合はプロフィールを再読み込み
                if (result == true) {
                  _reloadAll();
                }
              },
            ),
          ] else ...[
            // 他のユーザーのプロフィールの場合はフォローボタンを表示
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: ElevatedButton.icon(
                onPressed: _onFollowPressed,
                icon: Icon(
                  rel.following ? Icons.person_remove : Icons.person_add,
                  size: 18,
                ),
                label: Text(
                  rel.following ? context.l10n.unfollow : context.l10n.follow,
                  style: const TextStyle(
                    fontSize: 12,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: rel.following ? Colors.grey : Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
            // 通知アイコンをハッシュタグと同じに（オン時は色付き）
            IconButton(
              icon: Icon(
                rel.notifications
                  ? Icons.notifications_active
                  : Icons.notifications_none,
                color: rel.notifications ? Colors.orange : null,
              ),
              tooltip: rel.notifications
                  ? context.l10n.profNotifyOff
                  : context.l10n.profNotifyOn,
              onPressed: _onNotifyPressed,
            ),
          ],
          // その他のメニュー
          //
          // 自分自身のプロフィールではミュート/ブロック/ドメインブロック/
          // フォロワーから外す/リストに追加は意味を成さない (Mastodon API も
          // 自分自身に対しては no-op か拒否) ので非表示にして、サーバー情報
          // (= 自インスタンスの情報) だけを残す。
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) => _handleMenuAction(value, acct),
            itemBuilder: (context) {
              final isSelf = acct.id == widget.user.id;
              return [
                if (!isSelf) ...[
                  PopupMenuItem(
                    value: 'add_to_list',
                    child: ListTile(
                      leading: const Icon(Icons.playlist_add),
                      title: Text(context.l10n.listAddToList),
                      dense: true,
                    ),
                  ),
                  if (_supportsV46Features)
                    PopupMenuItem(
                      value: 'add_to_collection',
                      child: ListTile(
                        leading: const Icon(Icons.collections_bookmark),
                        title: Text(context.l10n.profAddToCollection),
                        dense: true,
                      ),
                    ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'mute',
                    child: ListTile(
                      leading: Icon(
                        rel.muting ? Icons.volume_up : Icons.volume_off,
                      ),
                      title: Text(rel.muting
                          ? context.l10n.unmuteTitle
                          : context.l10n.muteTitle),
                      dense: true,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'block',
                    child: ListTile(
                      leading: Icon(
                        rel.blocking ? Icons.block : Icons.block,
                        color: rel.blocking ? Colors.red : null,
                      ),
                      title: Text(
                        rel.blocking
                            ? context.l10n.unblockTitle
                            : context.l10n.profBlock,
                        style: TextStyle(
                          color: rel.blocking ? Colors.red : null,
                        ),
                      ),
                      dense: true,
                    ),
                  ),
                  // 相手が自分をフォロー中のときだけ「フォロワーから外す」を出す。
                  // ブロックほど強い操作ではないので、ブロック群より前に置く。
                  if (rel.followedBy) ...[
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'remove_from_followers',
                      child: ListTile(
                        leading: const Icon(Icons.person_remove_outlined),
                        title: Text(context.l10n.profRemoveFollower),
                        dense: true,
                      ),
                    ),
                  ],
                  if (acct.acct.contains('@')) ...[
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'domain_block',
                      child: ListTile(
                        leading: const Icon(Icons.shield, color: Colors.red),
                        title: Text(
                          context.l10n
                              .profDomainBlockAction(acct.acct.split('@').last),
                          style: const TextStyle(color: Colors.red),
                        ),
                        dense: true,
                      ),
                    ),
                  ],
                  const PopupMenuDivider(),
                ],
                // ブラウザで開く: 相手サーバーが認証 / 公開範囲を正しく
                // 処理するので、完全かつ正確な情報を確実に見られる。自他
                // どちらでも有用なので常に出す。
                PopupMenuItem(
                  value: 'open_in_browser',
                  child: ListTile(
                    leading: const Icon(Icons.open_in_browser),
                    title: Text(context.l10n.profOpenInBrowser),
                    dense: true,
                  ),
                ),
                // 相手サーバーから最新を読み込む: リモートアカウント
                // (acct に @ を含む) で、まだ相手ビューに切り替えていない
                // ときだけ。連合スナップショットでなく正確なカウント /
                // 公開投稿を相手インスタンス直叩きで取得する。
                if (acct.acct.contains('@') && !_remoteView)
                  PopupMenuItem(
                    value: 'load_from_remote',
                    child: ListTile(
                      leading: const Icon(Icons.cloud_download_outlined),
                      title: Text(context.l10n.profLoadFromRemote),
                      dense: true,
                    ),
                  ),
                // サーバー情報は自他どちらでも有用なので常に出す。
                PopupMenuItem(
                  value: 'server_info',
                  child: ListTile(
                    leading: const Icon(Icons.dns),
                    title: Text(context.l10n.profServerInfoTitle),
                    dense: true,
                  ),
                ),
              ];
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 相手サーバー公開ビュー中のバナー。AppBar 直下に常時固定し、
          // 「公開投稿のみ (フォロワー限定は含まれない)」を明示して、
          // 自インスタンス表示へ戻す導線を出す。
          if (_remoteView) _buildRemoteBanner(),
          Expanded(
            child: SafeArea(
        top: true,
        bottom: false,
        // pull-to-refresh は **各タブ内** に置きつつ、`notificationPredicate`
        // で「外側 sliver header が top に戻った時」だけ反応するよう絞る。
        // (RefreshIndicator を外側に出すと内側 ListView のオーバスクロール
        //  通知が伝わらず refresh が走らない、内側だけだとタブ内 ListView が
        //  常時 offset 0 のため誤発火する、を両方避けるための折衷)
        child: NestedScrollView(
          controller: _outerScrollController,
          physics: const BouncingScrollPhysics(),
          headerSliverBuilder: (ctx, inner) {
            return <Widget>[
              if (_hasValidHeader(display.headerUrl))
                SliverToBoxAdapter(
                  child: DynamicHeaderImage(url: display.headerUrl),
                ),
              SliverToBoxAdapter(
                child: _buildHeader(display, settings, _familiarFollowers),
              ),
              SliverPersistentHeader(
                pinned: true,
                delegate: _SliverTabBarDelegate(
                  TabBar(
                    controller: _tabController,
                    tabs: [
                      Tab(text: context.l10n.profTabPosts),
                      Tab(text: context.l10n.profTabMedia),
                      Tab(text: context.l10n.profTabFollowing),
                      Tab(text: context.l10n.profTabFollowers),
                      // コレクションタブは 4.6+ のみ。
                      if (_supportsV46Features)
                        Tab(text: context.l10n.profTabCollections),
                    ],
                  ),
                ),
              ),
            ];
          },
          body: TabBarView(
            controller: _tabController,
            children: [
              // 各タブを `_KeepAliveTab` で包んで、タブ切替で State (= 内側
              // ListView の ScrollController が握っているスクロール位置) が
              // 破棄されないようにする。これがないと「投稿タブをスクロール
              // → メディアタブ → 投稿タブに戻る」で 0 番目に飛んでしまう。
              _KeepAliveTab(child: _buildPostsTab(settings)),
              _KeepAliveTab(child: _buildMediaTab(settings)),
              _KeepAliveTab(
                child: _buildAccountList(
                  _following,
                  context.l10n.profFollowingLabel,
                  hasMore: _hasMoreFollowing,
                ),
              ),
              // 自分のプロフィールを開いている時だけ各フォロワーに「外す」
              _KeepAliveTab(
                child: _buildAccountList(
                  _followers,
                  context.l10n.profTabFollowers,
                  allowRemoveFromFollowers: widget.targetAccountId == null ||
                      _account?.id == widget.user.id,
                  hasMore: _hasMoreFollowers,
                ),
              ),
              // コレクション (4.6+)。自前でロードする独立 widget。
              if (_supportsV46Features)
                _KeepAliveTab(
                  child: _CollectionsTab(
                    user: widget.user,
                    accountId: acct.id,
                    isSelf: widget.targetAccountId == null ||
                        acct.id == widget.user.id,
                  ),
                ),
            ],
          ),
        ), // close NestedScrollView
            ), // close SafeArea
          ), // close Expanded
        ],
      ), // close Column
    );
  }

  /// 相手サーバー公開ビュー中に AppBar 直下へ固定するバナー。
  Widget _buildRemoteBanner() {
    final host = _remoteHost != null ? Uri.parse(_remoteHost!).host : '';
    final color = Theme.of(context).colorScheme.primary;
    return Material(
      color: color.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            Icon(Icons.public, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                context.l10n.profRemoteViewNotice(host),
                style: const TextStyle(fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: _reloadAll,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(context.l10n.profBackToHomeInstance,
                  style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  /// プロフィールヘッダ全体の組み立て。
  ///
  /// 直接 State (`_account` / `_familiarFollowers` / `_rel` 等) を読まず、
  /// 引数で受け取れるものは引数で渡す方針 (= 各セクションが「何に依存
  /// しているか」を明示)。`_rel` だけはバッジ + private note の両方で
  /// 使われていてフロー上 nullable のため、ここでは内部で `_rel` を
  /// 参照する形を残す。
  Widget _buildHeader(
    Account acct,
    _ProfileSettingsSlice settings,
    List<Account> familiarFollowers,
  ) {
    final textColor = Theme.of(context).textTheme.bodyMedium?.color ?? Colors.black;
    final fs = settings.fontSize;
    final lh = settings.lineHeight;
    final rel = _rel; // フォロー関係情報

    final nameSpans = _cachedParseSpans(
      key: 'displayName',
      html: acct.displayName,
      emojis: acct.emojis,
      baseStyle: Theme.of(context).textTheme.titleLarge!.copyWith(
            fontSize: fs + 4,
          ),
      linkColor: Colors.blue, // リンクは青色固定
      emojiSize: (fs + 4) * settings.emojiScaleInDisplayName,
      disableEmojiAnimation: settings.disableCustomEmojiAnimationInDisplayName,
      enableInlineLinks: false, // 表示名は metadata
    );
    final headerName = RichText(
      text: TextSpan(children: nameSpans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // アイコン＋表示名＋@username
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // 表示は 80×80。外観設定の四角アイコン設定に追従する。
              UserAvatar(
                url: acct.avatarUrl,
                radius: 40,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: headerName),
                        // アカウント属性アイコン
                        if (acct.bot)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Icon(
                              Icons.smart_toy,
                              size: fs + 6,
                              color: Colors.grey[600],
                            ),
                          ),
                        if (acct.locked)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Icon(
                              Icons.lock,
                              size: fs + 6,
                              color: Colors.grey[600],
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      formatAcct(acct.acct, widget.user.instanceUrl),
                      style: TextStyle(
                        color: textColor,
                        fontSize: fs + 2,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    // 登録日 (yyyy年MM月)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          Icon(Icons.calendar_today,
                              size: fs - 2, color: textColor),
                          const SizedBox(width: 4),
                          Text(
                            _joinedOnLabel(acct.createdAt.toLocal()),
                            style: TextStyle(
                              color: textColor,
                              fontSize: fs - 2,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // フォロー関係の表示
                    if (rel != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (rel.followedBy)
                            Container(
                              margin: const EdgeInsets.only(right: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Theme.of(context).brightness == Brightness.dark
                                    ? Colors.green.shade800.withValues(alpha: 0.3)
                                    : Colors.green.shade100,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Theme.of(context).brightness == Brightness.dark
                                      ? Colors.green.shade600
                                      : Colors.green.shade300,
                                ),
                              ),
                              child: Text(
                                context.l10n.profFollowsYou,
                                style: TextStyle(
                                  fontSize: fs - 2,
                                  color: Theme.of(context).brightness == Brightness.dark
                                      ? Colors.green.shade300
                                      : Colors.green.shade700,
                                ),
                              ),
                            ),
                          if (rel.following)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Theme.of(context).brightness == Brightness.dark
                                    ? Colors.blue.shade800.withValues(alpha: 0.3)
                                    : Colors.blue.shade100,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Theme.of(context).brightness == Brightness.dark
                                      ? Colors.blue.shade600
                                      : Colors.blue.shade300,
                                ),
                              ),
                              child: Text(
                                context.l10n.profFollowingLabel,
                                style: TextStyle(
                                  fontSize: fs - 2,
                                  color: Theme.of(context).brightness == Brightness.dark
                                      ? Colors.blue.shade300
                                      : Colors.blue.shade700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        // 投稿・フォロー数
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _countCol(context.l10n.profTabPosts, acct.statusesCount),
              _countCol(context.l10n.profTabFollowing, acct.followingCount),
              _countCol(context.l10n.profTabFollowers, acct.followersCount),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (acct.note.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: RichText(
              text: TextSpan(
                style: TextStyle(
                  fontSize: fs,
                  height: lh,
                  color: Theme.of(context).textTheme.bodyLarge?.color,
                ),
                children: _cachedParseSpans(
                  key: 'note',
                  html: acct.note,
                  emojis: acct.emojis,
                  baseStyle: TextStyle(
                    fontSize: fs,
                    height: lh,
                    color: Theme.of(context).textTheme.bodyLarge?.color,
                  ),
                  linkColor: Colors.blue, // リンクは青色固定
                  emojiSize: fs * settings.emojiScale,
                  disableEmojiAnimation:
                      settings.disableCustomEmojiAnimationInContent,
                ),
              ),
            ),
          ),
        // ── 共通のフォロワー (familiar followers) ── //
        // 自分のフォロー中のうち、このアカウントもフォローしている人。
        // 自分のプロフィールでは load 自体スキップしているので空配列のはず。
        if (acct.id != widget.user.id && familiarFollowers.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: _buildFamiliarFollowersStrip(familiarFollowers, fs),
          ),
        // ── 自分専用メモ (Mastodon の private note 機能) ── //
        // 他のユーザーを見ているときだけ表示する。自分のプロフィールには
        // メモを付けられない。
        if (rel != null && acct.id != widget.user.id)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: _buildPersonalNoteCard(context, rel, acct, fs, lh),
          ),
        // ── プロフィール補足フィールド ── //
        if (acct.fields.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: LayoutBuilder(builder: (ctx, constraints) {
              // Mastodon Android 公式と同じく、画面幅に応じて 1 / 2 列で
              // 等分配置する。スマホ縦 (~360-400px) は 1 列、横や tablet
              // (~480px 以上) は 2 列を狙う閾値。
              final isWide = constraints.maxWidth >= 400;
              final cols = isWide ? 2 : 1;
              const spacing = 6.0;
              final itemWidth =
                  (constraints.maxWidth - spacing * (cols - 1)) / cols;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (int idx = 0; idx < acct.fields.length; idx++)
                    SizedBox(
                      width: itemWidth,
                      child: _buildProfileField(
                        acct.fields[idx],
                        idx,
                        acct.emojis,
                        fs,
                        lh,
                        textColor,
                        settings,
                        compact: cols == 1,
                      ),
                    ),
                ],
              );
            }),
          ),
        const Divider(height: 1),
      ],
    );
  }

  /// プロフィール補足フィールド 1 件分のカード。
  ///
  /// padding を詰めて密度を上げ、`field.isVerified == true` (サーバが
  /// rel="me" 検証 OK) なら緑系の背景 + 縁取り + チェックアイコンで
  /// 「認証済み」を表現する。Mastodon 公式 Web / Android 公式アプリの
  /// 見た目に揃えた。
  ///
  /// [compact] が true (= 1 列レイアウト) のときは「Name: ✓ Value」を
  /// 1 つの RichText に流して 1〜2 行に詰める (補足情報が多い人で縦長に
  /// なりすぎるのを防ぐ)。false (= 2 列等分) のときは Name 上 / Value 下の
  /// 縦積みでカード幅が狭くても可読性を維持する。
  Widget _buildProfileField(
    ProfileField f,
    int index,
    List<Emoji> emojis,
    double fs,
    double lh,
    Color textColor,
    _ProfileSettingsSlice settings, {
    required bool compact,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final verified = f.isVerified;

    final bg = verified
        ? (isDark
            ? Colors.green.shade900.withValues(alpha: 0.25)
            : Colors.green.shade50)
        : (isDark
            ? Colors.grey.shade800.withValues(alpha: 0.4)
            : Colors.grey.shade100);
    final borderColor = verified
        ? (isDark ? Colors.green.shade700 : Colors.green.shade300)
        : (isDark ? Colors.grey.shade600 : Colors.grey.shade300);
    final verifiedIconColor =
        isDark ? Colors.green.shade300 : Colors.green.shade700;

    final nameStyle = TextStyle(
      fontSize: fs - 1,
      fontWeight: FontWeight.bold,
      color: theme.hintColor,
    );
    final valueStyle = TextStyle(
      fontSize: fs,
      height: lh,
      color: textColor,
    );

    final nameSpans = _cachedParseSpans(
      key: 'fieldName:$index',
      html: f.name,
      emojis: emojis,
      baseStyle: nameStyle,
      linkColor: Colors.blue,
      emojiSize: (fs - 1) * settings.emojiScale,
      disableEmojiAnimation: settings.disableCustomEmojiAnimationInContent,
    );
    final valueSpans = _cachedParseSpans(
      key: 'fieldValue:$index',
      html: f.value,
      emojis: emojis,
      baseStyle: valueStyle,
      linkColor: Colors.blue,
      emojiSize: fs * settings.emojiScale,
      disableEmojiAnimation: settings.disableCustomEmojiAnimationInContent,
    );

    // 認証バッジを inline 配置するための WidgetSpan。compact の Row 内・
    // 縦積みの Row 内、どちらでも使い回す。
    final verifiedBadge = WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Icon(
          Icons.verified,
          size: fs,
          color: verifiedIconColor,
        ),
      ),
    );

    final cardDecoration = BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: borderColor),
    );

    if (compact) {
      // 1 列レイアウト: 「Name: (✓) Value」を 1 つの RichText に流し込んで
      // 1〜2 行で詰める。補足情報が多い人でカードが何行も縦に伸びるのを抑える。
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: cardDecoration,
        child: RichText(
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          text: TextSpan(
            children: [
              ...nameSpans,
              TextSpan(text: ': ', style: nameStyle),
              if (verified) verifiedBadge,
              ...valueSpans,
            ],
          ),
        ),
      );
    }

    // 2 列レイアウト: カード幅が狭いので Name 上 / Value 下の縦積みを維持。
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: cardDecoration,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(style: nameStyle, children: nameSpans),
          ),
          const SizedBox(height: 2),
          RichText(
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              style: valueStyle,
              children: [
                if (verified) verifiedBadge,
                ...valueSpans,
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 自分用メモ (private note) のカード。タップで編集ダイアログを開く。
  Widget _buildPersonalNoteCard(BuildContext context, Relationship rel,
      Account acct, double fs, double lh) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasNote = rel.note.trim().isNotEmpty;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _editPersonalNote(rel, acct),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.amber.shade900.withValues(alpha: 0.18)
                : Colors.amber.shade50,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isDark ? Colors.amber.shade700 : Colors.amber.shade200,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.sticky_note_2_outlined,
                      size: fs + 2,
                      color: isDark
                          ? Colors.amber.shade300
                          : Colors.amber.shade800),
                  const SizedBox(width: 6),
                  Text(
                    context.l10n.profMemoLabel,
                    style: TextStyle(
                      fontSize: fs - 1,
                      fontWeight: FontWeight.bold,
                      color: isDark
                          ? Colors.amber.shade300
                          : Colors.amber.shade800,
                    ),
                  ),
                  const Spacer(),
                  Icon(Icons.edit,
                      size: fs,
                      color: isDark
                          ? Colors.amber.shade300
                          : Colors.amber.shade800),
                ],
              ),
              if (hasNote) ...[
                const SizedBox(height: 8),
                Text(
                  rel.note,
                  style: TextStyle(fontSize: fs, height: lh),
                ),
              ] else ...[
                const SizedBox(height: 4),
                Text(
                  context.l10n.profMemoTapToAdd,
                  style: TextStyle(
                    fontSize: fs - 1,
                    color: Colors.grey,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editPersonalNote(Relationship rel, Account acct) async {
    final controller = TextEditingController(text: rel.note);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.profMemoEditTitle),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 6,
            minLines: 3,
            maxLength: 2000,
            decoration: InputDecoration(
              hintText: ctx.l10n.profMemoHint,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ctx.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(ctx.l10n.save),
          ),
        ],
      ),
    );
    // 即時 dispose は focus 外れに伴う clearComposing と競合するため 1 frame 遅延。
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (result == null) return; // キャンセル
    if (result.trim() == rel.note.trim()) return; // 変更なし

    try {
      final updated = await updateAccountNote(
        instanceUrl: widget.user.instanceUrl,
        accessToken: widget.user.accessToken,
        accountId: acct.id,
        comment: result,
      );
      if (mounted) {
        setState(() => _rel = updated);
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(context, l10n.profMemoSaveFailed);
      }
    }
  }

  Widget _buildPostsTab(_ProfileSettingsSlice settings) {
    final list = _buildPostsList(settings);
    // 自分のプロフィール (かつ自インスタンス表示) のときだけ、その場で DM の
    // 表示/非表示を切り替えるトグルを投稿一覧の上に出す。リモートビューや
    // 他人のプロフィールでは DM は元々出ないので意味が無く、出さない。
    // 4.6 未満は exclude_direct フィルタが無く DM を分離できないのでトグルも出さない。
    if (!_isOwnProfile || _remoteView || !_supportsV46Features) return list;
    return Column(
      children: [
        SwitchListTile(
          dense: true,
          secondary: const Icon(Icons.alternate_email),
          title: Text(context.l10n.profShowDm),
          value: !_excludeDirect,
          onChanged: (show) => _setExcludeDirect(!show),
        ),
        const Divider(height: 1),
        Expanded(child: list),
      ],
    );
  }

  Widget _buildPostsList(_ProfileSettingsSlice settings) {
    return RefreshIndicator(
      onRefresh: _reloadAll,
      // 「外側 sliver header が top に戻った時」だけ refresh を有効化。
      // (予測子なしだとタブ内 ListView の常時 offset 0 で誤発火する)
      notificationPredicate: (n) => n.depth == 0 && _isOuterAtTop(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (!_loadingMore &&
              n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
            _loadMore();
          }
          return false;
        },
        child: ListView.builder(
        itemCount:
            _displayPinned.length + _displayStatuses.length + (_loadingMore ? 1 : 0),
        itemBuilder: (ctx, i) {
          final layout = settings.timelineLayout;
          if (i < _displayPinned.length) {
            final s = _displayPinned[i];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  child: Text(context.l10n.profPinnedPosts,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                      )),
                ),
                wrapForTimelineLayout(
                  ctx,
                  PostTile(
                    status: s,
                    accountId: widget.user.id,
                    statusSourceInstanceUrl: _statusSource,
                  ),
                  layout,
                ),
                timelineSeparator(layout),
              ],
            );
          }
          final idx = i - _displayPinned.length;
          if (idx < _displayStatuses.length) {
            final s = _displayStatuses[idx];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                wrapForTimelineLayout(
                  ctx,
                  PostTile(
                    status: s,
                    accountId: widget.user.id,
                    statusSourceInstanceUrl: _statusSource,
                  ),
                  layout,
                ),
                timelineSeparator(layout),
              ],
            );
          }
          return const Padding(
            padding: EdgeInsets.all(8),
            child: Center(child: CircularProgressIndicator()),
          );
        },
        ),
      ),
    );
  }

  Widget _buildMediaTab(_ProfileSettingsSlice settings) {
    return RefreshIndicator(
      onRefresh: _reloadAll,
      notificationPredicate: (n) => n.depth == 0 && _isOuterAtTop(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (!_loadingMore &&
              n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
            _loadMore();
          }
          return false;
        },
        child: ListView.separated(
          itemCount: _displayMediaStatuses.length + (_loadingMore ? 1 : 0),
          separatorBuilder: (_, _) =>
              timelineSeparator(settings.timelineLayout),
          itemBuilder: (ctx, i) {
            if (i < _displayMediaStatuses.length) {
              return wrapForTimelineLayout(
                ctx,
                PostTile(
                  status: _displayMediaStatuses[i],
                  accountId: widget.user.id,
                  statusSourceInstanceUrl: _statusSource,
                ),
                settings.timelineLayout,
              );
            }
            return const Padding(
              padding: EdgeInsets.all(8),
              child: Center(child: CircularProgressIndicator()),
            );
          },
        ),
      ),
    );
  }

  Widget _buildAccountList(
    List<Account> list,
    String label, {
    bool allowRemoveFromFollowers = false,
    /// 「まだ続きがある」かを示す。投稿/メディアタブ同様、末尾近くまで
    /// スクロールしたら `_loadMore` を発火し、読み込み中はリスト末尾に
    /// プログレスインジケータの行を追加する。
    bool hasMore = false,
  }) {
    if (list.isEmpty) {
      return Center(child: Text(context.l10n.profNoData(label)));
    }
    return RefreshIndicator(
      onRefresh: _reloadAll,
      notificationPredicate: (n) => n.depth == 0 && _isOuterAtTop(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (!_loadingMore &&
              hasMore &&
              n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
            _loadMore();
          }
          return false;
        },
        child: ListView.separated(
          itemCount: list.length + (_loadingMore && hasMore ? 1 : 0),
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (_, i) {
            if (i >= list.length) {
              // 末尾のローディング行 (追加ロード中だけ表示)
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final a = list[i];
            // ListTile leading は default radius 20 (40×40)。
            return ListTile(
              leading: UserAvatar(
                url: a.avatarUrl,
                radius: 20,
              ),
              title: Text(a.displayName),
              subtitle: Text(formatAcct(a.acct, widget.user.instanceUrl)),
              // 「フォロワーから外す」(Mastodon 4.0+)。ブロックなしで相手の
              // フォローだけ切るためのもので、自分のプロフィールのフォロワー
              // タブだけで出す。古いサーバ / 派生実装は API が 404 を返す
              // ので、その時は SnackBar で「対応していない」案内する。
              trailing: allowRemoveFromFollowers
                  ? IconButton(
                      icon: const Icon(Icons.person_remove_outlined),
                      tooltip: context.l10n.profRemoveFollower,
                      onPressed: () => _removeFromFollowers(a),
                    )
                  : null,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ProfilePage(
                      user: widget.user, // 操作用アカウントは同じ
                      targetAccountId: a.id, // 表示対象は選択したアカウント
                      targetUsername: a.username,
                      targetInstanceUrl:
                          widget.user.instanceUrl, // 同じインスタンス内
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// フォロワーから指定アカウントを外す (確認ダイアログ + API + ローカル状態
  /// 同期)。
  ///
  /// 呼び出し元は 2 つ:
  ///  1. 自分のプロフィールのフォロワータブの IconButton (一覧の各行)
  ///  2. 相手のプロフィールページの「…」メニュー (`rel.followedBy == true`
  ///     のとき表示)
  ///
  /// API レスポンスの新しい Relationship を `_rel` に反映するのは、操作対象が
  /// 現在表示中のアカウントと一致しているとき (= ケース 2) だけ。ケース 1 は
  /// `_account` が自分なので `_rel` 自体を更新する意味がない。
  Future<void> _removeFromFollowers(Account follower) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.profRemoveFollower),
        content: Text(ctx.l10n.profRemoveFollowerConfirm(follower.acct)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l10n.profRemoveAction),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final updated = await removeFromFollowers(
        instanceUrl: widget.user.instanceUrl,
        accessToken: widget.user.accessToken,
        accountId: follower.id,
      );
      if (!mounted) return;
      setState(() {
        _followers = _followers.where((a) => a.id != follower.id).toList();
        // 表示中のプロフィール = いま外したフォロワー、なら rel も差し替え。
        // これでメニュー項目「フォロワーから外す」が followedBy=false で
        // 自動的に消える。
        if (_account?.id == follower.id) {
          _rel = updated;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.profFollowerRemoved(follower.acct))),
      );
    } on RemoveFromFollowersNotSupportedException catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, e.message);
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, l10n.profRemoveFollowerFailed('$e'));
    }
  }

  /// 共通のフォロワーを示す細い帯。アバター 3 枚 (重ね) + 「X さん他 N 人が
  /// フォローしています」のテキスト。タップで `_FamiliarFollowersListPage` を
  /// 開いて全員一覧。
  ///
  /// 件数が多いと 1 行に収まらない可能性があるため、`Flexible` +
  /// `overflow: ellipsis` で 1 行に切り詰める。
  Widget _buildFamiliarFollowersStrip(List<Account> list, double fs) {
    final theme = Theme.of(context);
    // 重ねるアバター枚数。多すぎると視認性が落ちるので 3 枚まで。
    final visibleCount = list.length >= 3 ? 3 : list.length;
    final avatarSize = fs + 12;
    final overlap = avatarSize * 0.4;

    final firstName =
        list.first.displayName.isNotEmpty ? list.first.displayName : list.first.username;
    final secondName = list.length >= 2
        ? (list[1].displayName.isNotEmpty ? list[1].displayName : list[1].username)
        : null;
    final remaining = list.length - 2;

    final String text;
    if (list.length == 1) {
      text = context.l10n.profFamiliarOne(firstName);
    } else if (list.length == 2) {
      text = context.l10n.profFamiliarTwo(firstName, secondName!);
    } else {
      text = context.l10n.profFamiliarMany(firstName, secondName!, remaining);
    }

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => _FamiliarFollowersListPage(
              user: widget.user,
              accounts: list,
              targetUsername: _account?.acct ?? '',
            ),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            // アバター重ね
            SizedBox(
              width: avatarSize + overlap * (visibleCount - 1),
              height: avatarSize,
              child: Stack(
                children: [
                  for (int i = 0; i < visibleCount; i++)
                    Positioned(
                      left: overlap * i,
                      // 後ろのアバターと重なって見えるよう scaffold 背景色で
                      // 縁取りつつ、外観設定の四角アイコンにも追従する。
                      child: Consumer(builder: (_, ref, _) {
                        final isSquare = ref.watch(settingsProvider
                            .select((s) => s.isAvatarSquare));
                        final inner = avatarSize / 2 - 2;
                        return Container(
                          decoration: BoxDecoration(
                            shape: isSquare
                                ? BoxShape.rectangle
                                : BoxShape.circle,
                            borderRadius: isSquare
                                ? BorderRadius.circular(
                                    (inner * 0.1).clamp(2.0, 12.0) + 2)
                                : null,
                            border: Border.all(
                              color: theme.scaffoldBackgroundColor,
                              width: 2,
                            ),
                          ),
                          child: UserAvatar(
                            url: list[i].avatarUrl,
                            radius: inner,
                          ),
                        );
                      }),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: fs - 2,
                  color: theme.hintColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _countCol(String label, int count) => Column(
        children: [
          Text('$count', style: const TextStyle(
            fontWeight: FontWeight.bold,
          )),
          Text(label),
        ],
      );

  /// AppBarのアカウント切り替えボタン
  Widget _buildAccountSwitcher() {
    return GestureDetector(
      onTap: () => _showAccountSwitcher(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 直径 32px。外観設定の四角アイコン設定に追従する。
          UserAvatar(
            url: widget.user.avatarUrl,
            radius: 16,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.user.displayName,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '@${widget.user.username}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const Icon(Icons.arrow_drop_down, size: 20),
        ],
      ),
    );
  }

  /// アカウント切り替えモーダルを表示
  void _showAccountSwitcher() {
    final auth = ref.read(authProvider);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true, // コンテンツのサイズを制御可能に
      builder: (context) => SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.l10n.profOpenFromAnotherAccount,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              ...auth.accounts.map((account) {
                final isSelected = account.id == widget.user.id;

                return ListTile(
                  leading: UserAvatar(
                    url: account.avatarUrl,
                    radius: 20,
                  ),
                  title: Text(
                    account.displayName,
                    style: TextStyle(
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(
                    // formatAcct と同じ規則で組み立てる (他のプロフィール表示
                    // と統一)。ローカルユーザの場合 username は acct 形式
                    // ではないので fallback の instanceUrl を補完させる。
                    formatAcct(account.username, account.instanceUrl),
                  ),
                  trailing: isSelected ? const Icon(Icons.check, color: Colors.green) : null,
                  onTap: isSelected ? null : () => _switchAccount(account),
                );
              }),
              // ナビゲーションバー分のスペースを確保
              SizedBox(height: MediaQuery.of(context).padding.bottom),
            ],
          ),
        ),
      ),
    );
  }

  /// アカウントを切り替えてプロフィールを再読み込み
  void _switchAccount(AuthAccount newAccount) {
    Navigator.pop(context); // モーダルを閉じる

    // widget.targetAccountId は **元のインスタンスでの** ID なので、別インスタンス
    // のアカウントから開いたら fetchAccount は必ず失敗する。`_reloadAll` の
    // catch 節は targetUsername + targetInstanceUrl があれば search で fallback
    // できるが、search_page など一部の呼び出し元は targetAccountId しか渡して
    // こない。そこで、今ロード済みの `_account` から webfinger 風の情報
    // (username + instance URL) を復元して新しい ProfilePage に持たせる。
    //
    // - acct = "user@host.example" のとき → リモート、host が instance URL になる
    // - acct = "user"             のとき → ローカル (= widget.user.instanceUrl)
    final loaded = _account;
    String? username = widget.targetUsername;
    String? instanceUrl = widget.targetInstanceUrl;
    if (loaded != null) {
      if (loaded.acct.contains('@')) {
        final parts = loaded.acct.split('@');
        username ??= parts.first;
        instanceUrl ??= 'https://${parts.last}';
      } else {
        username ??= loaded.username;
        instanceUrl ??= widget.user.instanceUrl;
      }
    }

    // 新しいアカウントでProfilePageを置き換え
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ProfilePage(
          user: newAccount, // 操作用アカウント
          targetAccountId: widget.targetAccountId,
          targetUsername: username,
          targetInstanceUrl: instanceUrl,
        ),
      ),
    );
  }
}

/// プロフィール本体の読み込み状態。`bool _loading` + `Object? _error` の
/// 2 変数管理は組み合わせ矛盾 (loading=true && errored 同時セット等) を
/// 招きやすいため enum で 1 つにまとめる。
enum _ProfileLoadStatus {
  /// 初回ロード中、または pull-to-refresh 中。
  loading,
  /// ロード成功 = 通常表示。
  loaded,
  /// ロード失敗。`_errorObj` に例外が入っている。
  errored,
}

/// プロフィールページのタブ種別。`_loadMore` で `_tabController.index` を
/// 直接 switch すると並び順を変えたときにサイレントに壊れる
/// (例: case 0 が posts のままなのに UI 順だけ media を先にする変更を加える
///  と、media タブでも posts の loadMore が走るバグになる)。
/// この enum の宣言順 = `TabBarView.children` の並び順、という 1 つの
/// 不変条件に紐付けることで「index と意味」を分離する。
enum _ProfileTab { posts, media, following, followers, collections }

/// `_ProfilePageState._parseCache` の値型。spans に含まれる
/// `TapGestureRecognizer` をキャッシュ置換時 / state dispose 時に確実に
/// `dispose()` する責務を持つ。実装は post_tile の `_ParsedSpansEntry`
/// と同等 (=リーク対策のため再帰的に TextSpan の recognizer を辿る)。
class _ParsedSpansEntry {
  final String signature;
  final List<InlineSpan> spans;

  _ParsedSpansEntry(this.signature, this.spans);

  void dispose() {
    for (final span in spans) {
      _disposeSpanRecursively(span);
    }
  }

  static void _disposeSpanRecursively(InlineSpan span) {
    if (span is TextSpan) {
      span.recognizer?.dispose();
      final children = span.children;
      if (children != null) {
        for (final c in children) {
          _disposeSpanRecursively(c);
        }
      }
    } else if (span is WidgetSpan) {
      // WidgetSpan の child 内に Text.rich(...) がぶら下がっている可能性は
      // profile_page では今のところ無いが、html_parser の仕様変更で増えても
      // 安全になるよう PostTile と同じく再帰サポートを残しておく。
      final child = span.child;
      if (child is Text) {
        final t = child.textSpan;
        if (t != null) _disposeSpanRecursively(t);
      }
    }
  }
}

/// `TabBarView` の各タブを包んで、タブ切替で State (= 内側 ListView の
/// ScrollController が握っているスクロール位置) が破棄されないようにする
/// 薄いラッパ。`AutomaticKeepAliveClientMixin` の `wantKeepAlive => true` で
/// off-screen でも Element/State を保持させる。
class _KeepAliveTab extends StatefulWidget {
  final Widget child;
  const _KeepAliveTab({required this.child});

  @override
  State<_KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<_KeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // KeepAlive 規約: build の先頭で super を呼ぶ
    return widget.child;
  }
}

// タブバー固定デリゲートは省略せず同じ実装です。
class _SliverTabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar _tabBar;
  _SliverTabBarDelegate(this._tabBar);

  @override
  double get minExtent => _tabBar.preferredSize.height;
  @override
  double get maxExtent => _tabBar.preferredSize.height;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: _tabBar,
    );
  }

  @override
  bool shouldRebuild(covariant SliverPersistentHeaderDelegate old) =>
      false;
}

class DynamicHeaderImage extends StatefulWidget {
  final String url;
  const DynamicHeaderImage({super.key, required this.url});

  @override
  State<DynamicHeaderImage> createState() => _DynamicHeaderImageState();
}

class _DynamicHeaderImageState extends State<DynamicHeaderImage> {
  /// 取得済みのアスペクト比 (= width / height)。null = まだ取れていない。
  double? _aspect;

  /// 表示と aspect 取得で **共有する** ImageProvider。
  ///
  /// 旧実装は `NetworkImage` を 2 回別々に作っていたので同じ画像が 2 回 fetch
  /// されていた。`CachedNetworkImageProvider` を 1 個だけ作って resolve と
  /// `Image(image: ...)` で使い回せば、disk + memory cache を経由するので
  /// 実質 1 fetch で済む (resolve でキックされた download が memory に
  /// 乗り、続く Image() の解決で cache hit する)。
  ///
  /// Web では ImageProvider は bytes 経由 decode = CORS の影響を受けるため
  /// この pattern が使えない (resolve で永遠に待たされ aspect も取れない)。
  /// build 内で kIsWeb 分岐し、KurageNetworkImage (HTML <img> 経由) で
  /// 固定 2:1 描画にフォールバックする。
  late CachedNetworkImageProvider _provider;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) _attach();
  }

  @override
  void didUpdateWidget(DynamicHeaderImage old) {
    super.didUpdateWidget(old);
    // URL 変更 (= 別ユーザのプロフィールに切り替わった) → 取り直す
    if (old.url != widget.url) {
      _detach();
      setState(() => _aspect = null);
      if (!kIsWeb) _attach();
    }
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _attach() {
    _provider = CachedNetworkImageProvider(widget.url);
    _stream = _provider.resolve(const ImageConfiguration());
    _listener = ImageStreamListener((info, _) {
      if (mounted) {
        final ui.Image img = info.image;
        setState(() => _aspect = img.width / img.height);
      }
      // 1 回取れれば aspect は確定するので listener を片付ける (LRU と
      // ガベージコレクションを邪魔しないため)。
      _detach();
    });
    _stream!.addListener(_listener!);
  }

  void _detach() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
      _stream = null;
      _listener = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final dpr = media.devicePixelRatio;
    // 横幅は「利用可能な制約幅」基準にする。画面全体幅 (MediaQuery.size.width)
    // だと、Deck のプロフィールポップアップのように幅を絞った領域に置いたとき、
    // ヘッダの高さが画面幅基準で過大に計算されてしまう。
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : media.size.width;
        if (kIsWeb) {
          // Web は aspect 検出不能 (CORS) なので 2:1 固定で描画。
          // KurageNetworkImage が HTML <img> 経由で読むため CORS 影響なし。
          final height = width / 2;
          return KurageNetworkImage(
            imageUrl: widget.url,
            width: width,
            height: height,
            fit: BoxFit.cover,
          );
        }
        if (_aspect == null) return const SizedBox.shrink();
        final height = _aspect! < 2 ? width / 2 : width / _aspect!;
        // ヘッダ画像も Mastodon 側は最大 1500px で来るので、表示サイズ × DPR
        // を超えるデコードはメモリの無駄。ResizeImage で絞る。`fit` は
        // 「短辺合わせで最低限のデコード」、`cover` 表示用に十分な解像度を
        // 確保しつつフルデコードは避ける。
        return Image(
          image: ResizeImage(
            _provider,
            width: (width * dpr).round(),
            height: (height * dpr).round(),
            policy: ResizeImagePolicy.fit,
          ),
          width: width,
          height: height,
          fit: BoxFit.cover,
        );
      },
    );
  }
}

/// プロフィールページ用サーバー情報表示ダイアログ
class _ProfileServerInfoDialog extends StatelessWidget {
  final Map<String, dynamic> serverInfo;
  final String instanceUrl;
  final Account authorAccount;

  const _ProfileServerInfoDialog({
    required this.serverInfo,
    required this.instanceUrl,
    required this.authorAccount,
  });

  @override
  Widget build(BuildContext context) {
    if (serverInfo['error'] != null) {
      return AlertDialog(
        title: Text(context.l10n.profServerInfoTitle),
        content: Text(context.l10n.genericError('${serverInfo['error']}')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.close),
          ),
        ],
      );
    }

    final stats = serverInfo['stats'] as Map<String, dynamic>?;
    final config = serverInfo['configuration'] as Map<String, dynamic>?;
    final nodeInfo = serverInfo['nodeinfo'] as Map<String, dynamic>?;
    final software = nodeInfo?['software'] as Map<String, dynamic>?;

    final dialogTitle =
        context.l10n.profServerInfoDialogTitle(authorAccount.username);

    // 広い画面 (Deck) では double.maxFinite だとダイアログがウィンドウ幅
    // いっぱいに広がってしまうので最大幅を制限する (通知フィルターと同様)。
    // 狭い画面 (スマホ) では従来どおりフル幅にして情報行に余裕を持たせる。
    final dialogWidth =
        MediaQuery.of(context).size.width < 480 ? double.maxFinite : 400.0;

    return AlertDialog(
      title: Text(dialogTitle),
      content: SizedBox(
        width: dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // プロフィール主情報
              _buildSection(context.l10n.profSectionProfileOwner, [
                _buildInfoRow(context.l10n.profInfoUsername,
                    '@${authorAccount.username}'),
                _buildInfoRow(
                    context.l10n.displayNameLabel,
                    authorAccount.displayName.isNotEmpty
                        ? authorAccount.displayName
                        : null),
                // 実際に情報を取得したサーバー (instanceUrl) の host を出す
                // (acct ドメインだと WEB_DOMAIN ≠ LOCAL_DOMAIN 構成で取得元と
                // ズレるため)。
                _buildInfoRow(
                    context.l10n.profInfoServer, Uri.parse(instanceUrl).host),
              ]),

              // 基本情報
              _buildSection(context.l10n.profSectionServerBasic, [
                _buildInfoRow(context.l10n.profInfoName, serverInfo['title']),
                _buildInfoRow('URL', serverInfo['uri'] ?? instanceUrl),
                _buildInfoRow(
                    context.l10n.profInfoVersion, serverInfo['version']),
                if (software != null)
                  _buildInfoRow(context.l10n.profInfoSoftware,
                      '${software['name']} ${software['version']}'),
              ]),

              // 説明
              if (serverInfo['short_description']?.toString().isNotEmpty == true)
                _buildSection(context.l10n.profSectionDescription, [
                  Text(
                    serverInfo['short_description'],
                    style: const TextStyle(fontSize: 14),
                  ),
                ]),

              // 統計情報
              if (stats != null)
                _buildSection(context.l10n.profSectionStats, [
                  _buildInfoRow(context.l10n.profInfoUserCount,
                      stats['user_count']?.toString()),
                  _buildInfoRow(context.l10n.profInfoStatusCount,
                      stats['status_count']?.toString()),
                  _buildInfoRow(context.l10n.profInfoDomainCount,
                      stats['domain_count']?.toString()),
                ]),

              // 登録情報
              _buildSection(context.l10n.profSectionRegistrations, [
                _buildInfoRow(
                    context.l10n.profInfoNewRegistrations,
                    serverInfo['registrations'] == true
                        ? context.l10n.profRegOpen
                        : context.l10n.profRegClosed),
                _buildInfoRow(
                    context.l10n.profInfoApprovalRequired,
                    serverInfo['approval_required'] == true
                        ? context.l10n.profYes
                        : context.l10n.profNo),
                _buildInfoRow(
                    context.l10n.profInfoInvitesEnabled,
                    serverInfo['invites_enabled'] == true
                        ? context.l10n.profYes
                        : context.l10n.profNo),
              ]),

              // 設定情報
              if (config != null) ...[
                if (config['statuses'] != null)
                  _buildSection(context.l10n.profSectionPostSettings, [
                    _buildInfoRow(context.l10n.profInfoMaxChars,
                        config['statuses']['max_characters']?.toString()),
                    _buildInfoRow(
                        context.l10n.profInfoMaxMedia,
                        config['statuses']['max_media_attachments']
                            ?.toString()),
                  ]),
                if (config['media_attachments'] != null)
                  _buildSection(context.l10n.profSectionMediaSettings, [
                    _buildInfoRow(
                        context.l10n.profInfoImageSizeLimit,
                        _formatBytes(
                            config['media_attachments']['image_size_limit'])),
                    _buildInfoRow(
                        context.l10n.profInfoVideoSizeLimit,
                        _formatBytes(
                            config['media_attachments']['video_size_limit'])),
                  ]),
              ],

              // 言語
              if (serverInfo['languages'] is List && (serverInfo['languages'] as List).isNotEmpty)
                _buildSection(context.l10n.profSectionLanguages, [
                  Text(
                    (serverInfo['languages'] as List).join(', '),
                    style: const TextStyle(fontSize: 14),
                  ),
                ]),

              // 連絡先
              if (serverInfo['contact_account'] != null)
                _buildSection(context.l10n.profSectionAdmin, [
                  _buildInfoRow(context.l10n.profInfoUsername,
                      '@${serverInfo['contact_account']['username']}'),
                  _buildInfoRow(context.l10n.displayNameLabel,
                      serverInfo['contact_account']['display_name']),
                ]),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.close),
        ),
      ],
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }

  Widget _buildInfoRow(String label, String? value) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 14,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  String _formatBytes(dynamic bytes) {
    if (bytes == null) return '';
    final int value = int.tryParse(bytes.toString()) ?? 0;
    if (value == 0) return '';
    
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    int i = 0;
    double size = value.toDouble();
    
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    
    return '${size.toStringAsFixed(i == 0 ? 0 : 1)} ${suffixes[i]}';
  }
}

/// 「共通のフォロワー」を全員見るためのページ。
///
/// `fetchFamiliarFollowers` の結果は **ページングが無く** 1 回の API で全件
/// 取れる仕様なので、ProfilePage 側でロード済みのリストをそのまま受け取って
/// 表示するだけ。タップで各人のプロフィールへ遷移できる。
class _FamiliarFollowersListPage extends StatelessWidget {
  final AuthAccount user;
  final List<Account> accounts;
  /// AppBar サブタイトルに「@xxx の」と出すための表示用 acct
  final String targetUsername;

  const _FamiliarFollowersListPage({
    required this.user,
    required this.accounts,
    required this.targetUsername,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.profCommonFollowers),
            if (targetUsername.isNotEmpty)
              Text(
                '@$targetUsername',
                style: const TextStyle(fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
      body: ListView.separated(
        itemCount: accounts.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final a = accounts[i];
          return ListTile(
              leading: UserAvatar(
                url: a.avatarUrl,
                radius: 20,
              ),
              title: Text(
                a.displayNameOrUsername,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text('@${a.acct}',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ProfilePage(
                      user: user,
                      targetAccountId: a.id,
                      targetUsername: a.username,
                      targetInstanceUrl: user.instanceUrl,
                    ),
                  ),
                );
              },
            );
          },
        ),
    );
  }
}

/// プロフィールの「コレクション」タブ (4.6+)。自前で fetchAccountCollections /
/// (自分なら) fetchAccountInCollections を読み込み、各行タップで詳細へ飛ぶ。
/// 自分のプロフィールでは新規作成導線を出す。外側 `_KeepAliveTab` が State を
/// 保持するので、独自の keep-alive は持たない。
class _CollectionsTab extends StatefulWidget {
  const _CollectionsTab({
    required this.user,
    required this.accountId,
    required this.isSelf,
  });

  final AuthAccount user;
  final String accountId;
  final bool isSelf;

  @override
  State<_CollectionsTab> createState() => _CollectionsTabState();
}

class _CollectionsTabState extends State<_CollectionsTab> {
  List<Collection> _created = const [];
  List<Collection> _inCollections = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final created = await fetchAccountCollections(
        instanceUrl: widget.user.instanceUrl,
        accessToken: widget.user.accessToken,
        accountId: widget.accountId,
      );
      List<Collection> inCol = const [];
      if (widget.isSelf) {
        // 掲載されているコレクション (自分のみ)。未対応や権限差で失敗しても
        // 作成済み一覧は出せるので握りつぶす。
        try {
          inCol = await fetchAccountInCollections(
            instanceUrl: widget.user.instanceUrl,
            accessToken: widget.user.accessToken,
            accountId: widget.accountId,
          );
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _created = created;
        _inCollections = inCol;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _openDetail(Collection c) {
    openDeckPage(
      context,
      (onDeckBack) => CollectionDetailPage(
        user: widget.user,
        collectionId: c.id,
        initialCollection: c,
        onDeckBack: onDeckBack,
      ),
    );
  }

  Future<void> _create() async {
    final created = await openCollectionForm(context, user: widget.user);
    if (created != null && mounted) {
      _load();
      _openDetail(created);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _created.isEmpty && _inCollections.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _created.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text(context.l10n.profCollectionsFetchFailed),
              const SizedBox(height: 4),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                  onPressed: _load, child: Text(context.l10n.retry)),
            ],
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          if (widget.isSelf)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: _create,
                  icon: const Icon(Icons.add),
                  label: Text(context.l10n.profCreateCollection),
                ),
              ),
            ),
          if (_created.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  widget.isSelf
                      ? context.l10n.profNoCollectionsOwn
                      : context.l10n.profNoCollections,
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          for (final c in _created) _buildTile(c),
          if (widget.isSelf && _inCollections.isNotEmpty) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                context.l10n.profFeaturedCollections,
                style: theme.textTheme.titleSmall,
              ),
            ),
            for (final c in _inCollections) _buildTile(c),
          ],
        ],
      ),
    );
  }

  Widget _buildTile(Collection c) {
    final subtitle = c.description.isNotEmpty
        ? context.l10n
            .profCollectionSubtitleWithDesc(c.itemCount, c.description)
        : context.l10n.profCollectionMemberCount(c.itemCount);
    return ListTile(
      leading: const Icon(Icons.collections_bookmark),
      title: Text(
        c.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => _openDetail(c),
    );
  }
}

/// 「コレクションに追加」用ボトムシート。自分の作成したコレクション一覧を出し、
/// 選択で [target] を addCollectionItem する。新規作成して追加する導線もある。
class _AddToCollectionSheet extends StatefulWidget {
  const _AddToCollectionSheet({required this.user, required this.target});

  final AuthAccount user;
  final Account target;

  @override
  State<_AddToCollectionSheet> createState() => _AddToCollectionSheetState();
}

class _AddToCollectionSheetState extends State<_AddToCollectionSheet> {
  List<Collection> _collections = const [];
  bool _loading = true;
  String? _error;
  String? _busyId; // 追加中のコレクション id

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await fetchAccountCollections(
        instanceUrl: widget.user.instanceUrl,
        accessToken: widget.user.accessToken,
        accountId: widget.user.id,
      );
      if (!mounted) return;
      setState(() {
        _collections = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _add(Collection c) async {
    if (_busyId != null) return;
    setState(() => _busyId = c.id);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await addCollectionItem(
        instanceUrl: widget.user.instanceUrl,
        accessToken: widget.user.accessToken,
        collectionId: c.id,
        accountId: widget.target.id,
      );
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.profAddedToCollection(c.name))),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyId = null);
      showErrorSnackBar(context, l10n.profAddToCollectionFailed('$e'));
    }
  }

  Future<void> _createAndAdd() async {
    final created = await openCollectionForm(context, user: widget.user);
    if (created == null || !mounted) return;
    await _add(created);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: mq.size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                context.l10n.profAddToCollection,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add),
              title: Text(context.l10n.profCreateAndAdd),
              onTap: _busyId == null ? _createAndAdd : null,
            ),
            const Divider(height: 1),
            Flexible(child: _buildList()),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(context.l10n.profCollectionsFetchFailedError('$_error'),
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: _load, child: Text(context.l10n.retry)),
          ],
        ),
      );
    }
    if (_collections.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text(context.l10n.profNoCollectionsCreateHint)),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: _collections.length,
      itemBuilder: (_, i) {
        final c = _collections[i];
        final busy = _busyId == c.id;
        return ListTile(
          leading: const Icon(Icons.collections_bookmark),
          title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(context.l10n.profCollectionMemberCount(c.itemCount)),
          trailing: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          onTap: busy ? null : () => _add(c),
        );
      },
    );
  }
}
