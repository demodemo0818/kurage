// html_text_utils (html_parser から切り出した純粋テキスト処理) のテスト。
//
// extractValidHashtagFromUrl は hashtag_utils の extractHashtagFromUrl と
// 似て非なる関数 (validation あり / fragment 除外 / raw #tag 無し)。
// Unicode 文字集合の網羅は hashtag_utils_test に既にあるので、ここでは
// html_parser 版固有の差分に絞ってテストする。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/utils/html_text_utils.dart';

void main() {
  group('extractValidHashtagFromUrl', () {
    test('/tags/ パスからハッシュタグを抽出する', () {
      expect(
        extractValidHashtagFromUrl('https://example.com/tags/flutter'),
        'flutter',
      );
    });

    test('/tag/ (単数形) パスにも対応する', () {
      expect(
        extractValidHashtagFromUrl('https://example.com/tag/flutter'),
        'flutter',
      );
    });

    test('percent-encoded タグをデコードする', () {
      expect(
        extractValidHashtagFromUrl(
            'https://example.com/tags/%E6%97%A5%E6%9C%AC%E8%AA%9E'),
        '日本語',
      );
    });

    test('不正な percent encoding は raw 値にフォールバックする', () {
      // `%fo` は decode 不能 → FormatException 経路。raw のままでは
      // isValidHashtag を通らない文字 (%) を含むので null になる。
      expect(
        extractValidHashtagFromUrl('https://example.com/tags/%fo'),
        isNull,
      );
    });

    test('非エンコードの生 CJK (Misskey 連合) も拾える (ArgumentError 経路)', () {
      expect(
        extractValidHashtagFromUrl('https://example.com/tags/地下鉄の日'),
        '地下鉄の日',
      );
    });

    test('数字のみのタグは validation で弾いて null (hashtag_utils 版との差分)',
        () {
      expect(
        extractValidHashtagFromUrl('https://example.com/tags/123'),
        isNull,
      );
    });

    test('fragment は文字集合に含めない: /tags/foo#bar → foo', () {
      expect(
        extractValidHashtagFromUrl('https://example.com/tags/foo#bar'),
        'foo',
      );
    });

    test('ハッシュタグパスを含まない URL は null', () {
      expect(
        extractValidHashtagFromUrl('https://example.com/@alice/12345'),
        isNull,
      );
    });
  });

  group('shortenUrl', () {
    test('50 文字以下はそのまま返す', () {
      const url = 'https://example.com/short';
      expect(shortenUrl(url), url);
    });

    test('長いパス (20 文字超) は domain + パス先頭 17 文字 + "..." に短縮する',
        () {
      final url =
          'https://example.com/${'a' * 60}'; // path は '/aaa...' で 61 文字
      final result = shortenUrl(url);
      expect(result, 'example.com/${'a' * 16}...');
      expect(result.length, lessThan(url.length));
    });

    test('50 文字超でもパスが 20 文字以下なら domain + path を返す', () {
      // クエリで全長を 50 文字超にし、パス自体は短いケース。
      final url = 'https://example.com/p?q=${'x' * 40}';
      expect(shortenUrl(url), 'example.com/p');
    });
  });

  group('parseHtmlToPlainText', () {
    test('<br> は改行になる', () {
      expect(parseHtmlToPlainText('一行目<br>二行目'), '一行目\n二行目');
    });

    test('<p> ごとに改行で区切られる', () {
      expect(parseHtmlToPlainText('<p>段落1</p><p>段落2</p>'), '段落1\n段落2');
    });

    test('<span class="invisible"> の中身は除外される (Mastodon の URL 短縮)',
        () {
      // Mastodon の URL は invisible + ellipsis + invisible の 3 段構成。
      const html = '<a href="https://example.com/very/long/path">'
          '<span class="invisible">https://</span>'
          '<span class="ellipsis">example.com/very</span>'
          '<span class="invisible">/long/path</span></a>';
      expect(parseHtmlToPlainText(html), 'example.com/very');
    });

    test('<li> は "• " 付きの行になる', () {
      expect(
        parseHtmlToPlainText('<ul><li>項目1</li><li>項目2</li></ul>'),
        '• 項目1\n• 項目2',
      );
    });

    test('3 連続以上の改行は 2 つに畳み込まれ、前後は trim される', () {
      expect(
        parseHtmlToPlainText('<p>A</p><br><br><p>B</p><br>'),
        'A\n\nB',
      );
    });
  });
}
