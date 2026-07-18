// lib/pages/announcements_page.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/network_image_x.dart';

import '../models/announcement.dart';
import '../models/auth_account.dart';
import '../providers/announcements_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/html_parser.dart';
import '../utils/snackbar_helpers.dart';
import '../utils/time_formatter.dart';
import '../widgets/emoji_picker.dart';

/// サーバ管理者からのお知らせ一覧。
/// 複数アカウントのお知らせを 1 画面にまとめて表示する。
class AnnouncementsPage extends ConsumerWidget {
  /// Deck (ワイド) のポップアップで開かれた時に渡される戻る (←) コールバック。
  /// null (ナロー/通常 push) のときは AppBar に戻る矢印を出さない。
  final VoidCallback? onDeckBack;

  const AnnouncementsPage({super.key, this.onDeckBack});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // お知らせページを「ベル等で明示的に開いた」ときは、今アクティブな
    // カラムのアカウントに関係なく全アカウントのお知らせを見たいので、
    // `filteredAnnouncementsProvider` ではなく全件 (`announcementsProvider`)
    // を表示する。アクティブカラムのアカウントに紐づくお知らせしか出ないと、
    // そのアカウントのカラムを開いていない時にページが空になってしまう
    // (各カードは出元アカウントを `_Header` に表示するので区別は付く)。
    // なお未読バッジ (`unreadAnnouncementCountProvider`) は引き続き
    // `filteredAnnouncementsProvider` ベースでアクティブカラム分のみ数える。
    final asyncList = ref.watch(announcementsProvider);
    return Scaffold(
      appBar: AppBar(
        leading: onDeckBack == null ? null : BackButton(onPressed: onDeckBack),
        title: const Text('サーバーからのお知らせ'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '更新',
            onPressed: () =>
                ref.read(announcementsProvider.notifier).refresh(),
          ),
        ],
      ),
      body: asyncList.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.grey),
                const SizedBox(height: 12),
                Text('お知らせの取得に失敗しました\n$e',
                    textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () =>
                      ref.read(announcementsProvider.notifier).refresh(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('再試行'),
                ),
              ],
            ),
          ),
        ),
        data: (all) {
          final items = all;
          if (items.isEmpty) {
            return RefreshIndicator(
              onRefresh: () =>
                  ref.read(announcementsProvider.notifier).refresh(),
              child: ListView(
                children: const [
                  SizedBox(height: 120),
                  Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('現在お知らせはありません',
                          style: TextStyle(color: Colors.grey)),
                    ),
                  ),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () =>
                ref.read(announcementsProvider.notifier).refresh(),
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final a = items[i];
                return _AnnouncementCard(announcement: a);
              },
            ),
          );
        },
      ),
    );
  }
}

class _AnnouncementCard extends ConsumerWidget {
  const _AnnouncementCard({required this.announcement});

  final Announcement announcement;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final settings = ref.watch(settingsProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final sourceAccount = auth.accounts
        .where((a) => a.id == announcement.sourceAccountId)
        .firstOrNull;
    final unread = !announcement.read;
    final accentColor = sourceAccount?.accountColor ?? theme.colorScheme.primary;

    final contentSpans = parseContentWithEmojis(
      contentHtml: announcement.content,
      emojis: announcement.emojis,
      baseStyle: TextStyle(
        fontSize: settings.fontSize,
        height: settings.lineHeight,
        color: theme.textTheme.bodyLarge?.color,
      ),
      linkColor: theme.colorScheme.primary,
      emojiSize: settings.fontSize * settings.emojiScale,
      context: context,
      disableEmojiAnimation: settings.disableCustomEmojiAnimationInContent,
    );

    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          // 未読は accentColor で強調、既読はサブトル
          color: unread
              ? accentColor.withValues(alpha: 0.7)
              : (isDark ? Colors.grey.shade800 : Colors.grey.shade300),
          width: unread ? 1.5 : 1,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(
              account: sourceAccount,
              accent: accentColor,
              publishedAt: announcement.publishedAt,
              unread: unread,
              useRelativeTime: settings.useRelativeTime,
            ),
            const SizedBox(height: 10),
            SelectableText.rich(
              TextSpan(children: contentSpans),
            ),
            const SizedBox(height: 10),
            _ReactionsRow(announcement: announcement),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (unread)
                  TextButton.icon(
                    onPressed: () async {
                      try {
                        await ref
                            .read(announcementsProvider.notifier)
                            .dismiss(announcement);
                      } catch (_) {
                        if (context.mounted) {
                          showErrorSnackBar(context, '既読化に失敗しました');
                        }
                      }
                    },
                    icon: const Icon(Icons.done, size: 18),
                    label: const Text('既読にする'),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      '既読',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.account,
    required this.accent,
    required this.publishedAt,
    required this.unread,
    required this.useRelativeTime,
  });

