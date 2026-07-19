// lib/pages/boss_mode/google_search_box.dart

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// Google 検索窓そっくりの pill 型入力欄。
///
/// 偽装モードでは「検索」ではなく **投稿(toot)** に使う。Enter または右端の
/// 送信アイコンで [onSubmit] が発火する。controller / focusNode は親
/// (GoogleShell) が保持し、投稿後のクリアや返信時のフォーカス制御に使う。
class GoogleSearchBox extends StatelessWidget {
  const GoogleSearchBox({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
    required this.visibility,
    required this.onVisibilityChanged,
    this.autofocus = false,
    this.replyingToLabel,
    this.onCancelReply,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSubmit;
  final bool autofocus;

  /// 投稿の公開範囲 ('public' / 'unlisted' / 'private' / 'direct')。
  final String visibility;
  final ValueChanged<String> onVisibilityChanged;

  /// 返信中なら "@user" のラベル。null なら通常 (新規投稿)。
  final String? replyingToLabel;
  final VoidCallback? onCancelReply;

  static List<(String, IconData, String)> get _visibilities => [
        ('public', Icons.public, l10n.visibilityPublic),
        ('unlisted', Icons.lock_open, l10n.visibilityUnlisted),
        ('private', Icons.lock, l10n.visibilityPrivate),
        ('direct', Icons.alternate_email, l10n.visibilityDirect),
      ];

  static IconData _iconFor(String v) {
    for (final item in _visibilities) {
      if (item.$1 == v) return item.$2;
    }
    return Icons.public;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (replyingToLabel != null) ...[
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Wrap(
              children: [
                InputChip(
                  label: Text(context.l10n.bossReplyingTo(replyingToLabel!)),
                  onDeleted: onCancelReply,
                  visualDensity: VisualDensity.compact,
                  backgroundColor: const Color(0xFFF1F3F4),
                  labelStyle: const TextStyle(color: Color(0xFF202124), fontSize: 13),
                  deleteIconColor: const Color(0xFF5F6368),
                ),
              ],
            ),
          ),
        ],
        Material(
          color: Colors.white,
          elevation: 1,
          shadowColor: Colors.black26,
          borderRadius: BorderRadius.circular(24),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFDFE1E5)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                const Icon(Icons.search, color: Color(0xFF9AA0A6), size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    autofocus: autofocus,
                    textInputAction: TextInputAction.send,
                    cursorColor: const Color(0xFF4285F4),
                    style: const TextStyle(
                      color: Color(0xFF202124),
                      fontSize: 16,
                    ),
                    decoration: const InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: '',
                      contentPadding: EdgeInsets.symmetric(vertical: 14),
                    ),
                    onSubmitted: onSubmit,
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: context.l10n.visibilityTooltip,
                  initialValue: visibility,
                  icon: Icon(_iconFor(visibility),
                      color: const Color(0xFF5F6368), size: 20),
                  onSelected: onVisibilityChanged,
                  itemBuilder: (context) => [
                    for (final item in _visibilities)
                      PopupMenuItem<String>(
                        value: item.$1,
                        child: Row(
                          children: [
                            Icon(item.$2,
                                size: 18, color: const Color(0xFF5F6368)),
                            const SizedBox(width: 12),
                            Text(item.$3),
                          ],
                        ),
                      ),
                  ],
                ),
                IconButton(
                  tooltip: context.l10n.send,
                  icon: const Icon(Icons.send, color: Color(0xFF4285F4), size: 20),
                  onPressed: () => onSubmit(controller.text),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
