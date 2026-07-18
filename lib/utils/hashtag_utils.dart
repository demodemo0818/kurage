// lib/utils/hashtag_utils.dart

import 'package:flutter/material.dart';
import '../pages/hashtag_page.dart';
import 'open_profile.dart';

/// ハッシュタグがタップされた時の処理
void onHashtagTap(BuildContext context, String hashtag) {
  // #を除去
  final cleanHashtag = hashtag.startsWith('#') ? hashtag.substring(1) : hashtag;

  // ワイドはホームに重ねる Deck ポップアップ、ナローはフルスクリーン push。
  openDeckPage(
    context,
    (onDeckBack) => HashtagPage(hashtag: cleanHashtag, onDeckBack: onDeckBack),
  );
}

/// URLからハッシュタグ名を抽出
String? extractHashtagFromUrl(String url) {
  // Mastodonのハッシュタグリンクのパターン
  final patterns = [
    RegExp(r'/tags/([^/\s?]+)', caseSensitive: false),
    RegExp(r'/tag/([^/\s?]+)', caseSensitive: false),
    RegExp(
      r'#([\p{L}\p{N}_][\p{L}\p{N}_·\-—]*)',
      unicode: true,
    ),
  ];

  for (final pattern in patterns) {
    final match = pattern.firstMatch(url);
    if (match != null && match.group(1) != null) {
      final raw = match.group(1)!;
      // decode 失敗時 (= 不正な percent encoding、または raw Unicode を含む
      // 非エンコード入力) は raw 値で返す。
      //
      // Dart 3 系の `Uri.decodeComponent` は不正入力に対し `ArgumentError`
      // を投げる (古い Dart は `FormatException` だった)。両方をキャッチして
      // どちらの版でも正しく fallback する。これがないと `#日本語` のような
      // Unicode のハッシュタグ URL でアプリが落ちる。
      try {
        return Uri.decodeComponent(raw);
      } on FormatException {
        return raw;
      } on ArgumentError {
        return raw;
      }
    }
  }

  return null;
}

/// テキストからハッシュタグを抽出。Mastodon の `HASHTAG_NAME_RE` と概ね揃え、
/// Unicode letter / number / underscore + 中点 / ハイフン / em dash を許容
/// する。`html_parser.dart` の `_hashtagRegex` と同じ文字集合。
List<String> extractHashtagsFromText(String text) {
  final hashtagPattern = RegExp(
    r'#([\p{L}\p{N}_][\p{L}\p{N}_·\-—]*)',
    unicode: true,
  );

  return hashtagPattern
      .allMatches(text)
      .map((match) => match.group(1)!)
      .toList();
}

/// ハッシュタグが有効かチェック。`extractHashtagsFromText` の正規表現と
/// 必ず同じ文字集合にする (片方が拾って片方が validate で弾くと無音 drop
/// になる)。
bool isValidHashtag(String hashtag) {
  if (hashtag.isEmpty) return false;

  // 数字のみのハッシュタグは無効
  if (RegExp(r'^\d+$').hasMatch(hashtag)) return false;

  return RegExp(r'^[\p{L}\p{N}_·\-—]+$', unicode: true).hasMatch(hashtag);
}
