// parseContentWithEmojis (Mastodon content HTML → InlineSpan 変換) のテスト。
//
// html_parser.dart は投稿本文・CW・表示名など最大 6〜8 箇所から呼ばれる
// 描画の中核だが、これまでテストが無かった (html_text_utils_test は
// plain text 抽出のみ)。DOM walk の構造変換・装飾の重ね合わせ・<a> の
// mention / hashtag / URL 分類・プレーンテキスト中の自動リンク検出を固定する。
//
// 注: 非 Web (VM テスト) ではリンク類は TextSpan + TapGestureRecognizer に
// なる (Web のみ WidgetSpan)。ここでは VM 前提でアサーションする。

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/emoji.dart';
import 'package:kurage/utils/html_parser.dart';

const _base = TextStyle(fontSize: 14, color: Colors.black);
const _link = Colors.blue;

List<InlineSpan> _parse(
  String html, {
  List<Emoji> emojis = const [],
  bool enableInlineLinks = true,
}) =>
    parseContentWithEmojis(
      contentHtml: html,
      emojis: emojis,
      baseStyle: _base,
      linkColor: _link,
      emojiSize: 20,
      enableInlineLinks: enableInlineLinks,
    );

/// spans を平文に潰す。WidgetSpan (絵文字 / ブロック要素) は
/// includePlaceholders=false なら出力されない。
String _flatText(List<InlineSpan> spans) =>
    spans.map((s) => s.toPlainText(includePlaceholders: false)).join();

/// テキストが一致する TextSpan を再帰的に探す (スタイル検証用)。
TextSpan? _findText(List<InlineSpan> spans, String text) {
  for (final span in spans) {
    if (span is TextSpan) {
      if (span.text == text) return span;
      final children = span.children;
      if (children != null) {
        final found = _findText(children, text);
        if (found != null) return found;
      }
    }
  }
  return null;
}

