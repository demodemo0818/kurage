// lib/pages/scheduled_posts_page.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auth_account.dart';
import '../providers/auth_provider.dart';
import '../services/mastodon_api.dart' as api;
import '../widgets/user_avatar.dart';

class ScheduledPostsPage extends ConsumerStatefulWidget {
  /// Deck (ワイド) のポップアップで開かれた時に渡される戻る (←) コールバック。
  /// null (ナロー/通常 push) のときは AppBar に通常の戻る矢印を出す。
  final VoidCallback? onDeckBack;

  const ScheduledPostsPage({super.key, this.onDeckBack});

  @override
  ConsumerState<ScheduledPostsPage> createState() => _ScheduledPostsPageState();
}

class _ScheduledPostsPageState extends ConsumerState<ScheduledPostsPage> {
  final Map<String, List<Map<String, dynamic>>> _scheduledPosts = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadScheduledPosts();
  }

  Future<void> _loadScheduledPosts() async {
    setState(() => _isLoading = true);
    
    try {
      final auth = ref.read(authProvider);
      _scheduledPosts.clear();
      
      for (final account in auth.accounts) {
        try {
          final posts = await api.fetchScheduledStatuses(
            instanceUrl: account.instanceUrl,
            accessToken: account.accessToken,
          );
          _scheduledPosts[account.id] = posts;
        } catch (e) {
          debugPrint('予約投稿取得エラー ${account.username}: $e');
          _scheduledPosts[account.id] = [];
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('予約投稿の読み込みに失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _deleteScheduledPost(
    AuthAccount account,
    String scheduledStatusId,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('予約投稿を削除'),
        content: const Text('この予約投稿を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await api.deleteScheduledStatus(
        instanceUrl: account.instanceUrl,
        accessToken: account.accessToken,
        scheduledStatusId: scheduledStatusId,
      );

      // リストから削除
      setState(() {
        _scheduledPosts[account.id]?.removeWhere(
          (post) => post['id'] == scheduledStatusId,
        );
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('予約投稿を削除しました')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('削除に失敗しました: $e')),
        );
      }
    }
  }

  Future<void> _editScheduledTime(
    AuthAccount account,
    Map<String, dynamic> scheduledPost,
  ) async {
    final currentScheduledAt = DateTime.parse(scheduledPost['scheduled_at']);
    final now = DateTime.now();
    final minDate = now.add(const Duration(minutes: 5));

    // 日付選択
    final selectedDate = await showDatePicker(
      context: context,
      initialDate: currentScheduledAt.isAfter(minDate) ? currentScheduledAt : minDate,
      firstDate: minDate,
      lastDate: now.add(const Duration(days: 365)),
      helpText: '新しい予約日を選択',
      cancelText: 'キャンセル',
      confirmText: 'OK',
      locale: const Locale('ja', 'JP'),
    );

    if (selectedDate == null) return;
    if (!mounted) return;

    // 時刻選択
    final selectedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(currentScheduledAt),
      helpText: '新しい予約時刻を選択',
      hourLabelText: '時',
      minuteLabelText: '分',
      cancelText: 'キャンセル',
      confirmText: 'OK',
      builder: (BuildContext context, Widget? child) {
        return Localizations.override(
          context: context,
          locale: const Locale('ja', 'JP'),
          child: child!,
        );
      },
    );

    if (selectedTime == null) return;

    final newScheduledAt = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      selectedTime.hour,
      selectedTime.minute,
    );

    if (newScheduledAt.isBefore(minDate)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('予約時刻は5分後以降を選択してください')),
        );
      }
      return;
    }

    try {
      await api.updateScheduledStatus(
        instanceUrl: account.instanceUrl,
        accessToken: account.accessToken,
        scheduledStatusId: scheduledPost['id'],
        scheduledAt: newScheduledAt,
      );

      // リストを更新
      await _loadScheduledPosts();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('予約時刻を変更しました')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('時刻変更に失敗しました: $e')),
        );
      }
    }
  }

  String _formatScheduledTime(String scheduledAtString) {
    // APIから取得した時刻はUTCなので、ローカル時刻に変換
    final scheduledAtUtc = DateTime.parse(scheduledAtString);
    final scheduledAt = scheduledAtUtc.toLocal();
    
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final scheduledDate = DateTime(scheduledAt.year, scheduledAt.month, scheduledAt.day);
    
    final timeStr = '${scheduledAt.hour.toString().padLeft(2, '0')}:${scheduledAt.minute.toString().padLeft(2, '0')}';
    
    if (scheduledDate == today) {
      return '今日 $timeStr';
    }
    
    final tomorrow = today.add(const Duration(days: 1));
    if (scheduledDate == tomorrow) {
      return '明日 $timeStr';
    }
    
    if (scheduledAt.year == now.year) {
      return '${scheduledAt.month}月${scheduledAt.day}日 $timeStr';
    }
    
    return '${scheduledAt.year}年${scheduledAt.month}月${scheduledAt.day}日 $timeStr';
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('予約投稿管理'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onDeckBack ?? () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '更新',
            onPressed: _loadScheduledPosts,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadScheduledPosts,
              child: _scheduledPosts.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.schedule, size: 64, color: Colors.grey),
                          SizedBox(height: 16),
                          Text(
                            '予約投稿はありません',
                            style: TextStyle(
                              fontSize: 18,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: auth.accounts.length,
                      itemBuilder: (context, accountIndex) {
                        final account = auth.accounts[accountIndex];
                        final posts = _scheduledPosts[account.id] ?? [];

                        if (posts.isEmpty) {
                          return Card(
                            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            child: ListTile(
                              leading: UserAvatar(
                                url: account.avatarUrl,
                                radius: 20,
                              ),
                              title: Text(account.displayName),
                              subtitle: Text('@${account.username}@${account.host}'),
                              trailing: const Text(
                                '予約投稿なし',
                                style: TextStyle(color: Colors.grey),
                              ),
                            ),
                          );
                        }

                        return Card(
                          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          child: ExpansionTile(
                            leading: UserAvatar(
                              url: account.avatarUrl,
                              radius: 20,
                            ),
                            title: Text(account.displayName),
                            subtitle: Text('@${account.username}@${account.host}'),
                            trailing: Text(
                              '${posts.length}件',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            children: posts.map((post) {
                              final content = post['params']['text'] ?? '';
                              final scheduledAt = post['scheduled_at'] ?? '';
                              
                              return ListTile(
                                title: Text(
                                  content.isNotEmpty
                                      ? (content.length > 50 ? '${content.substring(0, 50)}...' : content)
                                      : '(メディアのみ)',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '予約時刻: ${_formatScheduledTime(scheduledAt)}',
                                      style: const TextStyle(fontWeight: FontWeight.w500),
                                    ),
                                    if (post['params']['media_ids'] != null && 
                                        (post['params']['media_ids'] as List).isNotEmpty)
                                      Text(
                                        'メディア: ${(post['params']['media_ids'] as List).length}件',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                  ],
                                ),
                                trailing: PopupMenuButton<String>(
                                  onSelected: (action) {
                                    switch (action) {
                                      case 'edit':
                                        _editScheduledTime(account, post);
                                        break;
                                      case 'delete':
                                        _deleteScheduledPost(account, post['id']);
                                        break;
                                    }
                                  },
                                  itemBuilder: (context) => [
                                    const PopupMenuItem(
                                      value: 'edit',
                                      child: ListTile(
                                        leading: Icon(Icons.edit),
                                        title: Text('時刻変更'),
                                        dense: true,
                                      ),
                                    ),
                                    const PopupMenuItem(
                                      value: 'delete',
                                      child: ListTile(
                                        leading: Icon(Icons.delete, color: Colors.red),
                                        title: Text('削除', style: TextStyle(color: Colors.red)),
                                        dense: true,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}