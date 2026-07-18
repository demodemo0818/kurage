// lib/pages/dm_page.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/conversations_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../models/conversation.dart';
import '../models/auth_account.dart';
import '../models/status.dart';
import '../pages/thread_page.dart';
import '../utils/open_profile.dart';
import '../widgets/post_tile.dart';
import '../widgets/user_avatar.dart';

class DmPage extends ConsumerStatefulWidget {
  /// Deck (ワイド) のポップアップで開かれた時に渡される戻る (←) コールバック。
  /// null (ナロー/通常) のときは AppBar に戻る矢印を出さない。
  final VoidCallback? onDeckBack;

  const DmPage({super.key, this.onDeckBack});

  @override
  ConsumerState<DmPage> createState() => _DmPageState();
}

class _DmPageState extends ConsumerState<DmPage> {
  bool _loadingMore = false;
  final Set<String> _selectedAccountIds = {};
  bool _hasInitialized = false;

  @override
  void initState() {
    super.initState();
    
    // 保存されたアカウント選択を復元
    final List<String> savedAccountIds = ConversationsNotifier.getSavedSelectedAccountIds();
    if (savedAccountIds.isNotEmpty) {
      _selectedAccountIds.addAll(savedAccountIds);
    }
  }

  void _refreshConversations() {
    ref.read(conversationsProvider.notifier).updateSelectedAccounts(_selectedAccountIds.toList());
  }

