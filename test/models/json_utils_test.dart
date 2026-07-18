// json_utils (防御的パースヘルパー) のテスト。
//
// Mastodon 派生サーバ (Pleroma/Akkoma 等) の数値 ID と、null / 不正な
// 日時文字列への耐性を固定する。モデルの fromJson はすべてここを経由する。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/json_utils.dart';

void main() {
  group('asIdStringOrNull', () {
    test('String はそのまま、num は toString、それ以外は null', () {
      expect(asIdStringOrNull('abc'), 'abc');
      expect(asIdStringOrNull(123), '123');
      expect(asIdStringOrNull(null), isNull);
      expect(asIdStringOrNull(true), isNull);
      expect(asIdStringOrNull(['x']), isNull);
    });
  });

  group('asIdString', () {
    test('正常値は文字列化して返す', () {
      expect(asIdString('abc'), 'abc');
      expect(asIdString(123), '123');
    });

    test('null / 非対応型は FormatException', () {
      expect(() => asIdString(null), throwsFormatException);
      expect(() => asIdString(true), throwsFormatException);
    });
  });

  group('tryParseDateTime', () {
    test('ISO 8601 文字列をパースする', () {
      expect(tryParseDateTime('2024-01-01T00:00:00.000Z'),
          DateTime.parse('2024-01-01T00:00:00.000Z'));
    });

    test('null / 空文字 / 不正形式 / 非文字列は null', () {
      expect(tryParseDateTime(null), isNull);
      expect(tryParseDateTime(''), isNull);
      expect(tryParseDateTime('not-a-date'), isNull);
      expect(tryParseDateTime(12345), isNull);
    });
  });

  group('parseDateTimeOr', () {
    test('パース失敗時は fallback に倒す', () {
      final fallback = DateTime(2020, 1, 1);
      expect(parseDateTimeOr('broken', fallback), fallback);
      expect(parseDateTimeOr(null, fallback), fallback);
    });

    test('fallback 省略時は現在時刻近傍を返す (クラッシュしない)', () {
      final before = DateTime.now();
      final v = parseDateTimeOr(null);
      final after = DateTime.now();
      expect(v.isBefore(before), isFalse);
      expect(v.isAfter(after), isFalse);
    });
  });
}
