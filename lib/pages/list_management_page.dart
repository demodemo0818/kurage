// lib/pages/list_management_page.dart
//
// リスト管理ページ。アカウントごとのリスト一覧を表示し、新規作成 / 名前変更 /
// 削除 / メンバー閲覧へのナビゲーションを提供する。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/auth_account.dart';
import '../models/mastodon_list.dart';
import '../providers/auth_provider.dart';
import '../services/mastodon_api.dart';
import '../utils/snackbar_helpers.dart';
import 'list_members_page.dart';

class ListManagementPage extends ConsumerStatefulWidget {
  const ListManagementPage({super.key});

  @override
  ConsumerState<ListManagementPage> createState() =>
      _ListManagementPageState();
}

class _ListManagementPageState extends ConsumerState<ListManagementPage> {
  /// 「最後に使ったアカウント」を覚えるための SharedPreferences キー。
  /// 複数アカウントを切り替えながらリストを管理する人向け。
  static const _prefKey = 'list_management_last_account_id';

  AuthAccount? _selectedAccount;
  List<MastodonList> _lists = const [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initSelectedAccount();
    });
  }

  Future<void> _initSelectedAccount() async {
    final accounts = ref.read(authProvider).accounts;
    if (accounts.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final lastId = prefs.getString(_prefKey);
    AuthAccount initial;
    if (lastId != null) {
      initial = accounts.firstWhere(
        (a) => a.id == lastId,
        orElse: () => accounts.first,
      );
    } else {
      initial = accounts.first;
    }
    if (!mounted) return;
    setState(() => _selectedAccount = initial);
    await _loadLists();
  }

  Future<void> _onAccountChanged(AuthAccount? acct) async {
    if (acct == null || acct.id == _selectedAccount?.id) return;
    setState(() => _selectedAccount = acct);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, acct.id);
    await _loadLists();
  }

  Future<void> _loadLists() async {
    final auth = _selectedAccount;
    if (auth == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final lists = await fetchLists(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
      );
      if (!mounted) return;
      setState(() {
        _lists = lists;
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

  Future<void> _createList() async {
    final auth = _selectedAccount;
    if (auth == null) return;

    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新しいリストを作成'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'リスト名'),
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('作成'),
          ),
        ],
      ),
    );
    // 即時 dispose は focus 外れに伴う clearComposing と競合するため 1 frame 遅延。
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (title == null || title.isEmpty) return;

    try {
      final newList = await createList(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        title: title,
      );
      if (!mounted) return;
      setState(() => _lists = [..._lists, newList]);
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, 'リスト作成に失敗しました: $e');
    }
  }

  Future<void> _renameList(MastodonList list) async {
    final auth = _selectedAccount;
    if (auth == null) return;

    final controller = TextEditingController(text: list.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('リスト名を変更'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    // 即時 dispose は focus 外れに伴う clearComposing と競合するため 1 frame 遅延。
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (newTitle == null || newTitle.isEmpty || newTitle == list.title) return;

    try {
      final updated = await updateList(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        listId: list.id,
        title: newTitle,
      );
      if (!mounted) return;
      setState(() {
        _lists =
            _lists.map((l) => l.id == updated.id ? updated : l).toList();
      });
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, 'リスト名の変更に失敗しました: $e');
    }
  }

  Future<void> _deleteList(MastodonList list) async {
    final auth = _selectedAccount;
    if (auth == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('リストを削除'),
        content: Text(
          '「${list.title}」を削除します。\n\nこのリストを参照しているカラムからは表示されなくなります。',
        ),
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
      await deleteList(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        listId: list.id,
      );
      if (!mounted) return;
      setState(() {
        _lists = _lists.where((l) => l.id != list.id).toList();
      });
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, 'リストの削除に失敗しました: $e');
    }
  }

  void _openMembers(MastodonList list) {
    final auth = _selectedAccount;
    if (auth == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ListMembersPage(auth: auth, list: list),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(authProvider).accounts;

    return Scaffold(
      appBar: AppBar(title: const Text('リスト管理')),
      body: Column(
        children: [
          if (accounts.length > 1) _buildAccountSelector(accounts),
          Expanded(child: _buildBody()),
        ],
      ),
      floatingActionButton: _selectedAccount == null
          ? null
          : FloatingActionButton.extended(
              // main の投稿 FAB (Icons.edit) と default heroTag が衝突して、
              // 戻る時に「+ → ペン」の icon snap が走るのを避けるため
              // Hero を無効化。
              heroTag: null,
              onPressed: _createList,
              icon: const Icon(Icons.add),
              label: const Text('リストを作成'),
            ),
    );
  }

  Widget _buildAccountSelector(List<AuthAccount> accounts) {
    final selected = _selectedAccount;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          const Icon(Icons.account_circle_outlined, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButton<AuthAccount>(
              isExpanded: true,
              value: selected,
              onChanged: _onAccountChanged,
              underline: const SizedBox.shrink(),
              items: accounts
                  .map(
                    (a) => DropdownMenuItem(
                      value: a,
                      child: Text(
                        '@${a.username}@${Uri.parse(a.instanceUrl).host}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_selectedAccount == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('アカウントが登録されていません'),
        ),
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text('リストを取得できませんでした'),
              const SizedBox(height: 4),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadLists,
                child: const Text('再試行'),
              ),
            ],
          ),
        ),
      );
    }
    if (_lists.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.list,
                size: 56,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              const Text('リストがまだありません'),
              const SizedBox(height: 4),
              const Text(
                '右下の「+」ボタンから作成できます',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadLists,
      child: ListView.separated(
        itemCount: _lists.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final list = _lists[i];
          return ListTile(
            leading: const Icon(Icons.list),
            title: Text(list.title),
            trailing: PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (action) {
                switch (action) {
                  case 'rename':
                    _renameList(list);
                    break;
                  case 'delete':
                    _deleteList(list);
                    break;
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'rename',
                  child: ListTile(
                    leading: Icon(Icons.edit_outlined),
                    title: Text('名前を変更'),
                    dense: true,
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    leading: Icon(Icons.delete_outline, color: Colors.red),
                    title: Text(
                      '削除',
                      style: TextStyle(color: Colors.red),
                    ),
                    dense: true,
                  ),
                ),
              ],
            ),
            onTap: () => _openMembers(list),
          );
        },
      ),
    );
  }
}
