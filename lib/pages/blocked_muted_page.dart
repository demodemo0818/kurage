// lib/pages/blocked_muted_page.dart
//
// ミュート済み / ブロック済みユーザーと、ブロック済みドメインの一覧確認・
// 管理画面。タイムラインやプロフィールから個別にミュート/ブロックはできるが、
// 後から一覧で見て解除する導線が無かったため追加したもの。
//
// レイアウトは `reactors_page.dart`(無限スクロール一覧) + `search_page.dart`
// (AppBar のアカウント選択ドロップダウン) + `list_members_page.dart`
// (trailing の解除ボタン) を合成している。
//
// 重要: ミュート/ブロック一覧 (`/api/v1/mutes` `/api/v1/blocks`) のページング
// カーソルは Account.id ではなくサーバ内部の関係 ID。`mastodon_api.dart` の
// `fetchMutedAccounts` / `fetchBlockedAccounts` が Link ヘッダから次ページの
// max_id を返すので、ここではそれを `_nextMaxId` として引き継いで使う
// (`_items.last.id` を max_id に使ってはいけない)。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../models/account.dart';
import '../models/auth_account.dart';
import '../providers/auth_provider.dart';
import '../services/mastodon_api.dart';
import '../utils/open_profile.dart';
import '../utils/snackbar_helpers.dart';
import '../widgets/network_image_x.dart';
import '../widgets/user_avatar.dart';

/// アカウント一覧タブの種別。
enum _ModerationKind { mute, block }

/// 解除の確認ダイアログ。実行ボタンは destructive のとき赤
/// (`profile_page.dart` の `_toggleBlock` と見た目を揃える)。
Future<bool> _confirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(ctx.l10n.cancel),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: destructive
              ? ElevatedButton.styleFrom(backgroundColor: Colors.red)
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result == true;
}

class BlockedMutedPage extends ConsumerStatefulWidget {
  const BlockedMutedPage({super.key});

  @override
  ConsumerState<BlockedMutedPage> createState() => _BlockedMutedPageState();
}

class _BlockedMutedPageState extends ConsumerState<BlockedMutedPage> {
  /// 「current アカウント」概念廃止に伴い、どのアカウントの一覧を見ているかは
  /// このページのローカル state として持ち SharedPreferences で永続化する。
  static const _prefsKey = 'moderation_last_account_id';
  String? _accountId;

  /// `_accountId` を解決して該当 AuthAccount を返す。null や invalid なら
  /// `accounts.first` にフォールバック。アカウント 0 件なら null。
  AuthAccount? get _account {
    final accounts = ref.read(authProvider).accounts;
    if (accounts.isEmpty) return null;
    if (_accountId != null) {
      for (final a in accounts) {
        if (a.id == _accountId) return a;
      }
    }
    return accounts.first;
  }

  @override
  void initState() {
    super.initState();
    _restoreAccount();
  }

  Future<void> _restoreAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    if (saved != null && mounted) {
      setState(() => _accountId = saved);
    }
  }

  Future<void> _persistAccount(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, accountId);
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final account = _account;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(context.l10n.settingsBlockedMuted),
          actions: [
            // 複数アカウントのときだけ「どのアカウントの一覧か」を選べる
            // (search_page と同じ見た目)。
            if (authState.accounts.length > 1)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: account?.id,
                    icon: const Icon(Icons.keyboard_arrow_down),
                    items: authState.accounts.map((acc) {
                      return DropdownMenuItem<String>(
                        value: acc.id,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            UserAvatar(url: acc.avatarUrl, radius: 12),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: acc.displayName,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    TextSpan(
                                      text: '  @${acc.username}',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (id) {
                      if (id != null) {
                        // ValueKey に account.id を含めているので、ここで
                        // setState すれば子リストは State ごと作り直されて
                        // 切替先アカウントの一覧を再取得する。
                        setState(() => _accountId = id);
                        _persistAccount(id);
                      }
                    },
                  ),
                ),
              ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(
                  icon: const Icon(Icons.volume_off),
                  text: context.l10n.tabMutes),
              Tab(icon: const Icon(Icons.block), text: context.l10n.tabBlocks),
              Tab(icon: const Icon(Icons.dns), text: context.l10n.tabDomains),
            ],
          ),
        ),
        body: account == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(context.l10n.noLoggedInAccounts),
                ),
              )
            : TabBarView(
                children: [
                  _AccountModerationList(
                    key: ValueKey('mutes-${account.id}'),
                    account: account,
                    kind: _ModerationKind.mute,
                  ),
                  _AccountModerationList(
                    key: ValueKey('blocks-${account.id}'),
                    account: account,
                    kind: _ModerationKind.block,
                  ),
                  _DomainBlockList(
                    key: ValueKey('domains-${account.id}'),
                    account: account,
                  ),
                ],
              ),
      ),
    );
  }
}

/// ミュート / ブロックいずれかのアカウント一覧 (Link ヘッダ方式ページング)。
class _AccountModerationList extends StatefulWidget {
  final AuthAccount account;
  final _ModerationKind kind;

  const _AccountModerationList({
    super.key,
    required this.account,
    required this.kind,
  });

  @override
  State<_AccountModerationList> createState() => _AccountModerationListState();
}

