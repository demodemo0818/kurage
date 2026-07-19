// lib/pages/filters_page.dart
//
// フィルタ管理ページ。アカウントごとのサーバ側フィルタ一覧を表示し、
// 新規作成 / 編集 / 削除へのナビゲーションを提供する。
// (Mastodon Filters v2; 古いサーバや派生実装は空配列扱い)

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../models/auth_account.dart';
import '../models/filter.dart';
import '../providers/auth_provider.dart';
import '../services/mastodon_api.dart';
import '../utils/snackbar_helpers.dart';
import 'filter_edit_page.dart';

class FiltersPage extends ConsumerStatefulWidget {
  const FiltersPage({super.key});

  @override
  ConsumerState<FiltersPage> createState() => _FiltersPageState();
}

class _FiltersPageState extends ConsumerState<FiltersPage> {
  static const _prefKey = 'filters_last_account_id';

  AuthAccount? _selectedAccount;
  List<MastodonFilter> _filters = const [];
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
    await _loadFilters();
  }

  Future<void> _onAccountChanged(AuthAccount? acct) async {
    if (acct == null || acct.id == _selectedAccount?.id) return;
    setState(() => _selectedAccount = acct);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, acct.id);
    await _loadFilters();
  }

  Future<void> _loadFilters() async {
    final auth = _selectedAccount;
    if (auth == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await fetchFilters(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
      );
      if (!mounted) return;
      setState(() {
        _filters = list;
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

  Future<void> _createFilter() async {
    final auth = _selectedAccount;
    if (auth == null) return;
    final created = await Navigator.push<MastodonFilter>(
      context,
      MaterialPageRoute(
        builder: (_) => FilterEditPage(auth: auth),
      ),
    );
    if (created != null && mounted) {
      setState(() => _filters = [..._filters, created]);
    }
  }

  Future<void> _editFilter(MastodonFilter filter) async {
    final auth = _selectedAccount;
    if (auth == null) return;
    final updated = await Navigator.push<MastodonFilter>(
      context,
      MaterialPageRoute(
        builder: (_) => FilterEditPage(auth: auth, existing: filter),
      ),
    );
    if (updated != null && mounted) {
      setState(() {
        _filters =
            _filters.map((f) => f.id == updated.id ? updated : f).toList();
      });
    }
  }

  Future<void> _deleteFilter(MastodonFilter filter) async {
    final auth = _selectedAccount;
    if (auth == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.filterDeleteTitle),
        content: Text(ctx.l10n.filterDeleteMessage(filter.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(ctx.l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await deleteFilter(
        instanceUrl: auth.instanceUrl,
        accessToken: auth.accessToken,
        filterId: filter.id,
      );
      if (!mounted) return;
      setState(() {
        _filters = _filters.where((f) => f.id != filter.id).toList();
      });
    } on FiltersNotSupportedException catch (_) {
      if (!mounted) return;
      showErrorSnackBar(context, context.l10n.filterUnsupported);
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, context.l10n.filterDeleteFailed('$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(authProvider).accounts;

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.filtersTitle)),
      body: Column(
        children: [
          if (accounts.length > 1) _buildAccountSelector(accounts),
          Expanded(child: _buildBody()),
        ],
      ),
      floatingActionButton: _selectedAccount == null
          ? null
          : FloatingActionButton.extended(
              heroTag: null,
              onPressed: _createFilter,
              icon: const Icon(Icons.add),
              label: Text(context.l10n.filterCreate),
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
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(context.l10n.noAccountsRegistered),
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
              Text(context.l10n.filtersFetchFailed),
              const SizedBox(height: 4),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadFilters,
                child: Text(context.l10n.retry),
              ),
            ],
          ),
        ),
      );
    }
    if (_filters.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.filter_alt_outlined,
                size: 56,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(context.l10n.filtersEmpty),
              const SizedBox(height: 4),
              Text(
                context.l10n.plusButtonCreateHint,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadFilters,
      child: ListView.separated(
        itemCount: _filters.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final f = _filters[i];
          return ListTile(
            leading: Icon(
              f.filterAction == 'hide'
                  ? Icons.visibility_off_outlined
                  : Icons.filter_alt_outlined,
            ),
            title: Text(
              f.title.isEmpty ? context.l10n.untitled : f.title,
              style: TextStyle(
                decoration: f.isExpired ? TextDecoration.lineThrough : null,
              ),
            ),
            subtitle: Text(_subtitleFor(context, f)),
            trailing: PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (action) {
                switch (action) {
                  case 'edit':
                    _editFilter(f);
                    break;
                  case 'delete':
                    _deleteFilter(f);
                    break;
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'edit',
                  child: ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: Text(context.l10n.edit),
                    dense: true,
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    leading:
                        const Icon(Icons.delete_outline, color: Colors.red),
                    title: Text(context.l10n.delete,
                        style: const TextStyle(color: Colors.red)),
                    dense: true,
                  ),
                ),
              ],
            ),
            onTap: () => _editFilter(f),
          );
        },
      ),
    );
  }

  String _subtitleFor(BuildContext context, MastodonFilter f) {
    final parts = <String>[];
    parts.add(context.l10n.filterKeywordsCount(f.keywords.length));
    final ctxLabels = f.context
        .map((c) => kFilterContextLabels(context)[c] ?? c)
        .join(', ');
    if (ctxLabels.isNotEmpty) parts.add(ctxLabels);
    parts.add(kFilterActionLabels(context)[f.filterAction] ?? f.filterAction);
    if (f.isExpired) parts.add(context.l10n.filterExpired);
    return parts.join(' / ');
  }
}
