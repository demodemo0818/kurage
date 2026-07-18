// Emoji (カスタム絵文字) のパースと URL 選択のテスト。
//
// visible_in_picker は「true なら [] / それ以外は null」という特殊な変換を
// している (現実装の挙動をそのまま固定する)。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/emoji.dart';

Map<String, dynamic> _emojiJson({Map<String, dynamic> extra = const {}}) => {
      'shortcode': 'party',
      'url': 'https://example.com/party.gif',
      ...extra,
    };

void main() {
  group('Emoji.fromJson', () {
    test('static_url null 時は nonAnimatedUrl が url にフォールバックする', () {
      final emoji = Emoji.fromJson(_emojiJson());
      expect(emoji.staticUrl, isNull);
      expect(emoji.nonAnimatedUrl, 'https://example.com/party.gif');
      expect(emoji.animatedUrl, 'https://example.com/party.gif');
    });

    test('static_url ありなら nonAnimatedUrl はそれを使う', () {
      final emoji = Emoji.fromJson(_emojiJson(
          extra: {'static_url': 'https://example.com/party.png'}));
      expect(emoji.nonAnimatedUrl, 'https://example.com/party.png');
    });

    test('visible_in_picker: true → [] / false・欠落 → null (現実装の挙動)', () {
      expect(
        Emoji.fromJson(_emojiJson(extra: {'visible_in_picker': true}))
            .visibleInPicker,
        isEmpty,
      );
      expect(
        Emoji.fromJson(_emojiJson(extra: {'visible_in_picker': false}))
            .visibleInPicker,
        isNull,
      );
      expect(Emoji.fromJson(_emojiJson()).visibleInPicker, isNull);
    });

    test('category: 空文字・空白のみ → null / 非空 → 保持', () {
      expect(
          Emoji.fromJson(_emojiJson(extra: {'category': ''})).category, isNull);
      expect(Emoji.fromJson(_emojiJson(extra: {'category': '  '})).category,
          isNull);
      expect(Emoji.fromJson(_emojiJson(extra: {'category': 'パーティー'})).category,
          'パーティー');
      expect(Emoji.fromJson(_emojiJson()).category, isNull);
    });
  });

  group('isAnimated', () {
    test('url が .gif なら true', () {
      expect(Emoji.fromJson(_emojiJson()).isAnimated, true);
    });

    test('staticUrl が url と異なれば true', () {
      final emoji = Emoji.fromJson({
        'shortcode': 'party',
        'url': 'https://example.com/party.webp',
        'static_url': 'https://example.com/party_static.webp',
      });
      expect(emoji.isAnimated, true);
    });

    test('staticUrl == url で .gif でもなければ false', () {
      final emoji = Emoji.fromJson({
        'shortcode': 'party',
        'url': 'https://example.com/party.png',
        'static_url': 'https://example.com/party.png',
      });
      expect(emoji.isAnimated, false);
    });
  });
}
