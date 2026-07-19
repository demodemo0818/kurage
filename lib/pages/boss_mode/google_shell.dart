// lib/pages/boss_mode/google_shell.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../models/auth_account.dart';
import '../../models/status.dart';
import '../../providers/auth_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/mastodon_api.dart';
import '../../utils/html_parser.dart';
import 'google_result_tile.dart';
import 'google_search_box.dart';
import 'google_wordmark.dart';

/// ボスキー (偽装モード) の本体。
///
/// 見た目は Google 検索結果ページそっくりだが、中身は本物の Kurage。ホーム
/// タイムラインを検索結果風に表示してスクロール閲覧でき、上部の「検索窓」から
/// 投稿(toot)、各結果からふぁぼ/ブースト/返信ができる。データ層 (API) は
/// 既存のものをそのまま再利用する。
///
/// アプリのダークテーマが透けないよう、ローカルの白ライト Theme でラップする。
class GoogleShell extends ConsumerStatefulWidget {
  const GoogleShell({super.key});

  @override
  ConsumerState<GoogleShell> createState() => _GoogleShellState();
}

class _GoogleShellState extends ConsumerState<GoogleShell> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final GlobalKey<ScaffoldMessengerState> _messengerKey = GlobalKey();

  final List<Status> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _posting = false;
  bool _refreshing = false;
  String? _error;

  // 投稿の公開範囲 ('public' / 'unlisted' / 'private' / 'direct')。
  String _visibility = 'public';

  // 表示中のタイムライン種別。fetchTimelineForAccount の timelineType に渡す。
  // 'home' / 'local' / 'public'(=連合)。
  String _timelineType = 'home';

  // 表示中タブの選択肢 (value, ラベル)。ラベルは表示言語依存なので getter。
  static List<(String, String)> get _timelineTabs => [
        ('home', l10n.timelineHome),
        ('local', l10n.timelineLocal),
        ('public', l10n.timelineFederated),
      ];

  // 楽観更新の上書き (id → 状態)。サーバ反映前の即時反転に使う。
  final Map<String, bool> _favOverride = {};
  final Map<String, bool> _reblogOverride = {};
  final Map<String, bool> _bookmarkOverride = {};

  // 返信中の対象。
  String? _replyTargetId;
  String? _replyTargetLabel;

  // 使用中アカウント ID。実行中だけのランタイム state (永続化しない)。F9 で
  // 偽装モードに入るたびに GoogleShell が作り直され null に戻るので、毎回まず
  // `accounts.first` の TL を即座に取りに行く。別アカウントを見たいときだけ
  // ユーザーがアバターメニューで切り替える。null や invalid の間は first。
  String? _selectedAccountId;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // 実装前と同じく即座に初回取得 (prefs 読みを挟まない)。既定は first。
    _fetchInitial();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// `_selectedAccountId` を解決して該当 AuthAccount を返す。null や invalid
  /// なら `accounts.first`。アカウント 0 件のときは null。
  AuthAccount? get _account {
    final accs = ref.read(authProvider).accounts;
    if (accs.isEmpty) return null;
    if (_selectedAccountId != null) {
      for (final a in accs) {
        if (a.id == _selectedAccountId) return a;
      }
    }
    return accs.first;
  }

  /// アカウント切替。表示を全クリアして選択アカウントで再取得する。
  /// (タイムライン種別はそのまま維持する。)
  void _switchAccount(String id) {
    if (id == _account?.id) return;
    setState(() {
      _selectedAccountId = id;
      _items.clear();
      _favOverride.clear();
      _reblogOverride.clear();
      _bookmarkOverride.clear();
      _replyTargetId = null;
      _replyTargetLabel = null;
      _searchCtrl.clear();
      _loading = true;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _fetchInitial();
  }

  /// タブ切替。表示中タイムラインを変えて再取得する。
  void _switchTimeline(String type) {
    if (type == _timelineType) return;
    setState(() {
      _timelineType = type;
      _items.clear();
      _favOverride.clear();
      _reblogOverride.clear();
      _bookmarkOverride.clear();
      _loading = true;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _fetchInitial();
  }

  Future<void> _fetchInitial() async {
    final acct = _account;
    if (acct == null) {
      setState(() {
        _loading = false;
        _items.clear();
      });
      return;
    }
    // 取得後にタブ or アカウントが変わっていたら結果を破棄するため捕捉。
    final type = _timelineType;
    final acctId = acct.id;
    try {
      final list = await fetchTimelineForAccount(
        instanceUrl: acct.instanceUrl,
        accessToken: acct.accessToken,
        accountId: acct.id,
        timelineType: type,
        limit: 40,
      );
      if (!mounted || type != _timelineType || acctId != _account?.id) return;
      setState(() {
        _items
          ..clear()
          ..addAll(list);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || type != _timelineType || acctId != _account?.id) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _refresh() async {
    final acct = _account;
    if (acct == null) return;
    final type = _timelineType;
    final acctId = acct.id;
    try {
      final list = await fetchTimelineForAccount(
        instanceUrl: acct.instanceUrl,
        accessToken: acct.accessToken,
        accountId: acct.id,
        timelineType: type,
        limit: 40,
      );
      if (!mounted || type != _timelineType || acctId != _account?.id) return;
      setState(() {
        _items
          ..clear()
          ..addAll(list);
        // サーバの最新状態で上書きされるので楽観オーバーライドは破棄。
        _favOverride.clear();
        _reblogOverride.clear();
        _bookmarkOverride.clear();
        _error = null;
      });
    } catch (_) {
      // 引っ張って更新の失敗は黙殺 (既存表示を保つ)。
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _items.isEmpty) return;
    final acct = _account;
    if (acct == null) return;
    final type = _timelineType;
    final acctId = acct.id;
    setState(() => _loadingMore = true);
    try {
      final list = await fetchTimelineForAccount(
        instanceUrl: acct.instanceUrl,
        accessToken: acct.accessToken,
        accountId: acct.id,
        timelineType: type,
        maxId: _items.last.id,
        limit: 40,
      );
      if (!mounted || type != _timelineType || acctId != _account?.id) return;
      final existing = _items.map((e) => e.id).toSet();
      setState(() {
        _items.addAll(list.where((s) => !existing.contains(s.id)));
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  Future<void> _submit(String raw) async {
    final text = raw.trim();
    if (text.isEmpty || _posting) return;
    final acct = _account;
    if (acct == null) {
      _toast(l10n.bossNoAccounts);
      return;
    }
    setState(() => _posting = true);
    try {
      final posted = await postStatus(
        instanceUrl: acct.instanceUrl,
        accessToken: acct.accessToken,
        statusText: text,
        visibility: _visibility,
        language: ref.read(settingsProvider).defaultPostLanguage,
        inReplyToId: _replyTargetId,
      );
      if (!mounted) return;
      setState(() {
        _searchCtrl.clear();
        _replyTargetId = null;
        _replyTargetLabel = null;
        _posting = false;
        // 投稿を即座に先頭へ反映 (検索結果に自分の投稿が出たように見える)。
        _items.insert(0, posted);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _posting = false);
      _toast(l10n.bossPostFailed);
    }
  }

  Future<void> _toggleFav(Status d) async {
    final acct = _account;
    if (acct == null) return;
    final current = _favOverride[d.id] ?? d.favourited;
    setState(() => _favOverride[d.id] = !current);
    try {
      await toggleFavourite(
        instanceUrl: acct.instanceUrl,
        accessToken: acct.accessToken,
        statusId: d.id,
        currentlyFavourited: current,
      );
    } catch (_) {
      if (mounted) setState(() => _favOverride[d.id] = current);
    }
  }

  Future<void> _toggleReblog(Status d) async {
    final acct = _account;
    if (acct == null) return;
    final current = _reblogOverride[d.id] ?? d.reblogged;
    setState(() => _reblogOverride[d.id] = !current);
    try {
      await toggleReblog(
        instanceUrl: acct.instanceUrl,
        accessToken: acct.accessToken,
        statusId: d.id,
        currentlyReblogged: current,
      );
    } catch (_) {
      if (mounted) setState(() => _reblogOverride[d.id] = current);
    }
  }

  Future<void> _toggleBookmark(Status d) async {
    final acct = _account;
    if (acct == null) return;
    final current = _bookmarkOverride[d.id] ?? d.bookmarked;
    setState(() => _bookmarkOverride[d.id] = !current);
    try {
      await toggleBookmark(
        instanceUrl: acct.instanceUrl,
        accessToken: acct.accessToken,
        statusId: d.id,
        currentlyBookmarked: current,
      );
    } catch (_) {
      if (mounted) setState(() => _bookmarkOverride[d.id] = current);
    }
  }

  Future<void> _manualRefresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    await _refresh();
    if (mounted) setState(() => _refreshing = false);
  }

  void _startReply(Status d) {
    final handle = '@${d.account.acct}';
    setState(() {
      _replyTargetId = d.id;
      _replyTargetLabel = handle;
      _searchCtrl.text = '$handle ';
      _searchCtrl.selection =
          TextSelection.collapsed(offset: _searchCtrl.text.length);
    });
    _searchFocus.requestFocus();
  }

  void _cancelReply() {
    setState(() {
      _replyTargetId = null;
      _replyTargetLabel = null;
    });
  }

  void _toast(String message) {
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: Colors.white,
      fontFamily: 'Arial',
      fontFamilyFallback: const ['Helvetica', 'Roboto', 'sans-serif'],
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF4285F4),
        brightness: Brightness.light,
      ),
    );

    return Theme(
      data: theme,
      // F9 でのみ解除する想定。ブラウザ/OS の戻るで誤って抜けないよう塞ぐ。
      child: PopScope(
        canPop: false,
        child: ScaffoldMessenger(
          key: _messengerKey,
          child: Scaffold(
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(),
                      _tabBar(),
                      const Divider(height: 1, color: Color(0xFFEBEBEB)),
                      Expanded(child: _body()),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Google の検索カテゴリタブ風のタイムライン切替バー。
  Widget _tabBar() {
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final t in _timelineTabs) _tabItem(t.$1, t.$2),
        ],
      ),
    );
  }

  Widget _tabItem(String type, String label) {
    final active = _timelineType == type;
    const blue = Color(0xFF1A73E8);
    return InkWell(
      onTap: () => _switchTimeline(type),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? blue : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? blue : const Color(0xFF5F6368),
            fontSize: 14,
            fontWeight: active ? FontWeight.w500 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final acct = _account;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Row(
        children: [
          const GoogleWordmark(fontSize: 26),
          const SizedBox(width: 16),
          Expanded(
            child: GoogleSearchBox(
              controller: _searchCtrl,
              focusNode: _searchFocus,
              autofocus: true,
              replyingToLabel: _replyTargetLabel,
              onCancelReply: _cancelReply,
              onSubmit: _submit,
              visibility: _visibility,
              onVisibilityChanged: (v) => setState(() => _visibility = v),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: context.l10n.refresh,
            onPressed: _refreshing ? null : _manualRefresh,
            icon: _refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, color: Color(0xFF5F6368)),
          ),
          if (acct != null) ...[
            const SizedBox(width: 6),
            _accountSwitcher(acct),
          ],
        ],
      ),
    );
  }

  /// 右上のアバター。Google の「アカウント切替」よろしくタップでアカウント
  /// 一覧メニューを開く。アカウントが 1 つだけならメニュー無しのアバターのみ。
  Widget _accountSwitcher(AuthAccount current) {
    final accounts = ref.read(authProvider).accounts;
    final avatar = CircleAvatar(
      radius: 16,
      backgroundColor: const Color(0xFFE8EAED),
      foregroundImage:
          current.avatarUrl.isEmpty ? null : NetworkImage(current.avatarUrl),
      onForegroundImageError: (_, _) {},
      child: const Icon(Icons.person, size: 18, color: Color(0xFF5F6368)),
    );
    if (accounts.length < 2) return avatar;
    // PopupMenuButton はこの widget (= GoogleShell のローカル白 Theme 配下) の
    // Theme を showMenu に渡すため、メニューも自動で白テーマになる。
    return PopupMenuButton<String>(
      tooltip: l10n.account,
      offset: const Offset(0, 44),
      initialValue: current.id,
      onSelected: _switchAccount,
      itemBuilder: (context) => [
        for (final a in accounts)
          PopupMenuItem<String>(
            value: a.id,
            child: _accountMenuRow(a, a.id == current.id),
          ),
      ],
      child: avatar,
    );
  }

  Widget _accountMenuRow(AuthAccount a, bool selected) {
    return Row(
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: const Color(0xFFE8EAED),
          foregroundImage:
              a.avatarUrl.isEmpty ? null : NetworkImage(a.avatarUrl),
          onForegroundImageError: (_, _) {},
          child: const Icon(Icons.person, size: 16, color: Color(0xFF5F6368)),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                a.displayName.isEmpty ? a.username : a.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFF202124), fontSize: 14),
              ),
              Text(
                '@${a.username}@${a.host}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFF5F6368), fontSize: 12),
              ),
            ],
          ),
        ),
        if (selected) ...[
          const SizedBox(width: 12),
          const Icon(Icons.check, size: 18, color: Color(0xFF1A73E8)),
        ],
      ],
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_account == null) {
      return Center(
        child: Text(
          l10n.bossNotLoggedIn,
          style: const TextStyle(color: Color(0xFF5F6368)),
        ),
      );
    }
    if (_items.isEmpty && _error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.bossSearchFailed,
                style: const TextStyle(color: Color(0xFF5F6368))),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () {
                setState(() => _loading = true);
                _fetchInitial();
              },
              child: Text(l10n.retry),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        itemCount: _items.length + 2,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                l10n.bossAboutNResults(_items.length),
                style: const TextStyle(color: Color(0xFF70757A), fontSize: 13),
              ),
            );
          }
          if (index == _items.length + 1) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: _loadingMore
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const SizedBox.shrink(),
              ),
            );
          }
          return _buildTile(_items[index - 1]);
        },
      ),
    );
  }

  Widget _buildTile(Status item) {
    final d = item.reblog ?? item;
    final fav = _favOverride[d.id] ?? d.favourited;
    final reblogged = _reblogOverride[d.id] ?? d.reblogged;
    final bookmarked = _bookmarkOverride[d.id] ?? d.bookmarked;
    final favCount =
        d.favouritesCount + (fav == d.favourited ? 0 : (fav ? 1 : -1));
    final reblogCount = d.reblogsCount +
        (reblogged == d.reblogged ? 0 : (reblogged ? 1 : -1));

    return GoogleResultTile(
      urlLine: _urlLine(d),
      title: d.account.displayNameOrUsername,
      snippet: _snippet(d),
      favourited: fav,
      reblogged: reblogged,
      bookmarked: bookmarked,
      favCount: favCount,
      reblogCount: reblogCount,
      onFavourite: () => _toggleFav(d),
      onReblog: () => _toggleReblog(d),
      onBookmark: () => _toggleBookmark(d),
      onReply: () => _startReply(d),
    );
  }

  String _urlLine(Status d) {
    String host = '';
    final url = d.url ?? d.uri;
    if (url != null) {
      host = Uri.tryParse(url)?.host ?? '';
    }
    if (host.isEmpty) {
      // acct が "user@domain" ならドメインを拾う。
      final parts = d.account.acct.split('@');
      if (parts.length == 2) host = parts[1];
    }
    final handle = '@${d.account.acct}';
    return host.isEmpty ? handle : '$host › $handle';
  }

  String _snippet(Status d) {
    final date = d.createdAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final prefix = '${date.year}/${two(date.month)}/${two(date.day)}';
    final plain = parseHtmlToPlainText(d.content).replaceAll('\n', ' ').trim();
    return plain.isEmpty ? prefix : '$prefix — $plain';
  }
}
