// InstanceRule (サーバルール) のパースのテスト。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/instance_rule.dart';

void main() {
  group('InstanceRule.fromJson', () {
    test('id が JSON int でも文字列に正規化される', () {
      final rule = InstanceRule.fromJson({'id': 1, 'text': 'ルール1'});
      expect(rule.id, '1');
      expect(rule.text, 'ルール1');
    });

    test('text 欠落 → 空文字 / hint 欠落 → null', () {
      final rule = InstanceRule.fromJson({'id': 'r1'});
      expect(rule.text, '');
      expect(rule.hint, isNull);
    });

    test('hint ありをパースできる', () {
      final rule = InstanceRule.fromJson(
          {'id': 'r1', 'text': 'ルール', 'hint': '詳細説明'});
      expect(rule.hint, '詳細説明');
    });
  });
}
