// lib/pages/collection_detail_page.dart
//
// Mastodon 4.6+ の Collection (公開キュレーション・アカウントリスト) 1 件の
// 詳細画面。メンバー (CollectionItem) 一覧を表示し、
//  - 所有者: メンバー削除 / コレクション編集・削除
//  - 掲載された本人 (pending): 承認 / 掲載拒否(revoke)
// を行える。
//
// CollectionItem は account_id しか持たないので、メンバー描画用のアカウントは
// fetchAccountsByIds でまとめて解決する (実機検証ゲート #2: items[] が account を
// 内包していれば将来そちらを使う最適化も可能だが、id 解決なら構造に依存せず動く)。

import 'package:flutter/material.dart';

import '../models/account.dart';
import '../models/auth_account.dart';
import '../models/collection.dart';
import '../services/mastodon_api.dart';
import '../utils/open_profile.dart';
import '../utils/snackbar_helpers.dart';
import '../widgets/network_image_x.dart';
import 'collection_form_page.dart';

class CollectionDetailPage extends StatefulWidget {
  const CollectionDetailPage({
    super.key,
    required this.user,
    required this.collectionId,
    this.initialCollection,
    this.onDeckBack,
  });

  /// 操作に使うログイン中アカウント。
  final AuthAccount user;
  final String collectionId;

  /// 一覧から渡せる場合の初期表示用 (fetch 完了までの仮表示。items は空のことあり)。
  final Collection? initialCollection;

  /// Deck ポップアップの最初のページとして開かれた時だけ非 null (戻る ← 用)。
  final VoidCallback? onDeckBack;

  @override
  State<CollectionDetailPage> createState() => _CollectionDetailPageState();
}

class _CollectionDetailPageState extends State<CollectionDetailPage> {
  Collection? _collection;
  final Map<String, Account> _accounts = {}; // accountId -> Account
  bool _loading = true;
  String? _error;

  /// 操作中の item id (重複タップ防止 + 個別スピナー)。
  final Set<String> _busyItemIds = {};

  @override
  void initState() {
    super.initState();
    _collection = widget.initialCollection;
    _load();
  }

  bool get _isOwner => _collection?.accountId == widget.user.id;

