// lib/pages/account_settings_page.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/auth_account.dart';
import '../providers/auth_provider.dart';
import '../services/auth_service.dart';
import '../services/mastodon_api.dart';
import '../utils/snackbar_helpers.dart';
import '../widgets/settings_section.dart';
import '../widgets/user_avatar.dart';

/// アカウント設定ページ (Android「設定」アプリ風レイアウト)
class AccountSettingsPage extends ConsumerWidget {
  const AccountSettingsPage({super.key});

  /// アカウントのサーバ側デフォルト公開範囲 (`posting:default:visibility`)
  /// を表示・変更するダイアログを開く。変更は
  /// `PATCH /api/v1/accounts/update_credentials` の `source[privacy]` で
  /// サーバに保存されるため、Web UI など他クライアントにも反映される。
  Future<void> _showDefaultVisibilityDialog(
      BuildContext context, AuthAccount acct) async {
    const options = [
      (value: 'public', icon: Icons.public, label: '公開'),
      (value: 'unlisted', icon: Icons.lock_open, label: '控えめ公開'),
      (value: 'private', icon: Icons.lock, label: 'フォロワーのみ'),
      (value: 'direct', icon: Icons.alternate_email, label: '特定の人'),
    ];

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(
          'デフォルト公開範囲\n@${acct.username}',
          style: const TextStyle(fontSize: 16),
        ),
        children: [
          // 現在値の取得は現在値へのチェックマーク表示にだけ使う。取得に
          // 失敗しても選択肢自体は出す (変更操作は独立して成立するため)。
          FutureBuilder<UserPreferences>(
            future: fetchPreferences(
              instanceUrl: acct.instanceUrl,
              accessToken: acct.accessToken,
            ),
            builder: (ctx, snap) {
              final current = snap.data?.defaultVisibility;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (snap.connectionState == ConnectionState.waiting)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: LinearProgressIndicator(),
                    ),
                  if (snap.hasError)
                    const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                      child: Text(
                        '現在の設定を取得できませんでした',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                  for (final opt in options)
                    ListTile(
                      leading: Icon(opt.icon),
                      title: Text(opt.label),
                      trailing: current == opt.value
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => Navigator.pop(ctx, opt.value),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
    if (selected == null) return;

    try {
      await updateDefaultPostVisibility(
        instanceUrl: acct.instanceUrl,
        accessToken: acct.accessToken,
        visibility: selected,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('デフォルト公開範囲を変更しました')),
      );
    } catch (e) {
      if (!context.mounted) return;
      showErrorSnackBar(context, 'デフォルト公開範囲の変更に失敗しました: $e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final notifier = ref.read(authProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('アカウント設定'),
      ),
      body: SettingsListView(
        children: [
          SettingsSection(
            title: '登録済みのアカウント',
            children: [
              if (auth.accounts.isEmpty)
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('登録済みのアカウントがありません'),
                  subtitle: Text('右下の「+」ボタンから追加できます'),
                ),
              ...auth.accounts.map((acct) {
                return ListTile(
                  leading: UserAvatar(
                    url: acct.avatarUrl,
                    radius: 20, // CircleAvatar default
                  ),
                  title: Text(acct.displayName),
                  subtitle: Text('@${acct.username}\n${acct.instanceUrl}'),
                  isThreeLine: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 色設定ボタン
                      IconButton(
                        tooltip: 'アカウントカラー',
                        icon: Icon(
                          Icons.palette,
                          color: acct.accountColor ?? Colors.grey,
                        ),
                        onPressed: () async {
                          final selectedColor = await showDialog<Color>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('アカウントカラーを選択'),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      Colors.red,
                                      Colors.pink,
                                      Colors.purple,
                                      Colors.deepPurple,
                                      Colors.indigo,
                                      Colors.blue,
                                      Colors.lightBlue,
                                      Colors.cyan,
                                      Colors.teal,
                                      Colors.green,
                                      Colors.lightGreen,
                                      Colors.lime,
                                      Colors.yellow,
                                      Colors.amber,
                                      Colors.orange,
                                      Colors.deepOrange,
                                      Colors.brown,
                                      Colors.grey,
                                    ].map((color) {
                                      return GestureDetector(
                                        onTap: () =>
                                            Navigator.pop(ctx, color),
                                        child: Container(
                                          width: 40,
                                          height: 40,
                                          decoration: BoxDecoration(
                                            color: color,
                                            shape: BoxShape.circle,
                                            border: acct.accountColor == color
                                                ? Border.all(
                                                    width: 3,
                                                    color: Colors.black)
                                                : null,
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                  const SizedBox(height: 16),
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, null),
                                    child: const Text('色をリセット'),
                                  ),
                                ],
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('キャンセル'),
                                ),
                              ],
                            ),
                          );
                          await notifier.updateAccountColor(
                              acct.id, selectedColor);
                        },
                      ),
                      IconButton(
                        tooltip: 'デフォルト公開範囲',
                        icon: const Icon(Icons.public),
                        onPressed: () =>
                            _showDefaultVisibilityDialog(context, acct),
                      ),
                      IconButton(
                        tooltip: 'アカウントを削除',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await notifier.logout(acct.id);
                        },
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        // main の投稿 FAB (Icons.edit) と default heroTag が衝突して、戻る時に
        // 「+ → ペン」の icon snap が走るのを避けるため Hero を無効化。
        heroTag: null,
        tooltip: 'アカウントを追加',
        icon: const Icon(Icons.add),
        label: const Text('アカウントを追加'),
        onPressed: () async {
          final uriController = TextEditingController(text: 'https://');
          final res = await showDialog<String>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('インスタンス URL を入力'),
              content: TextField(
                controller: uriController,
                decoration: const InputDecoration(
                  labelText: '例: https://mastodon.social',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('キャンセル'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final url = uriController.text.trim();
                    // ジェスチャ内で同期的に認証ポップアップを先行オープンする
                    // (iOS Safari のポップアップブロック回避)。host が無い不正
                    // 入力では開かない。Web 以外は no-op。await を挟まないこと。
                    if (Uri.tryParse(url)?.host.isNotEmpty ?? false) {
                      AuthService.prepareAuthWindow();
                    }
                    Navigator.pop(ctx, url);
                  },
                  child: const Text('認証開始'),
                ),
              ],
            ),
          );
          // 即時 dispose は focus 外れに伴う clearComposing と競合するため 1 frame 遅延。
          WidgetsBinding.instance
              .addPostFrameCallback((_) => uriController.dispose());
          if (res != null && res.isNotEmpty) {
            try {
              await notifier.login(res);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('ログインに成功しました')),
              );
              // 認証完了後はルートまで戻る
              Navigator.of(context).popUntil((route) => route.isFirst);
            } catch (e) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('ログイン失敗: $e')),
              );
            }
          }
        },
      ),
    );
  }
}
