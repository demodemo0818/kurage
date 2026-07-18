// lib/pages/appearance_page.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/settings_provider.dart';
import '../utils/app_fonts.dart';
import '../widgets/settings_section.dart';

/// 外観設定画面 (Android「設定」アプリ風レイアウト)
class AppearanceSettingsPage extends ConsumerWidget {
  const AppearanceSettingsPage({super.key});

  // プリセットカラー（Material 3推奨色）
  static final List<Color> _presetColors = [
    const Color(0xFF6750A4), // デフォルトの紫
    Colors.blue,
    Colors.teal,
    Colors.green,
    Colors.orange,
    Colors.deepOrange,
    Colors.pink,
    Colors.red,
    Colors.indigo,
    Colors.cyan,
    Colors.amber,
    Colors.brown,
  ];

  /// フォント設定の現在値ラベル。null = 端末デフォルト。
  String _fontLabel(String? key) {
    if (key == null) return '端末デフォルト';
    return appFontByKey(key)?.label ?? key;
  }

  Future<void> _showFontPicker(
    BuildContext context,
    String? current,
    SettingsNotifier notifier,
  ) async {
    // null (端末デフォルト) と「ダイアログ外タップ = キャンセル (null 返却)」を
    // 区別するため、端末デフォルトには専用センチネルを割り当てて pop する。
    // SimpleDialog<String?> だと両者が区別できない。
    const deviceDefault = '__device_default__';
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('フォント'),
        children: [
          RadioListTile<String>(
            title: const Text('端末デフォルト'),
            subtitle: const Text('OS のフォント（ダウンロードなし）'),
            value: deviceDefault,
            // ignore: deprecated_member_use
            groupValue: current ?? deviceDefault,
            // ignore: deprecated_member_use
            onChanged: (v) => Navigator.pop(context, v),
          ),
          for (final font in kAppFonts)
            RadioListTile<String>(
              title: Text(font.label),
              value: font.key,
              // ignore: deprecated_member_use
              groupValue: current ?? deviceDefault,
              // ignore: deprecated_member_use
              onChanged: (v) => Navigator.pop(context, v),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Text(
              'フォントを変更すると初回はダウンロードが発生し、その分'
              'キャッシュ（端末ストレージ）が増えます。日本語フォントは字数が'
              '多く、1 書体あたり数 MB〜十数 MB になることがあります。'
              '2 回目以降はキャッシュから読み込みます。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
    if (selected == null) return; // キャンセル
    final newKey = selected == deviceDefault ? null : selected;
    if (newKey != current) {
      await notifier.setFontFamily(newKey);
    }
  }

  String _themeModeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'ライト';
      case ThemeMode.dark:
        return 'ダーク';
      case ThemeMode.system:
        return 'システム設定に追従';
    }
  }

  Future<void> _showThemeModePicker(
    BuildContext context,
    ThemeMode current,
    SettingsNotifier notifier,
  ) async {
    final selected = await showDialog<ThemeMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('テーマモード'),
        children: [
          for (final mode in ThemeMode.values)
            RadioListTile<ThemeMode>(
              title: Text(_themeModeLabel(mode)),
              value: mode,
              // ignore: deprecated_member_use
              groupValue: current,
              // ignore: deprecated_member_use
              onChanged: (v) => Navigator.pop(context, v),
            ),
        ],
      ),
    );
    if (selected != null && selected != current) {
      await notifier.setThemeMode(selected);
    }
  }

  String _timelineLayoutLabel(TimelineLayout layout) {
    switch (layout) {
      case TimelineLayout.line:
        return '線で区切る';
      case TimelineLayout.card:
        return 'カードで区切る';
    }
  }

  String _mediaLayoutLabel(MediaLayout layout) {
    switch (layout) {
      case MediaLayout.horizontal:
        return '横スクロール';
      case MediaLayout.grid:
        return 'グリッド表示';
    }
  }

  Future<void> _showMediaLayoutPicker(
    BuildContext context,
    MediaLayout current,
    SettingsNotifier notifier,
  ) async {
    final selected = await showDialog<MediaLayout>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('サムネイル表示'),
        children: [
          for (final layout in MediaLayout.values)
            RadioListTile<MediaLayout>(
              title: Text(_mediaLayoutLabel(layout)),
              subtitle: Text(
                layout == MediaLayout.horizontal
                    ? '高さ固定の横並びで一覧表示'
                    : '枚数に合わせてタイル状に並べる (1〜4 枚、それ以上は +N)',
              ),
              value: layout,
              // ignore: deprecated_member_use
              groupValue: current,
              // ignore: deprecated_member_use
              onChanged: (v) => Navigator.pop(context, v),
            ),
        ],
      ),
    );
    if (selected != null && selected != current) {
      await notifier.setMediaLayout(selected);
    }
  }

  String _ogpLayoutLabel(OgpLayout layout) {
    switch (layout) {
      case OgpLayout.standard:
        return '大きく表示';
      case OgpLayout.compact:
        return 'コンパクト表示';
    }
  }

  Future<void> _showOgpLayoutPicker(
    BuildContext context,
    OgpLayout current,
    SettingsNotifier notifier,
  ) async {
    final selected = await showDialog<OgpLayout>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('リンクプレビュー表示'),
        children: [
          for (final layout in OgpLayout.values)
            RadioListTile<OgpLayout>(
              title: Text(_ogpLayoutLabel(layout)),
              subtitle: Text(
                layout == OgpLayout.standard
                    ? '従来の 16:9 ヘッダー画像 + 題名 + 説明'
                    : '左に小サムネ + 題名・ドメインを横並びで省スペース表示',
              ),
              value: layout,
              // ignore: deprecated_member_use
              groupValue: current,
              // ignore: deprecated_member_use
              onChanged: (v) => Navigator.pop(context, v),
            ),
        ],
      ),
    );
    if (selected != null && selected != current) {
      await notifier.setOgpLayout(selected);
    }
  }

  Future<void> _showTimelineLayoutPicker(
    BuildContext context,
    TimelineLayout current,
    SettingsNotifier notifier,
  ) async {
    final selected = await showDialog<TimelineLayout>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('タイムラインの区切り'),
        children: [
          for (final layout in TimelineLayout.values)
            RadioListTile<TimelineLayout>(
              title: Text(_timelineLayoutLabel(layout)),
              subtitle: Text(
                layout == TimelineLayout.line
                    ? '従来の細い水平線'
                    : '各投稿を角丸カードで囲む',
              ),
              value: layout,
              // ignore: deprecated_member_use
              groupValue: current,
              // ignore: deprecated_member_use
              onChanged: (v) => Navigator.pop(context, v),
            ),
        ],
      ),
    );
    if (selected != null && selected != current) {
      await notifier.setTimelineLayout(selected);
    }
  }

  Future<void> _showColorPicker(
    BuildContext context,
    Color currentColor,
    SettingsNotifier notifier,
  ) async {
    Color selectedColor = currentColor;

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('テーマカラーを選択'),
        content: StatefulBuilder(
          builder: (context, setState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 現在の色
              Container(
                width: 60,
                height: 60,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: selectedColor,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).dividerColor,
                    width: 2,
                  ),
                ),
              ),
              // プリセットカラー
              const Text(
                'プリセットカラー',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _presetColors.map((color) {
                  final isSelected = selectedColor == color;
                  return InkWell(
                    onTap: () {
                      setState(() {
                        selectedColor = color;
                      });
                    },
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).dividerColor,
                          width: isSelected ? 3 : 1,
                        ),
                      ),
                      child: isSelected
                          ? const Icon(
                              Icons.check,
                              color: Colors.white,
                              size: 20,
                            )
                          : null,
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              // カスタムカラー（スライダー）
              const Text(
                'カスタムカラー',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              // 色相スライダー
              Row(
                children: [
                  const Text('色相'),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Slider(
                      value: HSVColor.fromColor(selectedColor).hue,
                      min: 0,
                      max: 360,
                      onChanged: (value) {
                        setState(() {
                          final hsv = HSVColor.fromColor(selectedColor);
                          selectedColor = hsv.withHue(value).toColor();
                        });
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              notifier.setThemeColor(selectedColor);
              Navigator.of(context).pop();
            },
            child: const Text('適用'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Settings とその Notifier を取得
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('外観設定')),
      body: SettingsListView(
        children: [
          // ========== テーマ設定 ==========
          SettingsSection(
            title: 'テーマ',
            children: [
              ListTile(
                leading: const Icon(Icons.brightness_6, color: Colors.amber),
                title: const Text('テーマモード'),
                subtitle: Text(_themeModeLabel(settings.themeMode)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    _showThemeModePicker(context, settings.themeMode, notifier),
              ),
              ListTile(
                title: const Text('テーマカラー'),
                subtitle: const Text('アプリ全体のアクセントカラーを変更します'),
                leading: const Icon(Icons.color_lens, color: Colors.pink),
                trailing: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: settings.themeColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context).dividerColor,
                      width: 1,
                    ),
                  ),
                ),
                onTap: () async {
                  await _showColorPicker(context, settings.themeColor, notifier);
                },
              ),
            ],
          ),

          // ========== タイムライン表示 ==========
          SettingsSection(
            title: 'タイムライン表示',
            children: [
              ListTile(
                leading:
                    const Icon(Icons.dashboard_customize, color: Colors.purple),
                title: const Text('投稿の区切り'),
                subtitle: Text(_timelineLayoutLabel(settings.timelineLayout)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showTimelineLayoutPicker(
                  context,
                  settings.timelineLayout,
                  notifier,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.grid_view, color: Colors.teal),
                title: const Text('サムネイル表示'),
                subtitle: Text(_mediaLayoutLabel(settings.mediaLayout)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showMediaLayoutPicker(
                  context,
                  settings.mediaLayout,
                  notifier,
                ),
              ),
              // 画像のサムネイルサイズは横スクロール表示でのみ有効
              // (グリッド表示は枚数と画面幅に合わせて自動サイズになり photoSize を
              // 参照しない)。無効な設定を見せないよう、横スクロール表示のときだけ
              // サムネイル表示の直下に出す。
              if (settings.mediaLayout == MediaLayout.horizontal)
                _SliderTile(
                  icon: Icons.photo_size_select_large,
                  iconColor: Colors.pink,
                  title: '画像のサムネイルサイズ',
                  value: settings.photoSize,
                  min: 60,
                  max: 200,
                  divisions: 14,
                  label: '${settings.photoSize.toStringAsFixed(0)}px',
                  description: 'タイムラインに並ぶ画像サムネイルの大きさ (横スクロール表示のみ)',
                  onChanged: notifier.setPhotoSize,
                ),
              ListTile(
                leading: const Icon(Icons.link, color: Colors.indigo),
                title: const Text('リンクプレビュー表示'),
                subtitle: Text(_ogpLayoutLabel(settings.ogpLayout)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showOgpLayoutPicker(
                  context,
                  settings.ogpLayout,
                  notifier,
                ),
              ),
              SwitchListTile(
                title: const Text('相対時間を表示'),
                subtitle: const Text('「5分前」のような相対的な時間表示を使用'),
                value: settings.useRelativeTime,
                onChanged: notifier.setUseRelativeTime,
                secondary:
                    const Icon(Icons.access_time, color: Colors.blueGrey),
              ),
              SwitchListTile(
                title: const Text('ユーザーIDを表示'),
                subtitle: const Text('@username@domain の形式でユーザーIDを表示'),
                value: settings.showUserId,
                onChanged: notifier.setShowUserId,
                secondary:
                    const Icon(Icons.alternate_email, color: Colors.blue),
              ),
              SwitchListTile(
                title: const Text('投稿アクションバーを常に表示'),
                subtitle: const Text('返信・ブースト・お気に入りボタンを常に表示'),
                value: settings.showPostActions,
                onChanged: notifier.setShowPostActions,
                secondary: const Icon(Icons.touch_app, color: Colors.green),
              ),
              SwitchListTile(
                title: const Text('リアクション数を表示'),
                subtitle: const Text('ブーストやお気に入りの数を表示'),
                value: settings.showReactionCounts,
                onChanged: notifier.setShowReactionCounts,
                secondary: const Icon(Icons.numbers, color: Colors.orange),
              ),
              SwitchListTile(
                title: const Text('投稿元アプリを表示'),
                subtitle: const Text(
                    '投稿元クライアント名を表示 (投稿者が開示している場合のみ)'),
                value: settings.showVia,
                onChanged: notifier.setShowVia,
                secondary:
                    const Icon(Icons.smartphone, color: Colors.blueGrey),
              ),
            ],
          ),

          // ========== 通知表示 ==========
          SettingsSection(
            title: '通知表示',
            children: [
              SwitchListTile(
                secondary:
                    const Icon(Icons.layers_outlined, color: Colors.deepPurple),
                title: const Text('通知をグルーピング表示'),
                subtitle: const Text(
                    '同じ投稿への複数リアクションを「○○さん 他N人が…」とまとめます (Mastodon 4.3+)'),
                value: settings.groupedNotifications,
                onChanged: notifier.setGroupedNotifications,
              ),
            ],
          ),

          // ========== 文字とレイアウト ==========
          SettingsSection(
            title: '文字とレイアウト',
            children: [
              ListTile(
                leading:
                    const Icon(Icons.font_download, color: Colors.indigo),
                title: const Text('フォント'),
                subtitle: Text(_fontLabel(settings.fontFamily)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    _showFontPicker(context, settings.fontFamily, notifier),
              ),
              _SliderTile(
                icon: Icons.format_size,
                iconColor: Colors.indigo,
                title: '文字サイズ',
                value: settings.fontSize,
                min: 10,
                max: 24,
                divisions: 14,
                label: '${settings.fontSize.toStringAsFixed(0)}pt',
                description: '',
                onChanged: notifier.setFontSize,
              ),
              _SliderTile(
                icon: Icons.format_line_spacing,
                iconColor: Colors.deepPurple,
                title: '行間',
                value: settings.lineHeight,
                min: 1.0,
                max: 2.0,
                divisions: 10,
                label: '${settings.lineHeight.toStringAsFixed(1)}倍',
                description: '本文の行間',
                onChanged: notifier.setLineHeight,
              ),
              _SliderTile(
                icon: Icons.unfold_less,
                iconColor: Colors.brown,
                title: '投稿の折りたたみ行数',
                value: settings.collapseAfterLines.toDouble(),
                min: 0,
                max: 20,
                divisions: 20,
                label: settings.collapseAfterLines == 0
                    ? '無効'
                    : '${settings.collapseAfterLines}行',
                description: settings.collapseAfterLines == 0
                    ? '無効（すべて表示）'
                    : '${settings.collapseAfterLines}行を超える投稿を折りたたみます',
                onChanged: (v) =>
                    notifier.setCollapseAfterLines(v.toInt()),
              ),
            ],
          ),

          // ========== アイコンとボタン ==========
          SettingsSection(
            title: 'アイコンとボタン',
            children: [
              _SliderTile(
                icon: Icons.account_circle,
                iconColor: Colors.blue,
                title: 'アイコンのサイズ',
                value: settings.avatarSize,
                min: 24,
                max: 72,
                divisions: 12,
                label: '${settings.avatarSize.toStringAsFixed(0)}px',
                description: 'プロフィールアイコンの直径',
                onChanged: notifier.setAvatarSize,
              ),
              SwitchListTile(
                title: const Text('アイコンを四角表示'),
                subtitle: const Text('プロフィールアイコンを四角形で表示'),
                value: settings.isAvatarSquare,
                onChanged: notifier.setAvatarSquare,
                secondary: const Icon(Icons.crop_square, color: Colors.teal),
              ),
              _SliderTile(
                icon: Icons.star_border,
                iconColor: Colors.amber,
                title: 'アクションボタンのサイズ',
                value: settings.actionIconSize,
                min: 16,
                max: 32,
                divisions: 16,
                label: '${settings.actionIconSize.toStringAsFixed(0)}px',
                description: '返信・ブースト・お気に入りボタン',
                onChanged: notifier.setActionIconSize,
              ),
            ],
          ),

          // ========== カスタム絵文字 ==========
          SettingsSection(
            title: 'カスタム絵文字',
            children: [
              _SliderTile(
                icon: Icons.badge,
                iconColor: Colors.orange,
                title: '表示名での絵文字サイズ',
                value: settings.emojiScaleInDisplayName,
                min: 0.4,
                max: 4.0,
                divisions: 18,
                label: '${(settings.emojiScaleInDisplayName * 100).round()}%',
                description: 'ユーザー名内のカスタム絵文字',
                onChanged: notifier.setEmojiScaleInDisplayName,
              ),
              _SliderTile(
                icon: Icons.text_snippet,
                iconColor: Colors.green,
                title: '本文での絵文字サイズ',
                value: settings.emojiScale,
                min: 0.4,
                max: 4.0,
                divisions: 18,
                label: '${(settings.emojiScale * 100).round()}%',
                description: '投稿本文内のカスタム絵文字',
                onChanged: notifier.setEmojiScale,
              ),
            ],
          ),

          // アニメーション (カスタム絵文字に紐付くサブセクション)
          SettingsSection(
            title: 'アニメーション',
            children: [
              SwitchListTile(
                title: const Text('表示名でのアニメーションを無効化'),
                subtitle: const Text('ユーザー名のカスタム絵文字アニメーションを停止'),
                value: settings.disableCustomEmojiAnimationInDisplayName,
                onChanged:
                    notifier.setDisableCustomEmojiAnimationInDisplayName,
                secondary: const Icon(Icons.gif_box_outlined,
                    color: Colors.deepPurple),
              ),
              SwitchListTile(
                title: const Text('本文でのアニメーションを無効化'),
                subtitle: const Text('投稿本文のカスタム絵文字アニメーションを停止'),
                value: settings.disableCustomEmojiAnimationInContent,
                onChanged: notifier.setDisableCustomEmojiAnimationInContent,
                secondary:
                    const Icon(Icons.movie_filter_outlined, color: Colors.teal),
              ),
            ],
          ),

          // ========== メディアとコンテンツ ==========
          SettingsSection(
            title: 'メディアとコンテンツ',
            children: [
              SwitchListTile(
                title: const Text('メディアのぼかしを常に解除'),
                subtitle: const Text('NSFW や CW のメディアも、常にぼかしなしで表示'),
                value: settings.disableMediaBlur,
                onChanged: notifier.setDisableMediaBlur,
                secondary: const Icon(Icons.blur_off, color: Colors.cyan),
              ),
              SwitchListTile(
                title: const Text('CWを常に開く'),
                subtitle: const Text('コンテンツ警告のある投稿を常に展開表示'),
                value: settings.alwaysExpandCW,
                onChanged: notifier.setAlwaysExpandCW,
                secondary: const Icon(Icons.visibility, color: Colors.amber),
              ),
            ],
          ),

          const SizedBox(height: 24), // 底部に余白
        ],
      ),
    );
  }
}

/// `SettingsSection` 内に置くスライダー付きの設定行。
/// 通常の `ListTile` だとスライダーを subtitle に押し込む必要があり
/// レイアウトが崩れるため、独立した `StatelessWidget` として用意する。
class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.description,
    required this.onChanged,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final String description;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 16),
            child: Icon(icon, color: iconColor),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
                Slider(
                  min: min,
                  max: max,
                  divisions: divisions,
                  value: value,
                  label: label,
                  onChanged: onChanged,
                ),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.textTheme.bodySmall?.color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