  /// 自分自身のメンバー項目 (掲載されている本人としての承認/拒否に使う)。
  CollectionItem? get _myItem {
    final items = _collection?.items ?? const <CollectionItem>[];
    for (final item in items) {
      if (item.accountId == widget.user.id) return item;
    }
    return null;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await fetchCollection(
        instanceUrl: widget.user.instanceUrl,
        accessToken: widget.user.accessToken,
        collectionId: widget.collectionId,
      );
      final collection = result.collection;
      // 詳細レスポンスにメンバーの Account が同梱される (`accounts`)。
      var resolved = {for (final a in result.accounts) a.id: a};
      // 万一同梱が空で items だけあるサーバ向けに、バッチ取得でフォールバック。
      final missing =
          collection.items.where((e) => !resolved.containsKey(e.accountId));
      if (missing.isNotEmpty) {
        try {
          final accounts = await fetchAccountsByIds(
            instanceUrl: widget.user.instanceUrl,
            accessToken: widget.user.accessToken,
            accountIds: missing.map((e) => e.accountId).toList(),
          );
          resolved = {...resolved, for (final a in accounts) a.id: a};
        } catch (_) {
          // 解決に失敗してもメンバー数は出せるので致命的にしない。
        }
      }
      if (!mounted) return;
      setState(() {
        _collection = collection;
        _accounts
          ..clear()
          ..addAll(resolved);
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

  Future<void> _editCollection() async {
    final collection = _collection;
    if (collection == null) return;
    final updated = await openCollectionForm(
      context,
      user: widget.user,
      existing: collection,
    );
    if (updated != null && mounted) {
      setState(() => _collection = updated);
      _load();
    }
  }

  Future<void> _deleteCollection() async {
    final collection = _collection;
    if (collection == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('コレクションを削除'),
        content: Text('「${collection.name}」を削除します。この操作は取り消せません。'),
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
    try {
      await deleteCollection(
        instanceUrl: widget.user.instanceUrl,
        accessToken: widget.user.accessToken,
        collectionId: collection.id,
      );
      if (!mounted) return;
      Navigator.pop(context, true); // 一覧側に削除を通知
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, 'コレクションを削除できませんでした: $e');
    }
  }

  Future<void> _removeMember(CollectionItem item) async {
    final collection = _collection;
    if (collection == null || _busyItemIds.contains(item.id)) return;
    setState(() => _busyItemIds.add(item.id));
    try {
      await removeCollectionItem(
        instanceUrl: widget.user.instanceUrl,
        accessToken: widget.user.accessToken,
        collectionId: collection.id,
        itemId: item.id,
      );
      if (!mounted) return;
      _removeItemLocally(item.id);
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, 'メンバーを削除できませんでした: $e');
    } finally {
      if (mounted) setState(() => _busyItemIds.remove(item.id));
    }
  }

  Future<void> _acceptMembership(CollectionItem item) async {
    final collection = _collection;
    if (collection == null || _busyItemIds.contains(item.id)) return;
    setState(() => _busyItemIds.add(item.id));
    try {
      await acceptCollectionItem(
        instanceUrl: widget.user.instanceUrl,
        accessToken: widget.user.accessToken,
        collectionId: collection.id,
        itemId: item.id,
      );
      if (!mounted) return;
      // 承認後は再取得して state を最新化 (accepted へ)。
      _load();
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, '承認できませんでした: $e');
    } finally {
      if (mounted) setState(() => _busyItemIds.remove(item.id));
    }
  }

  Future<void> _revokeMembership(CollectionItem item) async {
    final collection = _collection;
    if (collection == null || _busyItemIds.contains(item.id)) return;
    setState(() => _busyItemIds.add(item.id));
    try {
      await revokeCollectionItem(
        instanceUrl: widget.user.instanceUrl,
        accessToken: widget.user.accessToken,
        collectionId: collection.id,
        itemId: item.id,
      );
      if (!mounted) return;
      _removeItemLocally(item.id);
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, '掲載を取り消せませんでした: $e');
    } finally {
      if (mounted) setState(() => _busyItemIds.remove(item.id));
    }
  }

  /// ローカルの items から 1 件外して再描画 (再 fetch せず即時反映)。
  void _removeItemLocally(String itemId) {
    final collection = _collection;
    if (collection == null) return;
    final newItems =
        collection.items.where((e) => e.id != itemId).toList();
    setState(() {
      _collection = Collection(
        id: collection.id,
        accountId: collection.accountId,
        uri: collection.uri,
        url: collection.url,
        name: collection.name,
        description: collection.description,
        language: collection.language,
        local: collection.local,
        sensitive: collection.sensitive,
        discoverable: collection.discoverable,
        tag: collection.tag,
        itemCount: newItems.length,
        items: newItems,
        createdAt: collection.createdAt,
        updatedAt: collection.updatedAt,
      );
    });
  }

  void _openMemberProfile(Account account) {
    openProfile(
      context,
      user: widget.user,
      targetAccountId: account.id,
      targetUsername: account.username,
      targetInstanceUrl: widget.user.instanceUrl,
    );
  }

