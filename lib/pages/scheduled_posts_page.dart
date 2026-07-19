// lib/pages/scheduled_posts_page.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
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
          SnackBar(content: Text(context.l10n.scheduledLoadFailed('$e'))),
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
        title: Text(context.l10n.scheduledDeleteTitle),
        content: Text(context.l10n.scheduledDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.delete),
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
          SnackBar(content: Text(context.l10n.scheduledDeleted)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.deleteFailed('$e'))),
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
      helpText: context.l10n.scheduledPickDateHelp,
      cancelText: context.l10n.cancel,
      confirmText: 'OK',
      // locale 指定なし = アプリの表示言語 (MaterialApp の locale) に追従
    );

    if (selectedDate == null) return;
    if (!mounted) return;

    // 時刻選択
    final selectedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(currentScheduledAt),
      helpText: context.l10n.scheduledPickTimeHelp,
      hourLabelText: context.l10n.hourLabel,
      minuteLabelText: context.l10n.minuteLabel,
      cancelText: context.l10n.cancel,
      confirmText: 'OK',
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
          SnackBar(content: Text(context.l10n.scheduledMinFiveMinutes)),
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
          SnackBar(content: Text(context.l10n.scheduledTimeChanged)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.scheduledTimeChangeFailed('$e'))),
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
      return l10n.scheduledToday(timeStr);
    }

    final tomorrow = today.add(const Duration(days: 1));
    if (scheduledDate == tomorrow) {
      return l10n.scheduledTomorrow(timeStr);
    }

    if (scheduledAt.year == now.year) {
      return l10n.scheduledDateShort(scheduledAt.month, scheduledAt.day, timeStr);
    }

    return l10n.scheduledDateFull(
        scheduledAt.year, scheduledAt.month, scheduledAt.day, timeStr);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.settingsScheduledPosts),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onDeckBack ?? () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: context.l10n.refresh,
            onPressed: _loadScheduledPosts,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadScheduledPosts,
              child: _scheduledPosts.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.schedule,
                              size: 64, color: Colors.grey),
                          const SizedBox(height: 16),
                          Text(
                            context.l10n.scheduledEmpty,
                            style: const TextStyle(
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
                              trailing: Text(
                                context.l10n.scheduledNoneShort,
                                style: const TextStyle(color: Colors.grey),
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
                              context.l10n.countItems(posts.length),
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            children: posts.map((post) {
                              final content = post['params']['text'] ?? '';
                              final scheduledAt = post['scheduled_at'] ?? '';
                              
                              return ListTile(
                                title: Text(
                                  content.isNotEmpty
                                      ? (content.length > 50 ? '${content.substring(0, 50)}...' : content)
                                      : context.l10n.scheduledMediaOnly,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      context.l10n.scheduledTimeLabel(
                                          _formatScheduledTime(scheduledAt)),
                                      style: const TextStyle(fontWeight: FontWeight.w500),
                                    ),
                                    if (post['params']['media_ids'] != null && 
                                        (post['params']['media_ids'] as List).isNotEmpty)
                                      Text(
                                        context.l10n.scheduledMediaCount(
                                            (post['params']['media_ids']
                                                    as List)
                                                .length),
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
                                    PopupMenuItem(
                                      value: 'edit',
                                      child: ListTile(
                                        leading: const Icon(Icons.edit),
                                        title: Text(
                                            context.l10n.scheduledChangeTime),
                                        dense: true,
                                      ),
                                    ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: ListTile(
                                        leading: const Icon(Icons.delete,
                                            color: Colors.red),
                                        title: Text(context.l10n.delete,
                                            style: const TextStyle(
                                                color: Colors.red)),
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