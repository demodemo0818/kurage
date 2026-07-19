// lib/pages/reactors_page.dart
//
// 「投稿をブースト / お気に入りした人の一覧」ページ。
// `GET /api/v1/statuses/:id/reblogged_by` と `/favourited_by` の結果を
// TabBar で 1 ページ内に並べ、無限スクロールで続きを取得する。
//
// `list_members_page.dart` のレイアウトを踏襲しつつ、reblog / fav の 2 リスト
// を持つために内部で `_ReactorList` を 2 回 mount する形にしている。
// Tab を切り替えるだけで再フェッチが走らないよう `AutomaticKeepAliveClientMixin`
// で State を保持する。

import '../widgets/network_image_x.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/account.dart';
import '../models/auth_account.dart';
import '../services/mastodon_api.dart';
import '../utils/snackbar_helpers.dart';
import '../utils/open_profile.dart';

/// 1 ページ呼び出しの形を抽象化したコールバック (テスト性は捨ててクロージャで簡潔に)。
/// 返り値は `(アカウント一覧, 次ページの max_id)`。max_id は Link ヘッダ由来の
/// サーバ内部カーソルで、Account.id とは別物 ([fetchRebloggedBy] の doc 参照)。
typedef _ReactorFetcher = Future<AccountPage> Function({String? maxId});

class ReactorsPage extends StatelessWidget {
  /// 一覧を取得する対象の投稿 id (操作アカウントから見えている id)
  final String statusId;

  /// API を叩くアカウント
  final AuthAccount account;

  /// 初期表示するタブ (0: ブースト, 1: お気に入り)
  final int initialIndex;

  /// Deck ポップアップで最初のページとして開かれた時だけ非 null。AppBar の
  /// 戻る (←) でポップアップ全体を閉じるのに使う。
  final VoidCallback? onDeckBack;

  const ReactorsPage._({
    required this.statusId,
    required this.account,
    required this.initialIndex,
    this.onDeckBack,
  });

  /// ブーストタブを最初に開く
  factory ReactorsPage.reblog({
    Key? key,
    required String statusId,
    required AuthAccount account,
    VoidCallback? onDeckBack,
  }) =>
      ReactorsPage._(
        statusId: statusId,
        account: account,
        initialIndex: 0,
        onDeckBack: onDeckBack,
      );

  /// お気に入りタブを最初に開く
  factory ReactorsPage.favourite({
    Key? key,
    required String statusId,
    required AuthAccount account,
    VoidCallback? onDeckBack,
  }) =>
      ReactorsPage._(
        statusId: statusId,
        account: account,
        initialIndex: 1,
        onDeckBack: onDeckBack,
      );

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: initialIndex,
      child: Scaffold(
        appBar: AppBar(
          leading:
              onDeckBack == null ? null : BackButton(onPressed: onDeckBack),
          title: Text(context.l10n.reactorsTitle),
          bottom: TabBar(
            tabs: [
              Tab(icon: const Icon(Icons.repeat), text: context.l10n.boost),
              Tab(icon: const Icon(Icons.star), text: context.l10n.favourite),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _ReactorList(
              key: const PageStorageKey('reactors-reblog'),
              account: account,
              emptyMessage: context.l10n.reactorsNoBoosts,
              fetcher: ({String? maxId}) => fetchRebloggedBy(
                instanceUrl: account.instanceUrl,
                accessToken: account.accessToken,
                statusId: statusId,
                maxId: maxId,
              ),
            ),
            _ReactorList(
              key: const PageStorageKey('reactors-fav'),
              account: account,
              emptyMessage: context.l10n.reactorsNoFavourites,
              fetcher: ({String? maxId}) => fetchFavouritedBy(
                instanceUrl: account.instanceUrl,
                accessToken: account.accessToken,
                statusId: statusId,
                maxId: maxId,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 1 リスト分の表示。reblog / fav どちらでも同じ構造なので共通化。
class _ReactorList extends StatefulWidget {
  final AuthAccount account;
  final String emptyMessage;
  final _ReactorFetcher fetcher;

  const _ReactorList({
    super.key,
    required this.account,
    required this.emptyMessage,
    required this.fetcher,
  });

  @override
  State<_ReactorList> createState() => _ReactorListState();
}

class _ReactorListState extends State<_ReactorList>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final ScrollController _scrollController = ScrollController();

  List<Account> _items = const [];
  bool _loading = false;
  bool _hasMore = true;
  String? _error;

  /// 次ページ取得用カーソル (Link ヘッダの rel="next" の max_id)。null = 末尾。
  /// Account.id ではなくサーバ内部の Reblog/Favourite レコード id なので、
  /// 末尾 Account.id を渡す旧方式だと毎回同じ先頭 40 件が返り 40 件で止まった。
  String? _nextMaxId;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadFirst();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loading || !_hasMore) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadFirst() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (fetched, next) = await widget.fetcher();
      if (!mounted) return;
      setState(() {
        _items = fetched;
        _loading = false;
        _nextMaxId = next;
        _hasMore = next != null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_nextMaxId == null) return;
    setState(() => _loading = true);
    try {
      final (fetched, next) = await widget.fetcher(maxId: _nextMaxId);
      if (!mounted) return;
      setState(() {
        // 重複は API 仕様上は出ないはずだが、サーバ実装差異を考慮して念のため弾く。
        final knownIds = _items.map((a) => a.id).toSet();
        final newOnes = fetched.where((a) => !knownIds.contains(a.id)).toList();
        _items = [..._items, ...newOnes];
        _loading = false;
        _nextMaxId = next;
        _hasMore = next != null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showErrorSnackBar(context, context.l10n.loadMoreFailed('$e'));
    }
  }

  void _openProfile(Account account) {
    // 一覧は `widget.account` のインスタンスから返ってきているので、ID も
    // `targetInstanceUrl` も同じインスタンスを渡せばよい。
    openProfile(
      context,
      user: widget.account,
      targetAccountId: account.id,
      targetUsername: account.username,
      targetInstanceUrl: widget.account.instanceUrl,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin の都合
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text(context.l10n.reactorsFetchFailed),
              const SizedBox(height: 4),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadFirst,
                child: Text(context.l10n.retry),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      // 空 + RefreshIndicator を効かせるため ListView でラップ。
      return RefreshIndicator(
        onRefresh: _loadFirst,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    widget.emptyMessage,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadFirst,
      child: ListView.separated(
        controller: _scrollController,
        itemCount: _items.length + (_hasMore ? 1 : 0),
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          if (i >= _items.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final a = _items[i];
          return ListTile(
            leading: KurageCircleAvatar(imageUrl: a.avatar),
            title: Text(
              a.displayNameOrUsername,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '@${a.acct}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _openProfile(a),
          );
        },
      ),
    );
  }
}