  @override
  Widget build(BuildContext context) {
    final collection = _collection;
    return Scaffold(
      appBar: AppBar(
        leading: widget.onDeckBack == null
            ? null
            : BackButton(onPressed: widget.onDeckBack),
        title: Text(collection?.name.isNotEmpty == true
            ? collection!.name
            : 'コレクション'),
        actions: [
          if (_isOwner)
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'edit') _editCollection();
                if (value == 'delete') _deleteCollection();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'edit',
                  child: ListTile(
                    leading: Icon(Icons.edit),
                    title: Text('編集'),
                    dense: true,
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    leading: Icon(Icons.delete, color: Colors.red),
                    title: Text('削除', style: TextStyle(color: Colors.red)),
                    dense: true,
                  ),
                ),
              ],
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _collection == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _collection == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              const Text('コレクションを取得できませんでした'),
              const SizedBox(height: 4),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _load, child: const Text('再試行')),
            ],
          ),
        ),
      );
    }
    final collection = _collection;
    if (collection == null) return const SizedBox.shrink();

    final items = collection.items;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: 1 + items.length,
        separatorBuilder: (_, i) =>
            i == 0 ? const SizedBox.shrink() : const Divider(height: 1),
        itemBuilder: (_, i) {
          if (i == 0) return _buildHeader(collection);
          return _buildMemberTile(collection, items[i - 1]);
        },
      ),
    );
  }

  Widget _buildHeader(Collection collection) {
    final theme = Theme.of(context);
    final myItem = _myItem;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (collection.description.isNotEmpty) ...[
            Text(collection.description, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Chip(
                avatar: const Icon(Icons.people_outline, size: 18),
                label: Text('${collection.itemCount} 人'),
                visualDensity: VisualDensity.compact,
              ),
              if (collection.tag != null)
                Chip(
                  avatar: const Icon(Icons.tag, size: 18),
                  label: Text(collection.tag!.name),
                  visualDensity: VisualDensity.compact,
                ),
              if (collection.sensitive)
                const Chip(
                  avatar: Icon(Icons.warning_amber, size: 18),
                  label: Text('閲覧注意'),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          // 自分がこのコレクションに掲載されていて承認待ちなら、上部に承認/拒否。
          if (myItem != null && myItem.isPending) ...[
            const SizedBox(height: 12),
            Card(
              color: theme.colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('あなたはこのコレクションに追加されています。掲載を承認しますか？'),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: _busyItemIds.contains(myItem.id)
                              ? null
                              : () => _revokeMembership(myItem),
                          style:
                              TextButton.styleFrom(foregroundColor: Colors.red),
                          child: const Text('掲載しない'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _busyItemIds.contains(myItem.id)
                              ? null
                              : () => _acceptMembership(myItem),
                          child: const Text('承認する'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (collection.items.isEmpty) ...[
            const SizedBox(height: 24),
            Center(
              child: Text(
                'メンバーがいません',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMemberTile(Collection collection, CollectionItem item) {
    final account = _accounts[item.accountId];
    final busy = _busyItemIds.contains(item.id);
    final isMe = item.accountId == widget.user.id;

    Widget? trailing;
    if (busy) {
      trailing = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (_isOwner) {
      trailing = IconButton(
        icon: const Icon(Icons.remove_circle_outline),
        color: Colors.red,
        tooltip: 'メンバーから削除',
        onPressed: () => _removeMember(item),
      );
    } else if (isMe && item.isPending) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.check_circle_outline),
            color: Colors.green,
            tooltip: '承認',
            onPressed: () => _acceptMembership(item),
          ),
          IconButton(
            icon: const Icon(Icons.cancel_outlined),
            color: Colors.red,
            tooltip: '掲載しない',
            onPressed: () => _revokeMembership(item),
          ),
        ],
      );
    }

    final pendingBadge = item.isPending
        ? Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '承認待ち',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.tertiary,
              ),
            ),
          )
        : null;

    if (account == null) {
      // アカウント解決に失敗した場合の最小表示。
      return ListTile(
        leading: const CircleAvatar(child: Icon(Icons.person_outline)),
        title: Text('アカウント (${item.accountId})'),
        subtitle: pendingBadge,
        trailing: trailing,
      );
    }

    return ListTile(
      leading: KurageCircleAvatar(imageUrl: account.avatar),
      title: Text(
        account.displayNameOrUsername,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('@${account.acct}',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          if (pendingBadge != null) pendingBadge,
        ],
      ),
      trailing: trailing,
      onTap: () => _openMemberProfile(account),
    );
  }
}
