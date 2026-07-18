// lib/widgets/settings_section.dart

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

/// Android (Pixel) の「設定」アプリと同じ見た目を提供する設定用コンテナ。
///
/// オプションのセクションタイトル + 角丸の Material コンテナに子要素
/// (`ListTile` / `SwitchListTile` 等) を縦に並べる。コンテナ内では
/// `Divider` を入れず、視覚的なグルーピングはコンテナの角丸と背景色で
/// 表現する。
///
/// 例:
/// ```dart
/// SettingsSection(
///   title: 'テーマ',
///   children: [
///     ListTile(title: Text('テーマモード')),
///     SwitchListTile(title: Text('...')),
///   ],
/// )
/// ```
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    this.title,
    required this.children,
  });

  /// セクション上部に表示する見出し。null なら見出し無し。
  final String? title;

  /// セクション内に縦に並べる子要素 (`ListTile`, `SwitchListTile` 等)。
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      // 左右はカード間のインセット。下は次セクションとの間隔。
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Text(
                title!,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          Material(
            // M3 の surfaceContainer はライト/ダーク両方で
            // scaffoldBackground より少しだけ上に浮き上がって見える色。
            color: theme.colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

/// Android 設定アプリ風のページで、`Scaffold.body` のルートに使う `ListView`。
///
/// `SettingsSection` を縦に並べる時に上下の余白を統一するためのラッパー。
///
/// デスクトップ (Windows/macOS/Linux) では常時表示のスクロールバーを付ける。
/// 設定ページは Slider などポインタ操作を奪う要素が多く、万一ホイール
/// スクロールが効かなくなってもバーのドラッグで確実にスクロールできる
/// 逃げ道を確保するため。
class SettingsListView extends StatefulWidget {
  const SettingsListView({
    super.key,
    required this.children,
  });

  final List<Widget> children;

  @override
  State<SettingsListView> createState() => _SettingsListViewState();
}

class _SettingsListViewState extends State<SettingsListView> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isDesktop => switch (defaultTargetPlatform) {
        TargetPlatform.windows ||
        TargetPlatform.macOS ||
        TargetPlatform.linux =>
          true,
        _ => false,
      };

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      thumbVisibility: _isDesktop,
      child: ListView(
        controller: _controller,
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: widget.children,
      ),
    );
  }
}