  @override
  Widget build(BuildContext context) {
    final conversationsAsync = ref.watch(conversationsProvider);
    final authState = ref.watch(authProvider);
    final accounts = authState.accounts;

    // 初回アカウント選択
    if (!_hasInitialized && accounts.isNotEmpty) {
      _hasInitialized = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() {
          // 保存されたアカウント選択がない場合は全アカウントを選択
          if (_selectedAccountIds.isEmpty) {
            _selectedAccountIds.addAll(accounts.map((a) => a.id));
          } else {
            // 保存されたアカウントIDのうち、現在存在するものだけを保持
            _selectedAccountIds.removeWhere((id) => !accounts.any((a) => a.id == id));
            if (_selectedAccountIds.isEmpty) {
              _selectedAccountIds.addAll(accounts.map((a) => a.id));
            }
          }
        });
        _refreshConversations();
      });
    }

    return Scaffold(
      appBar: AppBar(
        leading: widget.onDeckBack == null
            ? null
            : BackButton(onPressed: widget.onDeckBack),
        title: const Text('DM'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: _buildAccountSelector(accounts),
        ),
      ),
      body: conversationsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text('エラー: $error'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  _refreshConversations();
                },
                child: const Text('再試行'),
              ),
            ],
          ),
        ),
        data: (conversations) {
          if (conversations.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.mail, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('DMはありません'),
                ],
              ),
            );
          }

          return NotificationListener<ScrollNotification>(
            onNotification: (sn) {
              if (!_loadingMore &&
                  sn.metrics.pixels >= sn.metrics.maxScrollExtent - 100) {
                setState(() => _loadingMore = true);
                ref
                    .read(conversationsProvider.notifier)
                    .loadMore()
                    .whenComplete(() => setState(() => _loadingMore = false));
              }
              return false;
            },
            child: RefreshIndicator(
              onRefresh: () => ref.read(conversationsProvider.notifier).refresh(),
              child: ListView.builder(
                itemCount: conversations.length + (_loadingMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= conversations.length) {
                    return const Padding(
                      padding: EdgeInsets.all(8),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final conversation = conversations[index];
                  return _buildConversationItem(conversation, accounts);
                },
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildConversationItem(Conversation conversation, List<AuthAccount> accounts) {
    final sourceAccount = accounts.firstWhere(
      (a) => a.id == conversation.sourceAccountId,
      orElse: () => accounts.isNotEmpty ? accounts.first : throw StateError('No accounts available'),
    );

    final lastMessage = conversation.lastStatus;

    return Container(
      decoration: sourceAccount.accountColor != null
          ? BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: sourceAccount.accountColor!.withValues(alpha: 0.6),
                  width: 4,
                ),
              ),
              color: sourceAccount.accountColor!.withValues(alpha: 0.05),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 最新の投稿内容（PostTileを使用）- ヘッダーなしで直接表示
          if (lastMessage != null)
            GestureDetector(
              onTap: () => _navigateToThread(lastMessage, conversation.sourceAccountId),
              child: PostTile(
                status: lastMessage,
                accountId: conversation.sourceAccountId,
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text('メッセージがありません'),
            ),
          // 会話のアクションボタン
          if (conversation.unread)
            _buildConversationActions(conversation),
          const Divider(height: 1),
        ],
      ),
    );
  }

  Widget _buildConversationActions(Conversation conversation) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (conversation.unread)
            TextButton.icon(
              onPressed: () => ref.read(conversationsProvider.notifier).markAsRead(conversation.id),
              icon: const Icon(Icons.mark_email_read, size: 16),
              label: const Text('既読'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.blue,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
            ),
          TextButton.icon(
            onPressed: () => _showConversationOptions(conversation),
            icon: const Icon(Icons.more_horiz, size: 16),
            label: const Text('その他'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.grey,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountSelector(List<AuthAccount> accounts) {
    final isAvatarSquare =
        ref.watch(settingsProvider.select((s) => s.isAvatarSquare));
    return Container(
      height: 60,
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.1),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        itemCount: accounts.length,
        itemBuilder: (context, index) {
          final account = accounts[index];
          final isSelected = _selectedAccountIds.contains(account.id);

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              onTap: () {
                setState(() {
                  if (isSelected) {
                    _selectedAccountIds.remove(account.id);
                  } else {
                    _selectedAccountIds.add(account.id);
                  }
                });
                _refreshConversations();
              },
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      // 外観設定の四角アイコンに合わせて選択リング/影の
                      // 形状も切り替える。
                      shape: isAvatarSquare
                          ? BoxShape.rectangle
                          : BoxShape.circle,
                      borderRadius: isAvatarSquare
                          ? BorderRadius.circular(4)
                          : null,
                      border: isSelected
                          ? Border.all(
                              color: account.accountColor ?? Theme.of(context).primaryColor,
                              width: 3,
                            )
                          : null,
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: (account.accountColor ?? Theme.of(context).primaryColor).withValues(alpha: 0.3),
                                blurRadius: 8,
                                spreadRadius: 2,
                              )
                            ]
                          : null,
                    ),
                    child: UserAvatar(
                      url: account.avatarUrl,
                      radius: 20,
                    ),
                  ),
                  if (isSelected)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: account.accountColor ?? Theme.of(context).primaryColor,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1),
                        ),
                        child: const Icon(
                          Icons.check,
                          color: Colors.white,
                          size: 8,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _navigateToThread(Status status, String? sourceAccountId) {
    debugPrint('=== DM: Navigating to thread ===');
    debugPrint('Status ID: ${status.id}');
    debugPrint('Status author: ${status.account.displayName}');
    debugPrint('Status author acct: ${status.account.acct}');
    debugPrint('Status URI: ${status.uri ?? 'Not available'}');
    debugPrint('Status URL: ${status.url ?? 'Not available'}');
    debugPrint('Source Account ID: $sourceAccountId');

    // Determine original instance from status URL or author acct
    String? originalInstance;
    final url = status.url;
    if (url != null) {
      final uri = Uri.parse(url);
      originalInstance = '${uri.scheme}://${uri.host}';
      debugPrint('Original instance from URL: $originalInstance');
    } else if (status.account.acct.contains('@')) {
      final parts = status.account.acct.split('@');
      if (parts.length >= 2) {
        originalInstance = 'https://${parts.last}';
        debugPrint('Original instance from acct: $originalInstance');
      }
    }
    debugPrint('Detected original instance: $originalInstance');
    
    openDeckPage(
      context,
      (onDeckBack) => ThreadPage(
        threadRootStatusId: status.id,
        sourceAccountId: sourceAccountId,
        originalStatus: status,
        onDeckBack: onDeckBack,
      ),
    );
  }

  void _showConversationOptions(Conversation conversation) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (conversation.unread)
            ListTile(
              leading: const Icon(Icons.mark_email_read),
              title: const Text('既読にする'),
              onTap: () {
                Navigator.pop(context);
                ref.read(conversationsProvider.notifier).markAsRead(conversation.id);
              },
            ),
          ListTile(
            leading: const Icon(Icons.delete, color: Colors.red),
            title: const Text('削除', style: TextStyle(color: Colors.red)),
            onTap: () {
              Navigator.pop(context);
              _confirmDeleteConversation(conversation);
            },
          ),
        ],
      ),
    );
  }

  void _confirmDeleteConversation(Conversation conversation) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('会話を削除'),
        content: const Text('この会話を削除しますか？この操作は取り消せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ref.read(conversationsProvider.notifier).removeConversation(conversation.id);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('削除'),
          ),
        ],
      ),
    );
  }
}
