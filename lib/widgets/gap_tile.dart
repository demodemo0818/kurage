// lib/widgets/gap_tile.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/timeline_gap.dart';
import '../providers/settings_provider.dart';

/// タイムライン上のギャップを表示するタイル
class GapTile extends ConsumerWidget {
  final TimelineGap gap;
  final VoidCallback? onTap;
  final VoidCallback? onTapKeepTop;
  final VoidCallback? onTapKeepBottom;

  const GapTile({
    super.key,
    required this.gap,
    this.onTap,
    this.onTapKeepTop,
    this.onTapKeepBottom,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // build で使うのは themeColor / fontSize の 2 つだけ。Settings 全体を watch
    // すると他フィールドの変更でタイムライン中のギャップタイル全てが rebuild
    // するので、.select で限定購読する。
    final settings = ref.watch(settingsProvider.select((s) => (
      themeColor: s.themeColor,
      fontSize: s.fontSize,
    )));
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Card(
        elevation: 1,
        color: isDarkMode 
            ? Colors.grey.shade800.withValues(alpha: 0.6)
            : Colors.grey.shade50,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: gap.isLoading 
                ? settings.themeColor 
                : (isDarkMode ? Colors.grey.shade600 : Colors.grey.shade300),
            width: 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          // 注意: ローディング中も非ローディング時と同じ Column レイアウトを
          // 維持する。高さが変わると `_fillGap` 中にギャップ下のコンテンツが
          // 上下に揺れ、`keepBottom` の位置ピン留めが視覚的に破綻するため。
          // ローディング時はヘッダー行の中身を「投稿を読み込み中...」+
          // スピナーに差し替え、ボタン行はボタンを disabled で残す。
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (gap.isLoading) ...[
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: settings.themeColor,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      context.l10n.gapLoading,
                      style: TextStyle(
                        fontSize: settings.fontSize,
                        fontWeight: FontWeight.w500,
                        color: settings.themeColor,
                      ),
                    ),
                  ] else ...[
                    Icon(
                      Icons.more_horiz,
                      color: settings.themeColor,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      context.l10n.gapLoadPrompt,
                      style: TextStyle(
                        fontSize: settings.fontSize,
                        fontWeight: FontWeight.w500,
                        color: isDarkMode
                            ? Colors.grey.shade300
                            : Colors.grey.shade700,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              // 2つのボタンオプション
              if (onTapKeepTop != null && onTapKeepBottom != null) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: gap.isLoading ? null : onTapKeepTop,
                        icon:
                            const Icon(Icons.vertical_align_top, size: 16),
                        label: Text(context.l10n.gapKeepUpper),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          foregroundColor: isDarkMode
                              ? Colors.grey.shade300
                              : Colors.grey.shade700,
                          side: BorderSide(
                            color: isDarkMode
                                ? Colors.grey.shade600
                                : Colors.grey.shade300,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: gap.isLoading ? null : onTapKeepBottom,
                        icon: const Icon(Icons.vertical_align_bottom,
                            size: 16),
                        label: Text(context.l10n.gapKeepLower),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          foregroundColor: isDarkMode
                              ? Colors.grey.shade300
                              : Colors.grey.shade700,
                          side: BorderSide(
                            color: isDarkMode
                                ? Colors.grey.shade600
                                : Colors.grey.shade300,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ] else if (onTap != null) ...[
                // 互換性のための既存のタップ処理
                OutlinedButton.icon(
                  onPressed: gap.isLoading ? null : onTap,
                  icon: const Icon(Icons.download, size: 16),
                  label: Text(context.l10n.gapLoad),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: isDarkMode
                        ? Colors.grey.shade300
                        : Colors.grey.shade700,
                    side: BorderSide(
                      color: isDarkMode
                          ? Colors.grey.shade600
                          : Colors.grey.shade300,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}