void main() {
  group('段落と改行', () {
    test('単一段落は本文のみ (末尾の段落改行はトリムされる)', () {
      expect(_flatText(_parse('<p>こんにちは</p>')), 'こんにちは');
    });

    test('複数段落は空行 1 行で区切られる', () {
      expect(_flatText(_parse('<p>A</p><p>B</p>')), 'A\n\nB');
    });

    test('<br> は改行 1 つ', () {
      expect(_flatText(_parse('<p>A<br>B</p>')), 'A\nB');
    });

    test('空文字列は空リスト', () {
      expect(_parse(''), isEmpty);
    });

    test('空の段落は出力されない', () {
      expect(_flatText(_parse('<p></p><p>B</p>')), 'B');
    });
  });

  group('インライン装飾', () {
    test('strong / b は太字', () {
      for (final html in ['<p><strong>太字</strong></p>', '<p><b>太字</b></p>']) {
        final span = _findText(_parse(html), '太字');
        expect(span, isNotNull, reason: html);
        expect(span!.style?.fontWeight, FontWeight.bold, reason: html);
      }
    });

    test('em / i は斜体', () {
      for (final html in ['<p><em>斜体</em></p>', '<p><i>斜体</i></p>']) {
        final span = _findText(_parse(html), '斜体');
        expect(span!.style?.fontStyle, FontStyle.italic, reason: html);
      }
    });

    test('ネストした装飾は重なる (strong > em で太字 + 斜体)', () {
      final span = _findText(_parse('<p><strong><em>両方</em></strong></p>'), '両方');
      expect(span!.style?.fontWeight, FontWeight.bold);
      expect(span.style?.fontStyle, FontStyle.italic);
    });

    test('del / s / strike は取り消し線', () {
      for (final html in [
        '<p><del>消</del></p>',
        '<p><s>消</s></p>',
        '<p><strike>消</strike></p>',
      ]) {
        final span = _findText(_parse(html), '消');
        expect(span!.style?.decoration, TextDecoration.lineThrough,
            reason: html);
      }
    });

    test('u は下線、del との入れ子で decoration が合成される', () {
      final span = _findText(_parse('<p><del><u>両方</u></del></p>'), '両方');
      final deco = span!.style?.decoration;
      expect(deco, isNotNull);
      expect(deco!.contains(TextDecoration.underline), isTrue);
      expect(deco.contains(TextDecoration.lineThrough), isTrue);
    });

    test('code は等幅 + 背景色', () {
      final span = _findText(_parse('<p><code>x = 1</code></p>'), 'x = 1');
      expect(span!.style?.fontFamily, 'monospace');
      expect(span.style?.backgroundColor, isNotNull);
    });
  });

  group('ブロック要素', () {
    test('pre は WidgetSpan で囲まれる', () {
      final spans = _parse('<pre><code>code block</code></pre>');
      expect(spans.whereType<WidgetSpan>(), hasLength(1));
    });

    test('blockquote は WidgetSpan で囲まれる', () {
      final spans = _parse('<blockquote><p>引用文</p></blockquote>');
      expect(spans.whereType<WidgetSpan>(), hasLength(1));
    });

    test('ul は「• 」マーカー付きで列挙される', () {
      expect(_flatText(_parse('<ul><li>a</li><li>b</li></ul>')), '• a\n• b');
    });

    test('ol は番号付きで列挙される', () {
      expect(_flatText(_parse('<ol><li>a</li><li>b</li></ol>')), '1. a\n2. b');
    });

    test('単独の li (親なし fallback) は中身だけ出力される', () {
      expect(_flatText(_parse('<li>単独</li>')), '単独');
    });
  });

  group('<a> の分類', () {
    test('class="mention" はメンションスパン (リンク色 + recognizer)', () {
      final spans = _parse(
          '<p><a href="https://other.example/@bob" class="u-url mention">'
          '@<span>bob</span></a></p>');
      final span = _findText(spans, '@bob');
      expect(span, isNotNull);
      expect(span!.style?.color, _link);
      expect(span.style?.fontWeight, FontWeight.w600);
      expect(span.recognizer, isA<TapGestureRecognizer>());
    });

    test('class="mention hashtag" はハッシュタグ扱い', () {
      final spans = _parse(
          '<p><a href="https://example.com/tags/flutter" class="mention hashtag" '
          'rel="tag">#<span>flutter</span></a></p>');
      final span = _findText(spans, '#flutter');
      expect(span, isNotNull);
      expect(span!.style?.color, _link);
      expect(span.recognizer, isA<TapGestureRecognizer>());
    });

    test('class が無くても /tags/ URL ならハッシュタグ扱い', () {
      final spans = _parse(
          '<p><a href="https://example.com/tags/flutter">#flutter</a></p>');
      final span = _findText(spans, '#flutter');
      expect(span, isNotNull);
      expect(span!.recognizer, isA<TapGestureRecognizer>());
    });

    test('通常 URL は invisible span を除いた表示テキストになる', () {
      // Mastodon の URL 短縮 3 段組 (invisible + 本体 + invisible)
      final spans = _parse(
          '<p><a href="https://example.com/very/long/path">'
          '<span class="invisible">https://</span>'
          '<span class="ellipsis">example.com/very</span>'
          '<span class="invisible">/long/path</span></a></p>');
      final span = _findText(spans, 'example.com/very');
      expect(span, isNotNull);
      expect(span!.style?.color, _link);
      expect(span.recognizer, isA<TapGestureRecognizer>());
    });

    test('href 無しの <a> はプレーンテキストとして扱う', () {
      final spans = _parse('<p><a>ただの文字</a></p>');
      final span = _findText(spans, 'ただの文字');
      expect(span, isNotNull);
      expect(span!.recognizer, isNull);
    });
  });

  group('プレーンテキスト中の自動リンク (enableInlineLinks=true)', () {
    test('URL を検出してリンクスパンにする', () {
      final spans = _parse('<p>見て https://example.com/x</p>');
      final span = _findText(spans, 'https://example.com/x');
      expect(span, isNotNull);
      expect(span!.style?.color, _link);
      expect(span.recognizer, isA<TapGestureRecognizer>());
      expect(_findText(spans, '見て '), isNotNull);
    });

    test('ハッシュタグを検出する (CJK / ハイフン / キリル文字)', () {
      for (final tag in ['#日本語', '#open-source', '#русский']) {
        final spans = _parse('<p>いいね $tag です</p>');
        final span = _findText(spans, tag);
        expect(span, isNotNull, reason: tag);
        expect(span!.style?.fontWeight, FontWeight.w600, reason: tag);
        expect(span.recognizer, isA<TapGestureRecognizer>(), reason: tag);
      }
    });

    test('メンション (@user / @user@domain) を検出する', () {
      final spans = _parse('<p>cc @alice@example.com さん</p>');
      final span = _findText(spans, '@alice@example.com');
      expect(span, isNotNull);
      expect(span!.recognizer, isA<TapGestureRecognizer>());
    });

    test('URL 内の @ はメンションとして二重マッチしない (オーバーラップ排除)', () {
      final spans = _parse('<p>https://example.com/@user</p>');
      // URL 全体が 1 個のリンクスパンになり、@user 単独のスパンは出ない
      final url = _findText(spans, 'https://example.com/@user');
      expect(url, isNotNull);
      expect(_findText(spans, '@user'), isNull);
    });

    test('語中の # はハッシュタグにしない (C# / a#tag)', () {
      for (final text in ['C#が好き', 'a#tag']) {
        final spans = _parse('<p>$text</p>');
        // 全体が 1 個のプレーンテキストスパンのまま (リンク分割されない)
        final span = _findText(spans, text);
        expect(span, isNotNull, reason: text);
        expect(span!.recognizer, isNull, reason: text);
      }
    });

    test('行頭・空白後・開き括弧後の # はハッシュタグにする', () {
      for (final html in ['<p>#tag</p>', '<p>見て #tag</p>', '<p>(#tag)</p>']) {
        final span = _findText(_parse(html), '#tag');
        expect(span, isNotNull, reason: html);
        expect(span!.recognizer, isA<TapGestureRecognizer>(), reason: html);
      }
    });

    test('語中の @ はメンションにしない (メールアドレス / 日本語直後)', () {
      final mail = _parse('<p>メール aaa@example.com です</p>');
      expect(_findText(mail, '@example.com'), isNull);

      final ja = _parse('<p>日本語@user</p>');
      final span = _findText(ja, '日本語@user');
      expect(span, isNotNull);
      expect(span!.recognizer, isNull);
    });
  });

  group('enableInlineLinks=false (表示名モード)', () {
    test('URL / ハッシュタグ / メンションをリンク化しない', () {
      final spans = _parse(
        '<p>@alice #tag https://example.com</p>',
        enableInlineLinks: false,
      );
      // 表示名モードは全体を Unicode 双方向アイソレート (FSI … PDI) で囲むため
      // 先頭・末尾に制御文字スパンが付く。本文はリンク化されず 1 個の TextSpan
      // のまま (recognizer 無し) であることを検証する。
      final span = _findText(spans, '@alice #tag https://example.com');
      expect(span, isNotNull);
      expect(span!.recognizer, isNull);
    });

    test('カスタム絵文字は表示名モードでも変換される', () {
      final spans = _parse(
        '<p>Alice :party:</p>',
        emojis: [Emoji(shortcode: 'party', url: 'https://example.com/p.gif')],
        enableInlineLinks: false,
      );
      expect(spans.whereType<WidgetSpan>(), hasLength(1));
      expect(_findText(spans, 'Alice '), isNotNull);
    });
  });

  group('カスタム絵文字', () {
    test('一致する shortcode は WidgetSpan (画像) になる', () {
      final spans = _parse(
        '<p>:party: する</p>',
        emojis: [Emoji(shortcode: 'party', url: 'https://example.com/p.gif')],
      );
      expect(spans.whereType<WidgetSpan>(), hasLength(1));
      expect(_findText(spans, ' する'), isNotNull);
    });

    test('未知の shortcode はテキスト (:code:) のまま残る', () {
      final spans = _parse('<p>:unknown: する</p>');
      expect(spans.whereType<WidgetSpan>(), isEmpty);
      expect(_findText(spans, ':unknown:'), isNotNull);
    });

    test('url が空の絵文字定義はテキストのまま残る', () {
      final spans = _parse(
        '<p>:broken:</p>',
        emojis: [Emoji(shortcode: 'broken', url: '')],
      );
      expect(spans.whereType<WidgetSpan>(), isEmpty);
      expect(_findText(spans, ':broken:'), isNotNull);
    });
  });

  group('異常系・特殊ケース', () {
    test('span class="invisible" の中身は出力されない', () {
      expect(
        _flatText(_parse('<p>A<span class="invisible">隠す</span>B</p>')),
        'AB',
      );
    });

    test('閉じタグ欠落の HTML でも例外を投げずパースする', () {
      final spans = _parse('<p><strong>unclosed');
      final span = _findText(spans, 'unclosed');
      expect(span, isNotNull);
      expect(span!.style?.fontWeight, FontWeight.bold);
    });

    test('未知の要素は装飾なしで中身だけ反映される', () {
      expect(_flatText(_parse('<p><marquee>流れる</marquee></p>')), '流れる');
    });

    test('HTML エンティティはデコードされる', () {
      expect(_flatText(_parse('<p>A &amp; B &lt;tag&gt;</p>')), 'A & B <tag>');
    });
  });
}
