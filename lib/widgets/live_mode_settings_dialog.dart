// lib/widgets/live_mode_settings_dialog.dart

import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/live_mode.dart';

class LiveModeSettingsDialog extends StatefulWidget {
  final LiveModeSettings initialSettings;

  const LiveModeSettingsDialog({
    super.key,
    required this.initialSettings,
  });

  @override
  State<LiveModeSettingsDialog> createState() => _LiveModeSettingsDialogState();
}

class _LiveModeSettingsDialogState extends State<LiveModeSettingsDialog> {
  late bool _isEnabled;
  late List<String> _hashtags;
  late bool _insertAtEnd;
  final TextEditingController _newHashtagController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _isEnabled = widget.initialSettings.isEnabled;
    _hashtags = List.from(widget.initialSettings.hashtags);
    _insertAtEnd = widget.initialSettings.insertAtEnd;
  }

  @override
  void dispose() {
    _newHashtagController.dispose();
    super.dispose();
  }

  void _addHashtag() {
    final newTag = _newHashtagController.text.trim();
    if (newTag.isNotEmpty && !_hashtags.contains(newTag)) {
      setState(() {
        _hashtags.add(newTag);
        _newHashtagController.clear();
      });
    }
  }

  void _removeHashtag(int index) {
    setState(() {
      _hashtags.removeAt(index);
    });
  }

  void _saveSettings() {
    final settings = LiveModeSettings(
      isEnabled: _isEnabled,
      hashtags: _hashtags,
      insertAtEnd: _insertAtEnd,
    );
    Navigator.of(context).pop(settings);
  }

  @override
  Widget build(BuildContext context) {
    // 広い画面 (Deck) では double.maxFinite だとダイアログがウィンドウ幅
    // いっぱいまで横に広がってしまうので最大幅を制限する (通知フィルターと
    // 同じ方針)。狭い画面 (スマホ) では従来どおりフル幅にする。
    final screenWidth = MediaQuery.of(context).size.width;
    final dialogContentWidth =
        screenWidth < 480 ? double.maxFinite : 400.0;

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.live_tv, 
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.red.shade300
                : Colors.red,
          ),
          const SizedBox(width: 8),
          Text(context.l10n.liveModeTitle),
        ],
      ),
      content: SizedBox(
        width: dialogContentWidth,
        height: MediaQuery.of(context).size.height * 0.6,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 実況モードの有効/無効
              SwitchListTile(
                title: Text(context.l10n.liveModeEnable),
                subtitle: Text(context.l10n.liveModeEnableSubtitle),
                value: _isEnabled,
                onChanged: (value) {
                  setState(() {
                    _isEnabled = value;
                  });
                },
              ),
              
              const Divider(),
              
              // ハッシュタグ挿入位置（コンパクト版）
              Row(
                children: [
                  Text(
                    context.l10n.liveModeInsertPositionLabel,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Expanded(
                    child: DropdownButton<bool>(
                      value: _insertAtEnd,
                      isExpanded: true,
                      items: [
                        DropdownMenuItem(
                          value: true,
                          child: Text(context.l10n.liveModeAppendToEnd),
                        ),
                        DropdownMenuItem(
                          value: false,
                          child: Text(context.l10n.liveModePrependToStart),
                        ),
                      ],
                      onChanged: _isEnabled ? (value) {
                        setState(() {
                          _insertAtEnd = value!;
                        });
                      } : null,
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 12),
              
              // ハッシュタグ管理
              Text(
                context.l10n.hashtags,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              
              // ハッシュタグ追加フィールド
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _newHashtagController,
                      enabled: _isEnabled,
                      decoration: InputDecoration(
                        hintText: context.l10n.liveModeHashtagHint,
                        border: const OutlineInputBorder(),
                        prefixText: '#',
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                      ),
                      onSubmitted: _isEnabled ? (_) => _addHashtag() : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _isEnabled ? _addHashtag : null,
                    icon: Icon(
                      Icons.add,
                      color: _isEnabled
                          ? (Theme.of(context).brightness == Brightness.dark
                              ? Colors.blue.shade300
                              : Colors.blue.shade600)
                          : (Theme.of(context).brightness == Brightness.dark
                              ? Colors.grey.shade600
                              : Colors.grey.shade400),
                    ),
                    style: IconButton.styleFrom(
                      minimumSize: const Size(40, 40),
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 12),
              
              // ハッシュタグリスト
              if (_hashtags.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxHeight: 120),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.l10n.liveModeAddedHashtags,
                          style: TextStyle(
                            fontSize: 12, 
                            color: Theme.of(context).brightness == Brightness.dark
                                ? Colors.grey.shade400
                                : Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: _hashtags.asMap().entries.map((entry) {
                            final index = entry.key;
                            final tag = entry.value;
                            final isDarkMode = Theme.of(context).brightness == Brightness.dark;
                            return Chip(
                              label: Text(
                                '#$tag', 
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _isEnabled 
                                      ? (isDarkMode ? Colors.blue.shade200 : Colors.blue.shade800)
                                      : (isDarkMode ? Colors.grey.shade400 : Colors.grey.shade600),
                                ),
                              ),
                              deleteIcon: Icon(
                                Icons.close, 
                                size: 16,
                                color: _isEnabled
                                    ? (isDarkMode ? Colors.blue.shade300 : Colors.blue.shade600)
                                    : (isDarkMode ? Colors.grey.shade500 : Colors.grey.shade600),
                              ),
                              onDeleted: _isEnabled ? () => _removeHashtag(index) : null,
                              backgroundColor: _isEnabled 
                                  ? (isDarkMode ? Colors.blue.shade800.withValues(alpha: 0.3) : Colors.blue.shade50)
                                  : (isDarkMode ? Colors.grey.shade700 : Colors.grey.shade200),
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                )
              else if (_isEnabled)
                Center(
                  child: Text(
                    context.l10n.liveModeNoHashtags,
                    style: TextStyle(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.grey.shade400
                          : Colors.grey, 
                      fontSize: 12,
                    ),
                  ),
                ),
              
              if (_isEnabled && _hashtags.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.grey.shade800.withValues(alpha: 0.5)
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                    border: Theme.of(context).brightness == Brightness.dark
                        ? Border.all(color: Colors.grey.shade700)
                        : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.liveModePreviewLabel,
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _insertAtEnd
                            ? '${context.l10n.liveModePostPlaceholder}${LiveModeSettings(hashtags: _hashtags).hashtagString}'
                            : '${LiveModeSettings(hashtags: _hashtags).hashtagString.trim()} ${context.l10n.liveModePostPlaceholder}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.cancel),
        ),
        ElevatedButton(
          onPressed: _saveSettings,
          child: Text(context.l10n.save),
        ),
      ],
    );
  }
}