class _AccountModerationListState extends State<_AccountModerationList>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final ScrollController _scrollController = ScrollController();

  List<Account> _items = const [];
  bool _loading = false;
  bool _hasMore = true;
  String? _error;

  /// Link ヘッダから取り出した次ページのカーソル (null なら末尾)。
  String? _nextMaxId;

  /// 解除処理中のアカウント ID (多重タップ防止 + 行ごとのスピナー表示用)。
  final Set<String> _busyIds = {};

  bool get _isMute => widget.kind == _ModerationKind.mute;

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

  Future<AccountPage> _fetch({String? maxId}) {
    final a = widget.account;
    return _isMute
        ? fetchMutedAccounts(
            instanceUrl: a.instanceUrl,
            accessToken: a.accessToken,
            maxId: maxId,
          )
        : fetchBlockedAccounts(
            instanceUrl: a.instanceUrl,
            accessToken: a.accessToken,
            maxId: maxId,
          );
  }

  Future<void> _loadFirst() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (accounts, next) = await _fetch();
      if (!mounted) return;
      setState(() {
        _items = accounts;
        _nextMaxId = next;
        _hasMore = next != null;
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

  Future<void> _loadMore() async {
    if (_loading || !_hasMore || _nextMaxId == null) return;
    setState(() => _loading = true);
    try {
      final (accounts, next) = await _fetch(maxId: _nextMaxId);
      if (!mounted) return;
      setState(() {
        // サーバ実装差異を考慮して重複は念のため弾く。
        final knownIds = _items.map((a) => a.id).toSet();
        final newOnes =
            accounts.where((a) => !knownIds.contains(a.id)).toList();
        _items = [..._items, ...newOnes];
        _nextMaxId = next;
        _hasMore = next != null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showErrorSnackBar(context, context.l10n.loadMoreFailed('$e'));
    }
  }

  void _openProfile(Account account) {
    openProfile(
      context,
      user: widget.account,
      targetAccountId: account.id,
      targetUsername: account.username,
      targetInstanceUrl: widget.account.instanceUrl,
    );
  }

  Future<void> _unmoderate(Account a) async {
    final confirmed = await _confirmDialog(
      context,
      title: _isMute ? context.l10n.unmuteTitle : context.l10n.unblockTitle,
      content: _isMute
          ? context.l10n.unmuteConfirm(a.acct)
          : context.l10n.unblockConfirm(a.acct),
      confirmLabel:
          _isMute ? context.l10n.unmuteTitle : context.l10n.unblockTitle,
      destructive: !_isMute,
    );
    if (!confirmed || !mounted) return;

    setState(() => _busyIds.add(a.id));
    try {
      final acct = widget.account;
      if (_isMute) {
        await unmuteAccount(
          instanceUrl: acct.instanceUrl,
          accessToken: acct.accessToken,
          accountId: a.id,
        );
      } else {
        await unblockAccount(
          instanceUrl: acct.instanceUrl,
          accessToken: acct.accessToken,
          accountId: a.id,
        );
      }
      if (!mounted) return;
      setState(() {
        _items = _items.where((x) => x.id != a.id).toList();
        _busyIds.remove(a.id);
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(_isMute ? context.l10n.unmuted : context.l10n.unblocked),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyIds.remove(a.id));
      showErrorSnackBar(context, context.l10n.liftFailed('$e'));
    }
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
    final emptyMessage = _isMute
        ? context.l10n.noMutedUsers
        : context.l10n.noBlockedUsers;
    if (_items.isEmpty) {
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
                  child: Text(emptyMessage, textAlign: TextAlign.center),
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
          final busy = _busyIds.contains(a.id);
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
            trailing: busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    icon: Icon(_isMute ? Icons.volume_up : Icons.block),
                    color: _isMute ? null : Colors.red,
                    tooltip: _isMute
                        ? context.l10n.unmuteTitle
                        : context.l10n.unblockTitle,
                    onPressed: () => _unmoderate(a),
                  ),
            onTap: () => _openProfile(a),
          );
        },
      ),
    );
  }
}

/// ブロック済みドメインの一覧。Mastodon の `/api/v1/domain_blocks` は
/// ページングが無く `List<String>` を一括返却するので単純な一覧で良い。
class _DomainBlockList extends StatefulWidget {
  final AuthAccount account;

  const _DomainBlockList({super.key, required this.account});

  @override
  State<_DomainBlockList> createState() => _DomainBlockListState();
}

class _DomainBlockListState extends State<_DomainBlockList>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  List<String> _domains = const [];
  bool _loading = false;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _loadFirst();
  }

  Future<void> _loadFirst() async {
    setState(() => _loading = true);
    // fetchBlockedDomains は失敗時に [] を返す (例外を投げない)。
    final domains = await fetchBlockedDomains(
      instanceUrl: widget.account.instanceUrl,
      accessToken: widget.account.accessToken,
    );
    if (!mounted) return;
    setState(() {
      _domains = domains;
      _loading = false;
    });
  }

  Future<void> _unblock(String domain) async {
    final confirmed = await _confirmDialog(
      context,
      title: context.l10n.domainUnblockTitle,
      content: context.l10n.domainUnblockConfirm(domain),
      confirmLabel: context.l10n.unblockTitle,
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy.add(domain));
    try {
      await unblockDomain(
        instanceUrl: widget.account.instanceUrl,
        accessToken: widget.account.accessToken,
        domain: domain,
      );
      if (!mounted) return;
      setState(() {
        _domains = _domains.where((d) => d != domain).toList();
        _busy.remove(domain);
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.domainUnblocked)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy.remove(domain));
      showErrorSnackBar(context, context.l10n.liftFailed('$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin の都合

    if (_loading && _domains.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_domains.isEmpty) {
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
                    context.l10n.noBlockedDomains,
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
        itemCount: _domains.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final domain = _domains[i];
          final busy = _busy.contains(domain);
          return ListTile(
            leading: const Icon(Icons.dns),
            title: Text(
              domain,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    icon: const Icon(Icons.block),
                    color: Colors.red,
                    tooltip: context.l10n.unblockTitle,
                    onPressed: () => _unblock(domain),
                  ),
          );
        },
      ),
    );
  }
}
