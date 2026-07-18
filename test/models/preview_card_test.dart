// PreviewCard (status.card の OGP プレビュー) のパースのテスト。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/preview_card.dart';

void main() {
  group('PreviewCard.fromJson', () {
    test('全フィールド欠落時のデフォルト群', () {
      final card = PreviewCard.fromJson({});
      expect(card.url, '');
      expect(card.title, '');
      expect(card.description, '');
      expect(card.image, isNull);
      expect(card.width, 0);
      expect(card.height, 0);
      expect(card.type, 'link');
      expect(card.missingAttribution, false); // 4.6: 欠落時は false
    });

    test('missing_attribution (4.6) をパースできる', () {
      expect(
        PreviewCard.fromJson({'missing_attribution': true}).missingAttribution,
        true,
      );
      expect(
        PreviewCard.fromJson({'missing_attribution': false}).missingAttribution,
        false,
      );
    });

    test('全フィールド入り JSON をパースできる', () {
      final card = PreviewCard.fromJson({
        'url': 'https://example.com/article',
        'title': '記事タイトル',
        'description': '概要',
        'image': 'https://example.com/ogp.png',
        'width': 1200,
        'height': 630,
        'type': 'photo',
      });
      expect(card.url, 'https://example.com/article');
      expect(card.title, '記事タイトル');
      expect(card.image, 'https://example.com/ogp.png');
      expect(card.width, 1200);
      expect(card.height, 630);
      expect(card.type, 'photo');
    });
  });

  group('hasImage', () {
    test('null / 空文字 → false、非空 → true', () {
      expect(PreviewCard.fromJson({}).hasImage, false);
      expect(PreviewCard.fromJson({'image': ''}).hasImage, false);
      expect(
        PreviewCard.fromJson({'image': 'https://example.com/x.png'}).hasImage,
        true,
      );
    });
  });
}
