// ハッシュタグ検出 / 抽出 / 検証ロジックのテスト。
//
// 正規表現が `lib/utils/hashtag_utils.dart` と `lib/utils/html_parser.dart`
// の `_hashtagRegex` で重複定義されているため、片方を直したら片方を直し忘れ
// るリスクがある。Unicode (CJK, ハングル, キリル文字) や middle dot, em dash
// 等の許容範囲を回帰テストで固定する。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/utils/hashtag_utils.dart';

void main() {
  group('extractHashtagFromUrl', () {
    test('Mastodon /tags/ パス', () {
      expect(
        extractHashtagFromUrl('https://mastodon.social/tags/Flutter'),
        'Flutter',
      );
    });

    test('Mastodon /tag/ パス (一部実装で使われる単数形)', () {
      expect(
        extractHashtagFromUrl('https://example.com/tag/Dart'),
        'Dart',
      );
    });

    test('生の "#tag" 形式', () {
      expect(extractHashtagFromUrl('#hello'), 'hello');
    });

    test('CJK ハッシュタグ', () {
      expect(extractHashtagFromUrl('#日本語'), '日本語');
    });

    test('Percent-encoded をデコードする', () {
      expect(
        extractHashtagFromUrl('https://example.com/tags/%E6%97%A5%E6%9C%AC%E8%AA%9E'),
        '日本語',
      );
    });

    test('不正な percent encoding は raw 値で返す (FormatException で落とさない)', () {
      // `%foo` は decode 失敗 → fallback して raw 値を返す
      final result = extractHashtagFromUrl('https://example.com/tags/%foo');
      expect(result, '%foo');
    });

    test('該当しない URL は null', () {
      expect(extractHashtagFromUrl('https://example.com/users/alice'), isNull);
    });
  });

  group('extractHashtagsFromText', () {
    test('複数タグを順序保ったまま抽出', () {
      expect(
        extractHashtagsFromText('Hello #flutter and #dart world'),
        ['flutter', 'dart'],
      );
    });

    test('Unicode タグ (CJK, ハングル, キリル, ドイツ語)', () {
      expect(
        extractHashtagsFromText('#日本語 #한국어 #русский #München'),
        ['日本語', '한국어', 'русский', 'München'],
      );
    });

    test('middle dot / hyphen / em dash を含むタグ', () {
      expect(
        extractHashtagsFromText('#open-source #front—end #foo·bar'),
        ['open-source', 'front—end', 'foo·bar'],
      );
    });

    test('数字始まりは無視 (Mastodon HASHTAG_NAME_RE と同じ)', () {
      // 先頭が数字のみだと start anchor の `[\p{L}\p{N}_]` には乗るが、
      // Mastodon 仕様では数字オンリーは弾く。`isValidHashtag` 側で除外。
      expect(extractHashtagsFromText('#123'), ['123']);
      expect(isValidHashtag('123'), isFalse);
    });

    test('タグが無いテキスト', () {
      expect(extractHashtagsFromText('just plain text'), isEmpty);
    });
  });

  group('isValidHashtag', () {
    test('通常の英数字タグ', () {
      expect(isValidHashtag('hello'), isTrue);
      expect(isValidHashtag('hello_world'), isTrue);
      expect(isValidHashtag('open-source'), isTrue);
    });

    test('数字のみは無効', () {
      expect(isValidHashtag('123'), isFalse);
    });

    test('空文字は無効', () {
      expect(isValidHashtag(''), isFalse);
    });

    test('Unicode タグも有効', () {
      expect(isValidHashtag('日本語'), isTrue);
      expect(isValidHashtag('한국어'), isTrue);
      expect(isValidHashtag('München'), isTrue);
    });

    test('スペース / 記号を含むものは無効', () {
      expect(isValidHashtag('hello world'), isFalse);
      expect(isValidHashtag('hello!'), isFalse);
    });
  });
}