  final AuthAccount? account;
  final Color accent;
  final DateTime publishedAt;
  final bool unread;
  final bool useRelativeTime;

  @override
  Widget build(BuildContext context) {
    final host = account != null
        ? Uri.tryParse(account!.instanceUrl)?.host ?? account!.instanceUrl
        : '?';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 4,
          height: 24,
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        if (account != null)
          KurageCircleAvatar(
            radius: 10,
            imageUrl: account!.avatarUrl,
          )
        else
          const Icon(Icons.campaign, size: 18),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            host,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (unread)
          Container(
            margin: const EdgeInsets.only(right: 6),
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: accent.withValues(alpha: 0.6)),
            ),
            child: Text(
              '未読',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: accent,
              ),
            ),
          ),
        TimeText(
          dt: publishedAt,
          useRelative: useRelativeTime,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      ],
    );
  }
}

class _ReactionsRow extends ConsumerWidget {
  const _ReactionsRow({required this.announcement});

  final Announcement announcement;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        ...announcement.reactions.map((r) => _ReactionChip(
              announcement: announcement,
              reaction: r,
            )),
        _AddReactionChip(announcement: announcement),
      ],
    );
  }
}

class _ReactionChip extends ConsumerWidget {
  const _ReactionChip({required this.announcement, required this.reaction});

  final Announcement announcement;
  final AnnouncementReaction reaction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final selected = reaction.me;
    final bg = selected
        ? theme.colorScheme.primary.withValues(alpha: 0.15)
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6);
    final border = selected
        ? theme.colorScheme.primary.withValues(alpha: 0.6)
        : theme.colorScheme.outlineVariant;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () async {
        final notifier = ref.read(announcementsProvider.notifier);
        try {
          if (selected) {
            await notifier.removeReaction(announcement, reaction.name);
          } else {
            await notifier.addReaction(announcement, reaction.name);
          }
        } catch (_) {
          if (context.mounted) {
            showErrorSnackBar(context, 'リアクション操作に失敗しました');
          }
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reaction.url != null)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Tooltip(
                  message: ':${reaction.name}:',
                  waitDuration: const Duration(milliseconds: 300),
                  child: KurageNetworkImage(
                    imageUrl: reaction.url!,
                    width: 18,
                    height: 18,
                    fit: BoxFit.contain,
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(reaction.name,
                    style: const TextStyle(fontSize: 16)),
              ),
            Text(
              '${reaction.count}',
              style: TextStyle(
                fontSize: 12,
                fontWeight:
                    selected ? FontWeight.bold : FontWeight.normal,
                color: selected ? theme.colorScheme.primary : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddReactionChip extends ConsumerWidget {
  const _AddReactionChip({required this.announcement});

  final Announcement announcement;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _showPicker(context, ref),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: const Icon(Icons.add_reaction_outlined, size: 18),
      ),
    );
  }

  void _showPicker(BuildContext context, WidgetRef ref) {
    final accountId = announcement.sourceAccountId;
    if (accountId == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.6,
            child: EmojiPicker(
              // お知らせはサーバ単位なので、出元アカウントだけを渡して
              // そのインスタンスのカスタム絵文字のみを候補に出す。
              selectedAccountIds: {accountId},
              onEmojiSelected: (raw) async {
                // EmojiPicker は Unicode 絵文字なら "🎉" を、カスタム絵文字
                // なら ":shortcode:" を返す。Mastodon の reaction API には
                // 前者はそのまま、後者は ":" を外した shortcode を渡す。
                final name = (raw.startsWith(':') && raw.endsWith(':'))
                    ? raw.substring(1, raw.length - 1)
                    : raw;
                Navigator.pop(ctx);
                try {
                  await ref
                      .read(announcementsProvider.notifier)
                      .addReaction(announcement, name);
                } catch (_) {
                  if (context.mounted) {
                    showErrorSnackBar(context, 'リアクション追加に失敗しました');
                  }
                }
              },
            ),
          ),
        );
      },
    );
  }
}
