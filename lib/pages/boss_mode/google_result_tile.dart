// lib/pages/boss_mode/google_result_tile.dart

import 'package:flutter/material.dart';

import '../../widgets/collapsible_text.dart';

/// 1 件の投稿を Google 検索結果風に描画する (青タイトル / 緑 URL 行 /
/// グレースニペット + 控えめなアクション行)。
///
/// モデルに依存しないよう、表示用の文字列・状態は親 (GoogleShell) で解決して
/// プリミティブで受け取る。
class GoogleResultTile extends StatelessWidget {
  const GoogleResultTile({
    super.key,
    required this.urlLine,
    required this.title,
    required this.snippet,
    required this.favourited,
    required this.reblogged,
    required this.bookmarked,
    required this.favCount,
    required this.reblogCount,
    required this.onFavourite,
    required this.onReblog,
    required this.onBookmark,
    required this.onReply,
  });

  final String urlLine; // 緑の URL 行 (例: "mstdn.jp › @alice")
  final String title; // 青いタイトル (表示名)
  final String snippet; // グレー本文スニペット
  final bool favourited;
  final bool reblogged;
  final bool bookmarked;
  final int favCount;
  final int reblogCount;
  final VoidCallback onFavourite;
  final VoidCallback onReblog;
  final VoidCallback onBookmark;
  final VoidCallback onReply;

  static const Color _titleBlue = Color(0xFF1A0DAB);
  static const Color _urlGreen = Color(0xFF006621);
  static const Color _snippet = Color(0xFF4D5156);
  static const Color _action = Color(0xFF5F6368);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 緑の URL 行
          Text(
            urlLine,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _urlGreen, fontSize: 13),
          ),
          const SizedBox(height: 2),
          // 青いタイトル (クリックできそうな見た目)
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _titleBlue,
              fontSize: 20,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 3),
          // グレースニペット。2 行を超える長文は「もっと見る」で展開できる
          // (CollapsibleText が TextPainter で実測し、超過時のみボタンを出す)。
          CollapsibleText(
            textSpans: [TextSpan(text: snippet)],
            defaultStyle: const TextStyle(
              color: _snippet,
              fontSize: 14,
              height: 1.45,
            ),
            maxLines: 2,
            buttonColor: const Color(0xFF1A73E8),
          ),
          const SizedBox(height: 6),
          // 控えめなアクション行 (Google のサイトリンク風に見せる)
          Row(
            children: [
              _action_(
                icon: Icons.reply,
                color: _action,
                count: null,
                onTap: onReply,
              ),
              const SizedBox(width: 18),
              _action_(
                icon: Icons.repeat,
                color: reblogged ? const Color(0xFF188038) : _action,
                count: reblogCount,
                onTap: onReblog,
              ),
              const SizedBox(width: 18),
              _action_(
                icon: favourited ? Icons.star : Icons.star_border,
                color: favourited ? const Color(0xFFE37400) : _action,
                count: favCount,
                onTap: onFavourite,
              ),
              const SizedBox(width: 18),
              _action_(
                icon: bookmarked ? Icons.bookmark : Icons.bookmark_border,
                color: bookmarked ? const Color(0xFF1A73E8) : _action,
                count: null,
                onTap: onBookmark,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _action_({
    required IconData icon,
    required Color color,
    required int? count,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            if (count != null && count > 0) ...[
              const SizedBox(width: 4),
              Text(
                '$count',
                style: TextStyle(color: color, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
