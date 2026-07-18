// lib/widgets/timeline_post_decoration.dart
//
// 設定 (`Settings.timelineLayout`) に応じて、投稿セルの装飾と区切りを
// 切り替えるためのユーティリティ。
//
// - `line` (既定) : 従来どおり 1px の Divider を区切りに、投稿はそのまま表示。
// - `card`         : 各投稿を角丸の Material で囲み、区切りは 8px の余白。
//
// すべてのタイムライン系画面 (メイン TL / 通知 / プロフィール / 検索 /
// ハッシュタグ / スレッド 等) で同じ見た目を使うため、関数として共通化。

import 'package:flutter/material.dart';

import '../providers/settings_provider.dart';

/// 投稿セル (PostTile / 通知ヘッダ + PostTile 等) を `layout` に応じて装飾する。
///
/// `line` モードでは何もせずそのまま返す。`card` モードでは左右 8px の余白 +
/// 角丸 16 + `surfaceContainer` 色の Material で包む (elevation 0 のフラット)。
Widget wrapForTimelineLayout(
  BuildContext context,
  Widget child,
  TimelineLayout layout,
) {
  if (layout != TimelineLayout.card) return child;
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: child,
    ),
  );
}

/// 投稿セルの区切り。`line` は 1px の Divider、`card` は 8px の余白。
Widget timelineSeparator(TimelineLayout layout) {
  return layout == TimelineLayout.card
      ? const SizedBox(height: 8)
      : const Divider(height: 1);
}
