// MastodonList (リスト) のパース・シリアライズのテスト。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/mastodon_list.dart';

void main() {
  group('MastodonList', () {
    test('replies_policy 欠落時は "list" がデフォルト', () {
      final list = MastodonList.fromJson({'id': 'l1', 'title': '友人'});
      expect(list.repliesPolicy, 'list');
    });

    test('toJson のキーは snake_case (replies_policy)', () {
      final json = MastodonList(
        id: 'l1',
        title: '友人',
        repliesPolicy: 'followed',
      ).toJson();
      expect(json, {
        'id': 'l1',
        'title': '友人',
        'replies_policy': 'followed',
      });
    });

    test('toJson → fromJson のラウンドトリップ', () {
      final list = MastodonList(id: 'l1', title: '友人', repliesPolicy: 'none');
      final restored = MastodonList.fromJson(list.toJson());
      expect(restored.id, list.id);
      expect(restored.title, list.title);
      expect(restored.repliesPolicy, list.repliesPolicy);
    });
  });
}
