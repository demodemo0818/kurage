// lib/widgets/timeline_splitter.dart

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// 区切りバーの高さ (px)。ペインの高さ計算 (ドラッグ量 → 比率換算、
/// アンカー alignment の換算) で使うので [TimelineSplitter] の外にも公開する。
const double kTimelineSplitterHeight = 28;

/// タイムライン分割表示 (上 = ライブ / 下 = 履歴ペイン) の区切りバー。
///
/// - 縦ドラッグで分割位置を調整 ([onDragUpdate] に px 単位の移動量を渡し、
///   比率への換算と保存は呼び出し側が行う)。ダブルタップで既定比率に戻す
/// - 左端 ⇈: ライブペインを閉じ、履歴ペインの読書位置を残して分割解除
/// - 右端 ⇊: 履歴ペインを閉じ、ライブペインを残して分割解除
///
/// Fedibird の TimelineSplitter に倣った操作体系 (あちらは区切りの × で
/// 履歴を閉じ、ヘッダーのボタンでライブを閉じる)。Kurage はモバイルでは
/// カラムヘッダーが無いので両方をバーに置く。
class TimelineSplitter extends StatelessWidget {
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onReset;
  final VoidCallback onCloseLive;
  final VoidCallback onCloseHistory;

  const TimelineSplitter({
    super.key,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onReset,
    required this.onCloseLive,
    required this.onCloseHistory,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final border = BorderSide(color: theme.dividerColor, width: 0.5);

    Widget button(IconData icon, String tooltip, VoidCallback onPressed) {
      return IconButton(
        tooltip: tooltip,
        icon: Icon(icon),
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 28),
        onPressed: onPressed,
      );
    }

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Container(
        height: kTimelineSplitterHeight,
        decoration: BoxDecoration(border: Border(top: border, bottom: border)),
        child: Row(
          children: [
            button(
              Icons.keyboard_double_arrow_up,
              context.l10n.timelineCloseLivePane,
              onCloseLive,
            ),
            Expanded(
              child: Semantics(
                label: context.l10n.timelineSplitter,
                child: Tooltip(
                  message: context.l10n.timelineSplitter,
                  waitDuration: const Duration(milliseconds: 800),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeRow,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: (d) => onDragUpdate(d.delta.dy),
                      onVerticalDragEnd: (_) => onDragEnd(),
                      onVerticalDragCancel: onDragEnd,
                      onDoubleTap: onReset,
                      child: Center(
                        child: Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            button(
              Icons.keyboard_double_arrow_down,
              context.l10n.timelineCloseHistoryPane,
              onCloseHistory,
            ),
          ],
        ),
      ),
    );
  }
}
