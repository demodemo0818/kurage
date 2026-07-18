// lib/widgets/column_header.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import 'user_avatar.dart';

/// ワイドレイアウト (デスクトップ / タブレット) でカラムの上部に出すヘッダー。
///
/// - アバター (複数ソースなら並べる) + タイムライン種別ラベル
/// - 右端に 🔄 リフレッシュ + ⋮ メニュー (カラムを編集 / 削除)
/// - ヘッダー本体 (ボタン以外) のタップで scroll-to-top
///
/// モバイル (narrow) では AppBar 側に同等情報があるためこの widget は
/// 使わない (main_page.dart の wide 分岐内でだけ生やす)。
class ColumnHeader extends ConsumerWidget {
  final Map<String, dynamic> column;
  final VoidCallback onRefresh;
  final VoidCallback onScrollToTop;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  /// `list_<id>` 形式の timelineType を実名に解決するための事前ロード済み
  /// マップ。`MainPage._listNames` を渡してもらう前提。マッピング無しの
  /// 場合は "リスト" 表記でフォールバック。
  final Map<String, String> listNames;

  const ColumnHeader({
    super.key,
    required this.column,
    required this.onRefresh,
    required this.onScrollToTop,
    required this.onEdit,
    required this.onDelete,
    this.listNames = const {},
  });

  static const _timelineTypeIcons = {
    'home': Icons.home,
    'local': Icons.people,
    'federated': Icons.public,
    'favourites': Icons.star,
    'bookmarks': Icons.bookmark,
    'lists': Icons.list,
    'notifications': Icons.notifications,
  };

  static const _timelineTypeLabels = {
    'home': 'ホーム',
    'local': 'ローカル',
    'federated': '連合',
    'favourites': 'お気に入り',
    'bookmarks': 'ブックマーク',
    'notifications': '通知',
  };

  String _getTimelineTypeLabel(String type) {
    if (type.startsWith('list_')) {
      final listId = type.substring(5);
      return listNames[listId] ?? 'リスト';
    }
    return _timelineTypeLabels[type] ?? type;
  }

  IconData _getTimelineTypeIcon(String type) {
    if (type.startsWith('list_')) return Icons.list;
    return _timelineTypeIcons[type] ?? Icons.timeline;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accounts = ref.watch(authProvider).accounts;
    final sources = (column['sources'] as List?) ?? const [];
    final title = (column['title'] as String?) ?? '';

    final children = <Widget>[];
    for (var i = 0; i < sources.length; i++) {
      final source = sources[i] as Map;
      final accountId = source['accountId'] as String?;
      final timelineType = (source['timelineType'] as String?) ?? 'home';

      if (accountId == null) continue;

      String avatarUrl = '';
      Color? accountColor;
      if (accounts.isNotEmpty) {
        final account = accounts.firstWhere(
          (a) => a.id == accountId,
          orElse: () => accounts.first,
        );
        avatarUrl = account.avatarUrl;
        accountColor = account.accountColor;
      }

      // 種別アイコン (タイムラインタイプ。アカウントカラーで塗る)
      children.add(Icon(
        _getTimelineTypeIcon(timelineType),
        size: 16,
        color: accountColor ?? theme.colorScheme.onSurface,
      ));
      children.add(const SizedBox(width: 4));
      // アカウントアイコン (小)
      children.add(UserAvatar(url: avatarUrl, radius: 10));
      children.add(const SizedBox(width: 6));
      // ラベル。カラム名が付いている場合はカラム名を優先し、種別ラベルは
      // 省略する (複数ソース時に各ラベルが極端に圧縮されるのを防ぐ)。
      if (title.isEmpty) {
        children.add(
          Flexible(
            child: Text(
              _getTimelineTypeLabel(timelineType),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        );
      }
      if (i < sources.length - 1) {
        children.add(const SizedBox(width: 8));
      }
    }

    if (title.isNotEmpty) {
      children.add(const SizedBox(width: 2));
      children.add(
        Flexible(
          child: Text(
            title,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
      );
    }

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: onScrollToTop,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: theme.dividerColor,
                width: 0.5,
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Row(children: children),
              ),
              IconButton(
                tooltip: '更新',
                icon: const Icon(Icons.refresh),
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
                onPressed: onRefresh,
              ),
              PopupMenuButton<String>(
                tooltip: 'カラム操作',
                icon: const Icon(Icons.more_vert, size: 18),
                padding: EdgeInsets.zero,
                onSelected: (v) {
                  switch (v) {
                    case 'edit':
                      onEdit();
                      break;
                    case 'delete':
                      onDelete();
                      break;
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        Icon(Icons.tune, size: 18),
                        SizedBox(width: 8),
                        Text('カラムを編集'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline, size: 18),
                        SizedBox(width: 8),
                        Text('このカラムを削除'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
