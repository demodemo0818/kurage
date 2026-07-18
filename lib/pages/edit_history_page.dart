// lib/pages/edit_history_page.dart

import '../widgets/network_image_x.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auth_account.dart';
import '../models/media_attachment.dart';
import '../models/poll.dart';
import '../models/status_edit.dart';
import '../providers/settings_provider.dart';
import '../services/mastodon_api.dart';
import '../utils/html_parser.dart';
import '../utils/snackbar_helpers.dart';
import '../utils/time_formatter.dart';

/// 投稿の編集履歴ページ。
///
/// `GET /api/v1/statuses/:id/history` の結果を時系列で並べる。サーバから
/// 古い順に返ってくるが、UI は「最新の編集」が一番上の方が読みやすいので
/// ここで reverse して表示する。各バージョンには「初版」「N 回目の編集」
/// というラベルと相対/絶対時刻を表示する。
class EditHistoryPage extends ConsumerStatefulWidget {
  /// 履歴を取得する投稿の id (ローカルインスタンス上の id)
  final String statusId;

  /// 履歴取得 API を叩くアカウント
  final AuthAccount account;

  /// Deck ポップアップで最初のページとして開かれた時だけ非 null。AppBar の
  /// 戻る (←) でポップアップ全体を閉じるのに使う。
  final VoidCallback? onDeckBack;

  const EditHistoryPage({
    super.key,
    required this.statusId,
    required this.account,
    this.onDeckBack,
  });

  @override
  ConsumerState<EditHistoryPage> createState() => _EditHistoryPageState();
}

class _EditHistoryPageState extends ConsumerState<EditHistoryPage> {
  late Future<List<StatusEdit>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<StatusEdit>> _load() async {
    return fetchStatusHistory(
      instanceUrl: widget.account.instanceUrl,
      accessToken: widget.account.accessToken,
      statusId: widget.statusId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(
        leading: widget.onDeckBack == null
            ? null
            : BackButton(onPressed: widget.onDeckBack),
        title: const Text('編集履歴'),
        actions: [
          IconButton(
            tooltip: '再読み込み',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => _future = _load()),
          ),
        ],
      ),
      body: FutureBuilder<List<StatusEdit>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            // 取得失敗。ユーザーがリトライできるよう Scaffold 上に SnackBar
            // を出して操作可能なメッセージを表示する。
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                showErrorSnackBar(context, '編集履歴を取得できませんでした: ${snap.error}');
              }
            });
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '編集履歴を取得できませんでした。\n${snap.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final edits = snap.data ?? const <StatusEdit>[];
          if (edits.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'このサーバは編集履歴に対応していないか、履歴がありません',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          // サーバ返却順は古い → 新しい。最新が一番上のリストにする。
          // i = 0 が初版なので、表示用にラベルを作るときも元 index を使う。
          final reversed = edits.reversed.toList();
          final totalEdits = edits.length - 1; // 編集回数 (= 履歴件数 - 初版)

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: reversed.length,
            separatorBuilder: (_, _) => const Divider(height: 24),
            itemBuilder: (context, i) {
              final edit = reversed[i];
              final originalIndex = edits.length - 1 - i;
              final label = originalIndex == 0
                  ? '初版'
                  : '$originalIndex 回目の編集';
              return _EditEntry(
                edit: edit,
                label: label,
                isLatest: i == 0 && totalEdits >= 1,
                useRelativeTime: settings.useRelativeTime,
                fontSize: settings.fontSize,
                lineHeight: settings.lineHeight,
                emojiScale: settings.emojiScale,
                disableEmojiAnimation:
                    settings.disableCustomEmojiAnimationInContent,
              );
            },
          );
        },
      ),
    );
  }
}

class _EditEntry extends StatelessWidget {
  final StatusEdit edit;
  final String label;
  final bool isLatest;
  final bool useRelativeTime;
  final double fontSize;
  final double lineHeight;
  final double emojiScale;
  final bool disableEmojiAnimation;

  const _EditEntry({
    required this.edit,
    required this.label,
    required this.isLatest,
    required this.useRelativeTime,
    required this.fontSize,
    required this.lineHeight,
    required this.emojiScale,
    required this.disableEmojiAnimation,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final defaultStyle = DefaultTextStyle.of(context).style.copyWith(
          fontSize: fontSize,
          height: lineHeight,
        );
    final emojiSize = fontSize * emojiScale;

    final spans = parseContentWithEmojis(
      contentHtml: edit.content,
      emojis: edit.emojis,
      baseStyle: defaultStyle,
      linkColor: Colors.blue,
      emojiSize: emojiSize,
      context: context,
      disableEmojiAnimation: disableEmojiAnimation,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: isLatest
                      ? theme.colorScheme.primary
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  isLatest ? '$label (現在)' : label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isLatest
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TimeText(
                dt: edit.createdAt,
                useRelative: useRelativeTime,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.hintColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (edit.spoilerText.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.brightness == Brightness.dark
                    ? Colors.grey.shade800.withValues(alpha: 0.6)
                    : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(6),
              ),
              child: RichText(
                text: TextSpan(
                  style: defaultStyle,
                  children: [
                    TextSpan(
                      text: 'CW: ',
                      style: defaultStyle.copyWith(
                        fontWeight: FontWeight.w600,
                        color: Colors.orange.shade700,
                      ),
                    ),
                    TextSpan(text: edit.spoilerText),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
          ],
          if (edit.sensitive)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Icon(Icons.warning_amber,
                      size: 14, color: theme.hintColor),
                  const SizedBox(width: 4),
                  Text(
                    'NSFW (sensitive)',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.hintColor,
                    ),
                  ),
                ],
              ),
            ),
          RichText(text: TextSpan(children: spans)),
          if (edit.mediaAttachments.isNotEmpty) ...[
            const SizedBox(height: 8),
            _EditMediaThumbs(media: edit.mediaAttachments),
          ],
          if (edit.poll != null) ...[
            const SizedBox(height: 8),
            _EditPollPreview(poll: edit.poll!),
          ],
        ],
      ),
    );
  }
}

class _EditMediaThumbs extends StatelessWidget {
  // 履歴ページではメディアの ALT 文 / 中身は読めれば十分なので、
  // 投稿タイル側のフルギャラリーは作らずシンプルなサムネ列にする。
  final List<MediaAttachment> media;

  const _EditMediaThumbs({required this.media});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 80,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: media.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final m = media[i];
          final src = m.previewUrl.isNotEmpty ? m.previewUrl : m.url;
          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: src.isEmpty
                ? Container(
                    width: 80,
                    height: 80,
                    color: Colors.grey.shade300,
                    child: const Icon(Icons.broken_image),
                  )
                : KurageNetworkImage(
                    imageUrl: src,
                    width: 80,
                    height: 80,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => Container(
                      width: 80,
                      height: 80,
                      color: Colors.grey.shade300,
                    ),
                    errorWidget: (_, _, _) => Container(
                      width: 80,
                      height: 80,
                      color: Colors.grey.shade300,
                      child: const Icon(Icons.broken_image),
                    ),
                  ),
          );
        },
      ),
    );
  }
}

class _EditPollPreview extends StatelessWidget {
  // 投票はインタラクションなしで「この時点の選択肢」を一覧表示するだけ。
  final Poll poll;

  const _EditPollPreview({required this.poll});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final o in poll.options)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  const Icon(Icons.radio_button_off, size: 14),
                  const SizedBox(width: 6),
                  Expanded(child: Text(o.title)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
