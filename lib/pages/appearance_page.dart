// lib/pages/appearance_page.dart

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
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
  String _fontLabel(BuildContext context, String? key) {
    if (key == null) return context.l10n.appearanceFontDeviceDefault;
    return appFontByKey(key)?.label(context) ?? key;
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
        title: Text(context.l10n.appearanceFontTitle),
        children: [
          RadioListTile<String>(
            title: Text(context.l10n.appearanceFontDeviceDefault),
            subtitle: Text(context.l10n.appearanceFontDeviceDefaultSubtitle),
            value: deviceDefault,
            // ignore: deprecated_member_use
            groupValue: current ?? deviceDefault,
            // ignore: deprecated_member_use
            onChanged: (v) => Navigator.pop(context, v),
          ),
          for (final font in kAppFonts)
            RadioListTile<String>(
              title: Text(font.label(context)),
              value: font.key,
              // ignore: deprecated_member_use
              groupValue: current ?? deviceDefault,
              // ignore: deprecated_member_use
              onChanged: (v) => Navigator.pop(context, v),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Text(
              context.l10n.appearanceFontDownloadNote,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
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

  String _themeModeLabel(BuildContext context, ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return context.l10n.appearanceThemeModeLight;
      case ThemeMode.dark:
        return context.l10n.appearanceThemeModeDark;
      case ThemeMode.system:
        return context.l10n.appearanceThemeModeSystem;
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
        title: Text(context.l10n.appearanceThemeModeTitle),
        children: [
          for (final mode in ThemeMode.values)
            RadioListTile<ThemeMode>(
              title: Text(_themeModeLabel(context, mode)),
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

  String _timelineLayoutLabel(BuildContext context, TimelineLayout layout) {
    switch (layout) {
      case TimelineLayout.line:
        return context.l10n.appearanceTimelineLayoutLine;
      case TimelineLayout.card:
        return context.l10n.appearanceTimelineLayoutCard;
    }
  }

  String _mediaLayoutLabel(BuildContext context, MediaLayout layout) {
    switch (layout) {
      case MediaLayout.horizontal:
        return context.l10n.appearanceMediaLayoutHorizontal;
      case MediaLayout.grid:
        return context.l10n.appearanceMediaLayoutGrid;
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
        title: Text(context.l10n.appearanceMediaLayoutTitle),
        children: [
          for (final layout in MediaLayout.values)
            RadioListTile<MediaLayout>(
              title: Text(_mediaLayoutLabel(context, layout)),
              subtitle: Text(
                layout == MediaLayout.horizontal
                    ? context.l10n.appearanceMediaLayoutHorizontalDesc
                    : context.l10n.appearanceMediaLayoutGridDesc,
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

  String _ogpLayoutLabel(BuildContext context, OgpLayout layout) {
    switch (layout) {
      case OgpLayout.standard:
        return context.l10n.appearanceOgpStandard;
      case OgpLayout.compact:
        return context.l10n.appearanceOgpCompact;
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
        title: Text(context.l10n.appearanceOgpTitle),
        children: [
          for (final layout in OgpLayout.values)
            RadioListTile<OgpLayout>(
              title: Text(_ogpLayoutLabel(context, layout)),
              subtitle: Text(
                layout == OgpLayout.standard
                    ? context.l10n.appearanceOgpStandardDesc
                    : context.l10n.appearanceOgpCompactDesc,
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
        title: Text(context.l10n.appearanceTimelineLayoutPickerTitle),
        children: [
          for (final layout in TimelineLayout.values)
            RadioListTile<TimelineLayout>(
              title: Text(_timelineLayoutLabel(context, layout)),
              subtitle: Text(
                layout == TimelineLayout.line
                    ? context.l10n.appearanceTimelineLayoutLineDesc
                    : context.l10n.appearanceTimelineLayoutCardDesc,
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
        title: Text(context.l10n.appearanceColorPickerTitle),
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
              Text(
                context.l10n.appearancePresetColors,
                style: const TextStyle(fontWeight: FontWeight.bold),
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
              Text(
                context.l10n.appearanceCustomColor,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              // 色相スライダー
              Row(
                children: [
                  Text(context.l10n.appearanceHue),
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
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              notifier.setThemeColor(selectedColor);
              Navigator.of(context).pop();
            },
            child: Text(context.l10n.appearanceApply),
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
      appBar: AppBar(title: Text(context.l10n.appearanceTitle)),
      body: SettingsListView(
        children: [
          // ========== テーマ設定 ==========
          SettingsSection(
            title: context.l10n.appearanceSectionTheme,
            children: [
              ListTile(
                leading: const Icon(Icons.brightness_6, color: Colors.amber),
                title: Text(context.l10n.appearanceThemeModeTitle),
                subtitle: Text(_themeModeLabel(context, settings.themeMode)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    _showThemeModePicker(context, settings.themeMode, notifier),
              ),
              ListTile(
                title: Text(context.l10n.appearanceThemeColorTitle),
                subtitle: Text(context.l10n.appearanceThemeColorSubtitle),
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
            title: context.l10n.appearanceSectionTimeline,
            children: [
              ListTile(
                leading:
                    const Icon(Icons.dashboard_customize, color: Colors.purple),
                title: Text(context.l10n.appearancePostSeparatorTitle),
                subtitle: Text(
                    _timelineLayoutLabel(context, settings.timelineLayout)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showTimelineLayoutPicker(
                  context,
                  settings.timelineLayout,
                  notifier,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.grid_view, color: Colors.teal),
                title: Text(context.l10n.appearanceMediaLayoutTitle),
                subtitle: Text(_mediaLayoutLabel(context, settings.mediaLayout)),
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
                  title: context.l10n.appearancePhotoSizeTitle,
                  value: settings.photoSize,
                  min: 60,
                  max: 200,
                  divisions: 14,
                  label: '${settings.photoSize.toStringAsFixed(0)}px',
                  description: context.l10n.appearancePhotoSizeDesc,
                  onChanged: notifier.setPhotoSize,
                ),
              ListTile(
                leading: const Icon(Icons.link, color: Colors.indigo),
                title: Text(context.l10n.appearanceOgpTitle),
                subtitle: Text(_ogpLayoutLabel(context, settings.ogpLayout)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showOgpLayoutPicker(
                  context,
                  settings.ogpLayout,
                  notifier,
                ),
              ),
              SwitchListTile(
                title: Text(context.l10n.appearanceRelativeTimeTitle),
                subtitle: Text(context.l10n.appearanceRelativeTimeSubtitle),
                value: settings.useRelativeTime,
                onChanged: notifier.setUseRelativeTime,
                secondary:
                    const Icon(Icons.access_time, color: Colors.blueGrey),
              ),
              SwitchListTile(
                title: Text(context.l10n.appearanceShowUserIdTitle),
                subtitle: Text(context.l10n.appearanceShowUserIdSubtitle),
                value: settings.showUserId,
                onChanged: notifier.setShowUserId,
                secondary:
                    const Icon(Icons.alternate_email, color: Colors.blue),
              ),
              SwitchListTile(
                title: Text(context.l10n.appearanceShowPostActionsTitle),
                subtitle: Text(context.l10n.appearanceShowPostActionsSubtitle),
                value: settings.showPostActions,
                onChanged: notifier.setShowPostActions,
                secondary: const Icon(Icons.touch_app, color: Colors.green),
              ),
              SwitchListTile(
                title: Text(context.l10n.appearanceShowReactionCountsTitle),
                subtitle:
                    Text(context.l10n.appearanceShowReactionCountsSubtitle),
                value: settings.showReactionCounts,
                onChanged: notifier.setShowReactionCounts,
                secondary: const Icon(Icons.numbers, color: Colors.orange),
              ),
              SwitchListTile(
                title: Text(context.l10n.appearanceShowViaTitle),
                subtitle: Text(context.l10n.appearanceShowViaSubtitle),
                value: settings.showVia,
                onChanged: notifier.setShowVia,
                secondary:
                    const Icon(Icons.smartphone, color: Colors.blueGrey),
              ),
            ],
          ),

          // ========== 通知表示 ==========
          SettingsSection(
            title: context.l10n.appearanceSectionNotifications,
            children: [
              SwitchListTile(
                secondary:
                    const Icon(Icons.layers_outlined, color: Colors.deepPurple),
                title: Text(context.l10n.appearanceGroupNotifTitle),
                subtitle: Text(context.l10n.appearanceGroupNotifSubtitle),
                value: settings.groupedNotifications,
                onChanged: notifier.setGroupedNotifications,
              ),
            ],
          ),

          // ========== 文字とレイアウト ==========
          SettingsSection(
            title: context.l10n.appearanceSectionText,
            children: [
              ListTile(
                leading:
                    const Icon(Icons.font_download, color: Colors.indigo),
                title: Text(context.l10n.appearanceFontTitle),
                subtitle: Text(_fontLabel(context, settings.fontFamily)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    _showFontPicker(context, settings.fontFamily, notifier),
              ),
              _SliderTile(
                icon: Icons.format_size,
                iconColor: Colors.indigo,
                title: context.l10n.appearanceFontSizeTitle,
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
                title: context.l10n.appearanceLineHeightTitle,
                value: settings.lineHeight,
                min: 1.0,
                max: 2.0,
                divisions: 10,
                label: context.l10n.appearanceLineHeightValue(
                    settings.lineHeight.toStringAsFixed(1)),
                description: context.l10n.appearanceLineHeightDesc,
                onChanged: notifier.setLineHeight,
              ),
              _SliderTile(
                icon: Icons.unfold_less,
                iconColor: Colors.brown,
                title: context.l10n.appearanceCollapseTitle,
                value: settings.collapseAfterLines.toDouble(),
                min: 0,
                max: 20,
                divisions: 20,
                label: settings.collapseAfterLines == 0
                    ? context.l10n.appearanceCollapseDisabled
                    : context.l10n
                        .appearanceCollapseLines(settings.collapseAfterLines),
                description: settings.collapseAfterLines == 0
                    ? context.l10n.appearanceCollapseDescDisabled
                    : context.l10n.appearanceCollapseDescLines(
                        settings.collapseAfterLines),
                onChanged: (v) =>
                    notifier.setCollapseAfterLines(v.toInt()),
              ),
            ],
          ),

          // ========== アイコンとボタン ==========
          SettingsSection(
            title: context.l10n.appearanceSectionIcons,
            children: [
              _SliderTile(
                icon: Icons.account_circle,
                iconColor: Colors.blue,
                title: context.l10n.appearanceAvatarSizeTitle,
                value: settings.avatarSize,
                min: 24,
                max: 72,
                divisions: 12,
                label: '${settings.avatarSize.toStringAsFixed(0)}px',
                description: context.l10n.appearanceAvatarSizeDesc,
                onChanged: notifier.setAvatarSize,
              ),
              SwitchListTile(
                title: Text(context.l10n.appearanceAvatarSquareTitle),
                subtitle: Text(context.l10n.appearanceAvatarSquareSubtitle),
                value: settings.isAvatarSquare,
                onChanged: notifier.setAvatarSquare,
                secondary: const Icon(Icons.crop_square, color: Colors.teal),
              ),
              _SliderTile(
                icon: Icons.star_border,
                iconColor: Colors.amber,
                title: context.l10n.appearanceActionIconSizeTitle,
                value: settings.actionIconSize,
                min: 16,
                max: 32,
                divisions: 16,
                label: '${settings.actionIconSize.toStringAsFixed(0)}px',
                description: context.l10n.appearanceActionIconSizeDesc,
                onChanged: notifier.setActionIconSize,
              ),
            ],
          ),

          // ========== カスタム絵文字 ==========
          SettingsSection(
            title: context.l10n.appearanceSectionEmoji,
            children: [
              _SliderTile(
                icon: Icons.badge,
                iconColor: Colors.orange,
                title: context.l10n.appearanceEmojiDisplayNameTitle,
                value: settings.emojiScaleInDisplayName,
                min: 0.4,
                max: 4.0,
                divisions: 18,
                label: '${(settings.emojiScaleInDisplayName * 100).round()}%',
                description: context.l10n.appearanceEmojiDisplayNameDesc,
                onChanged: notifier.setEmojiScaleInDisplayName,
              ),
              _SliderTile(
                icon: Icons.text_snippet,
                iconColor: Colors.green,
                title: context.l10n.appearanceEmojiContentTitle,
                value: settings.emojiScale,
                min: 0.4,
                max: 4.0,
                divisions: 18,
                label: '${(settings.emojiScale * 100).round()}%',
                description: context.l10n.appearanceEmojiContentDesc,
                onChanged: notifier.setEmojiScale,
              ),
            ],
          ),

          // アニメーション (カスタム絵文字に紐付くサブセクション)
          SettingsSection(
            title: context.l10n.appearanceSectionAnimation,
            children: [
              SwitchListTile(
                title: Text(context.l10n.appearanceDisableAnimNameTitle),
                subtitle: Text(context.l10n.appearanceDisableAnimNameSubtitle),
                value: settings.disableCustomEmojiAnimationInDisplayName,
                onChanged:
                    notifier.setDisableCustomEmojiAnimationInDisplayName,
                secondary: const Icon(Icons.gif_box_outlined,
                    color: Colors.deepPurple),
              ),
              SwitchListTile(
                title: Text(context.l10n.appearanceDisableAnimContentTitle),
                subtitle:
                    Text(context.l10n.appearanceDisableAnimContentSubtitle),
                value: settings.disableCustomEmojiAnimationInContent,
                onChanged: notifier.setDisableCustomEmojiAnimationInContent,
                secondary:
                    const Icon(Icons.movie_filter_outlined, color: Colors.teal),
              ),
            ],
          ),

          // ========== メディアとコンテンツ ==========
          SettingsSection(
            title: context.l10n.appearanceSectionMedia,
            children: [
              SwitchListTile(
                title: Text(context.l10n.appearanceNoBlurTitle),
                subtitle: Text(context.l10n.appearanceNoBlurSubtitle),
                value: settings.disableMediaBlur,
                onChanged: notifier.setDisableMediaBlur,
                secondary: const Icon(Icons.blur_off, color: Colors.cyan),
              ),
              SwitchListTile(
                title: Text(context.l10n.appearanceExpandCwTitle),
                subtitle: Text(context.l10n.appearanceExpandCwSubtitle),
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
