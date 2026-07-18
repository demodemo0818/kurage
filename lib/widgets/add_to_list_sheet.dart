// lib/widgets/add_to_list_sheet.dart
//
// 「指定アカウントをリストに追加 / 削除」用のボトムシート。
// 投稿アクションメニューやプロフィールページから呼び出して使う。

import 'package:flutter/material.dart';

import '../models/account.dart';
import '../models/auth_account.dart';
import '../models/mastodon_list.dart';
import '../services/mastodon_api.dart';

/// `auth` のアカウント (= ログインアカウント) が持っているリストを一覧表示し、
/// `target` (= 操作対象のアカウント) のリスト所属をトグルできるボトムシートを開く。
///
/// 各トグルはその場で API に反映されるため、呼び出し側で戻り値を受け取る
/// 必要は無い (シート自身が SnackBar 等でユーザーフィードバックを行う)。
Future<void> showAddToListSheet({
  required BuildContext context,
  required AuthAccount auth,
  required Account target,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _AddToListSheet(auth: auth, target: target),
  );
}

class _AddToListSheet extends StatefulWidget {
  const _AddToListSheet({required this.auth, required this.target});

  final AuthAccount auth;
  final Account target;

  @override
  State<_AddToListSheet> createState() => _AddToListSheetState();
}

class _AddToListSheetState extends State<_AddToListSheet> {
  bool _loading = true;
  String? _error;

  /// `auth` の全リスト
  List<MastodonList> _allLists = const [];

  /// 現在 target が含まれているリストの ID 集合
  Set<String> _membership = {};

  /// 楽観的更新中の listId (重複タップ防止 + ProgressIndicator 表示用)
  final Set<String> _busyIds = {};

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
      // 全リスト + target の所属リストを並列取得
      final results = await Future.wait([
        fetchLists(
          instanceUrl: widget.auth.instanceUrl,
          accessToken: widget.auth.accessToken,
        ),
        fetchListsContainingAccount(
          instanceUrl: widget.auth.instanceUrl,
          accessToken: widget.auth.accessToken,
          accountId: widget.target.id,
        ),
      ]);
      final all = results[0];
      final containing = results[1];
      if (!mounted) return;
      setState(() {
        _allLists = all;
        _membership = containing.map((l) => l.id).toSet();
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

  Future<void> _toggleMembership(MastodonList list) async {
    if (_busyIds.contains(list.id)) return;
    final isMember = _membership.contains(list.id);

    setState(() => _busyIds.add(list.id));
    try {
      if (isMember) {
        await removeAccountsFromList(
          instanceUrl: widget.auth.instanceUrl,
          accessToken: widget.auth.accessToken,
          listId: list.id,
          accountIds: [widget.target.id],
        );
        if (!mounted) return;
        setState(() => _membership.remove(list.id));
      } else {
        try {
          await addAccountsToList(
            instanceUrl: widget.auth.instanceUrl,
            accessToken: widget.auth.accessToken,
            listId: list.id,
            accountIds: [widget.target.id],
          );
          if (!mounted) return;
          setState(() => _membership.add(list.id));
        } catch (e) {
          // 未フォローの相手をリストに追加しようとすると Mastodon は 422 を
          // 返す。ここを単にエラー表示で済ませると、ユーザーは「なぜ?」と
          // なるし、SnackBar で出してもモーダルボトムシートの背後に
          // 隠れてシートを閉じるまで見えない (= タイムラインに戻ってから
          // 突然出てくるように見える) という UX 問題が出る。
          // 422 のときは AlertDialog で「フォローして追加」導線を提示し、
          // その場でリカバリできるようにする。
          if (!mounted) return;
          if (e.toString().contains('422')) {
            await _promptFollowAndAdd(list);
          } else {
            rethrow;
          }
        }
      }
    } catch (e) {
      if (!mounted) return;
      // 422 以外の失敗 (ネットワーク等) もボトムシート背後に SnackBar を
      // 沈めないよう、ダイアログで明示する。
      await _showErrorDialog('リストの更新に失敗しました: $e');
    } finally {
      if (mounted) {
        setState(() => _busyIds.remove(list.id));
      }
    }
  }

  /// 未フォロー → 422 のリカバリ導線。フォローしてから再度リスト追加を試す。
  /// 鍵アカウントの場合は followAccount 後も `following` が false で返るので、
  /// その場合は「フォローリクエスト送信済み」だけ伝えてリスト追加は諦める
  /// (= 承認待ちで API もどのみち 422 を返す)。
  Future<void> _promptFollowAndAdd(MastodonList list) async {
    final shouldFollow = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('フォローが必要です'),
        content: Text(
          '「${list.title}」に追加するには、まず @${widget.target.acct} を'
          'フォローする必要があります。\n\n'
          'フォローしてからリストに追加しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('フォローして追加'),
          ),
        ],
      ),
    );
    if (shouldFollow != true || !mounted) return;

