// lib/utils/html_text_utils.dart
//
// html_parser.dart から切り出した「Flutter widget に依存しない」純粋な
// テキスト処理ヘルパー。unit test 可能にするため分離している。

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' show parseFragment;

import 'hashtag_utils.dart' show isValidHashtag;

/// URL から有効なハッシュタグを抽出する。
///
/// `hashtag_utils.dart` の [extractHashtagFromUrl] とは別関数なので注意:
/// - 抽出後に [isValidHashtag] で検証し、不合格 (数字のみ等) なら null を返す
/// - 文字集合に `#` を含まないため `/tags/foo#bar` の fragment を拾わない
/// - raw `#tag` パターン (URL 以外の平文) にはマッチしない
/// `<a>` 要素の href からハッシュタグリンクかどうかを判別する用途専用。
String? extractValidHashtagFromUrl(String url) {
  final patterns = [
    RegExp(r'/tags/([^/\s?#]+)', caseSensitive: false),
    RegExp(r'/tag/([^/\s?#]+)', caseSensitive: false),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(url);
    if (match != null && match.group(1) != null) {
      // `Uri.decodeComponent` は decode に失敗すると例外を投げる。投げ方が
      // 入力によって 2 種類あるので両方とも握り潰して raw 値にフォールバック
      // する必要がある:
      //   - 不正な percent encoding (`%foo` のように `%` 後に 16 進が来ない)
      //     → `FormatException`
      //   - percent-encode されていない生の非 ASCII (Misskey 連合で Mastodon が
      //     ローカルの hashtag リンクに書き換えず `/tags/地下鉄の日` のまま来る
      //     ケース) → `ArgumentError("Illegal percent encoding in URI")`
      // 後者を取りこぼすと、ハッシュタグのみの Misskey 投稿で例外が
      // parseContentWithEmojis まで伝播し、本文全体が黒いプレーンテキストに
      // フォールバックして「ハッシュタグがリンク化されない」事象になる。
      // どちらの場合も raw 値で `isValidHashtag` 判定すれば CJK 等は通る。
      String hashtag;
      try {
        hashtag = Uri.decodeComponent(match.group(1)!);
      } catch (_) {
        hashtag = match.group(1)!;
      }
      if (isValidHashtag(hashtag)) return hashtag;
    }
  }
  return null;
}

/// URL を表示用に短縮する (50 文字以下はそのまま)。
String shortenUrl(String url) {
  if (url.length <= 50) return url;
  final uri = Uri.tryParse(url);
  if (uri != null) {
    final domain = uri.host;
    final path = uri.path;
    if (path.length > 20) {
      return '$domain${path.substring(0, 17)}...';
    }
    return '$domain$path';
  }
  return '${url.substring(0, 47)}...';
}

// ============================================================
// プレーンテキスト抽出 (検索 / 通知 / OGP メタ等で使われる)
// ============================================================

/// HTML を平文に変換する。装飾は捨てるが文字並びは保つ。`<br>` `<p>` で改行、
/// `<span class="invisible">` の中身は除外。検索プレビューや通知本文の
/// スニペット等、装飾不要な場面で使う。
String parseHtmlToPlainText(String contentHtml) {
  final fragment = parseFragment(contentHtml);
  final raw = _extractPlainText(fragment.nodes);
  // 連続改行の整理
  return raw.replaceAll(RegExp(r'\n\s*\n\s*\n'), '\n\n').trim();
}

String _extractPlainText(List<dom.Node> nodes) {
  final buf = StringBuffer();
  for (final node in nodes) {
    if (node is dom.Text) {
      buf.write(node.text);
    } else if (node is dom.Element) {
      final name = node.localName?.toLowerCase();
      if (name == 'br') {
        buf.write('\n');
      } else if (name == 'p') {
        buf.write(_extractPlainText(node.nodes));
        buf.write('\n');
      } else if (name == 'li') {
        buf.write('• ');
        buf.write(_extractPlainText(node.nodes));
        buf.write('\n');
      } else {
        final cls = (node.attributes['class'] ?? '').toLowerCase();
        if (cls.contains('invisible')) continue;
        buf.write(_extractPlainText(node.nodes));
      }
    }
  }
  return buf.toString();
}
