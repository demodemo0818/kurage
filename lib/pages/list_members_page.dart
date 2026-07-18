// lib/pages/list_members_page.dart
//
// 1 つのリストに含まれているメンバーを表示し、リストから外したり、
// メンバーのプロフィールに飛んだりできるページ。

import 'package:flutter/material.dart';
import '../widgets/network_image_x.dart';

import '../models/account.dart';
import '../models/auth_account.dart';
import '../models/mastodon_list.dart';
import '../services/mastodon_api.dart';
import '../utils/snackbar_helpers.dart';
import '../utils/open_profile.dart';

class ListMembersPage extends StatefulWidget {
  const ListMembersPage({
    super.key,
    required this.auth,
    required this.list,
  });

  final AuthAccount auth;
  final MastodonList list;

  @override
  State<ListMembersPage> createState() => _ListMembersPageState();
}

class _ListMembersPageState extends State<ListMembersPage> {
  final ScrollController _scrollController = ScrollController();

  List<Account> _members = const [];
  bool _loading = false;
  bool _hasMore = true;
  String? _error;

  /// 削除中のアカウント (重複タップ防止 + 個別 ProgressIndicator 表示)
  final Set<String> _busyIds = {};

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
    // 末尾近くまでスクロールしたら次ページを取りに行く。
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
      final fetched = await fetchListAccounts(
        instanceUrl: widget.auth.instanceUrl,
        accessToken: widget.auth.accessToken,
        listId: widget.list.id,
      );
      if (!mounted) return;
      setState(() {
        _members = fetched;
        _loading = false;
        _hasMore = fetched.length >= 40; // limit 既定値
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
    if (_members.isEmpty) return;
    setState(() => _loading = true);
    try {
      final fetched = await fetchListAccounts(
        instanceUrl: widget.auth.instanceUrl,
        accessToken: widget.auth.accessToken,
        listId: widget.list.id,
        maxId: _members.last.id,
      );
      if (!mounted) return;
      setState(() {
        _members = [..._members, ...fetched];
        _loading = false;
        _hasMore = fetched.length >= 40;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
      showErrorSnackBar(context, '続きを取得できませんでした: $e');
    }
  }

  Future<void> _removeMember(Account member) async {
    if (_busyIds.contains(member.id)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('リストから削除'),
        content: Text('「${widget.list.title}」から @${member.acct} を外します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busyIds.add(member.id));
    try {
      await removeAccountsFromList(
        instanceUrl: widget.auth.instanceUrl,
        accessToken: widget.auth.accessToken,
        listId: widget.list.id,
        accountIds: [member.id],
      );
      if (!mounted) return;
      setState(() {
        _members = _members.where((m) => m.id != member.id).toList();
      });
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, 'リストから外せませんでした: $e');
    } finally {
      if (mounted) {
        setState(() => _busyIds.remove(member.id));
      }
    }
  }

  void _openProfile(Account account) {
    // メンバーは `auth` のインスタンスから返ってきているので、ID もこのインスタンス
    // 上のもの。`targetInstanceUrl` も同じインスタンスを渡す。
    openProfile(
      context,
      user: widget.auth,
      targetAccountId: account.id,
      targetUsername: account.username,
      targetInstanceUrl: widget.auth.instanceUrl,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('リストのメンバー'),
            Text(
              widget.list.title,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _members.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _members.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text('メンバーを取得できませんでした'),
              const SizedBox(height: 4),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadFirst,
                child: const Text('再試行'),
              ),
            ],
          ),
        ),
      );
    }
    if (_members.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.person_off_outlined,
                size: 56,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              const Text('メンバーがいません'),
              const SizedBox(height: 4),
              const Text(
                'プロフィールページや投稿のメニューから\nリストに追加できます',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadFirst,
      child: ListView.separated(
        controller: _scrollController,
        itemCount: _members.length + (_hasMore ? 1 : 0),
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          if (i >= _members.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final m = _members[i];
          final busy = _busyIds.contains(m.id);
          return ListTile(
            leading: KurageCircleAvatar(imageUrl: m.avatar),
            title: Text(
              m.displayName.isNotEmpty ? m.displayName : m.username,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '@${m.acct}',
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
                    icon: const Icon(Icons.remove_circle_outline),
                    color: Colors.red,
                    tooltip: 'リストから削除',
                    onPressed: () => _removeMember(m),
                  ),
            onTap: () => _openProfile(m),
          );
        },
      ),
    );
  }
}
