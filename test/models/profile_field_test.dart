// ProfileField (プロフィール補足項目) のパースと認証判定のテスト。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/profile_field.dart';

void main() {
  group('ProfileField.fromJson', () {
    test('name / value 欠落 → 空文字', () {
      final field = ProfileField.fromJson({});
      expect(field.name, '');
      expect(field.value, '');
      expect(field.verifiedAt, isNull);
    });

    test('verified_at をパースして isVerified が true になる', () {
      final field = ProfileField.fromJson({
        'name': 'Website',
        'value': '<a href="https://example.com">example.com</a>',
        'verified_at': '2026-01-15T10:00:00.000Z',
      });
      expect(field.verifiedAt, DateTime.parse('2026-01-15T10:00:00.000Z'));
      expect(field.isVerified, true);
    });

    test('verified_at 不正文字列は tryParse で null → 未認証扱い', () {
      final field = ProfileField.fromJson({'verified_at': 'not-a-date'});
      expect(field.verifiedAt, isNull);
      expect(field.isVerified, false);
    });

    test('verified_at 欠落は未認証', () {
      expect(ProfileField.fromJson({'name': 'X'}).isVerified, false);
    });
  });
}