    try {
      final rel = await followAccount(
        instanceUrl: widget.auth.instanceUrl,
        accessToken: widget.auth.accessToken,
        accountId: widget.target.id,
      );
      if (!mounted) return;
      if (!rel.following) {
        // 鍵アカウント — フォローリクエスト送信済みだが、まだ承認されていない。
        await _showErrorDialog(
          'このアカウントは承認制 (鍵アカウント) です。フォローリクエストを'
          '送信しました。承認されたらリストに追加できます。',
        );
        return;
      }
      await addAccountsToList(
        instanceUrl: widget.auth.instanceUrl,
        accessToken: widget.auth.accessToken,
        listId: list.id,
        accountIds: [widget.target.id],
      );
      if (!mounted) return;
      setState(() => _membership.add(list.id));
    } catch (e) {
      if (!mounted) return;
      await _showErrorDialog('フォローまたはリスト追加に失敗しました: $e');
    }
  }

  /// シートの上にモーダル表示される共通エラーダイアログ。
  /// SnackBar はモーダルボトムシートの背後に隠れて見えないため、ここでは
  /// ダイアログを使う。
  Future<void> _showErrorDialog(String message) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.error_outline, color: Colors.red),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  Future<void> _createNewList() async {
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新しいリストを作成'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'リスト名',
          ),
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
    // 即時 dispose すると、ダイアログ閉鎖時の focus 外れに伴う
    // EditableTextState._handleFocusChanged → controller.clearComposing() が
    // disposed な controller を触る例外を投げるため 1 frame 遅延する。
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (title == null || title.isEmpty) return;

    try {
      final newList = await createList(
        instanceUrl: widget.auth.instanceUrl,
        accessToken: widget.auth.accessToken,
        title: title,
      );
      if (!mounted) return;
      setState(() {
        _allLists = [..._allLists, newList];
      });
      // 作ったリストにそのまま追加
      await _toggleMembership(newList);
    } catch (e) {
      if (!mounted) return;
      await _showErrorDialog('リスト作成に失敗しました: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final acct = widget.target.acct;

    return SafeArea(
      child: ConstrainedBox(
        // 端末高さの 80% までに収める。中身が少ないときは縮む。
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ヘッダ
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'リストに追加',
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '@$acct',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 24),
              Expanded(child: _buildBody(theme)),
              const Divider(height: 12),
              // 新しいリストを作成
              ListTile(
                leading: Icon(Icons.add, color: theme.colorScheme.primary),
                title: Text(
                  '新しいリストを作成',
                  style: TextStyle(color: theme.colorScheme.primary),
                ),
                onTap: _createNewList,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      );
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
              Text(
                'リストを取得できませんでした',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _load,
                child: const Text('再試行'),
              ),
            ],
          ),
        ),
      );
    }
    if (_allLists.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.list,
                  size: 48, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              const Text('リストがまだありません'),
              const SizedBox(height: 4),
              Text(
                '「新しいリストを作成」から作れます',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: _allLists.length,
      itemBuilder: (_, i) {
        final list = _allLists[i];
        final isMember = _membership.contains(list.id);
        final busy = _busyIds.contains(list.id);
        return CheckboxListTile(
          value: isMember,
          // タップ自体は CheckboxListTile が拾うが、busy 中は無視する。
          onChanged: busy ? null : (_) => _toggleMembership(list),
          title: Text(list.title),
          secondary: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  Icons.list,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
          controlAffinity: ListTileControlAffinity.trailing,
        );
      },
    );
  }
}
