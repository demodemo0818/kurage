// Draft の JSON シリアライズのテスト。
//
// SharedPreferences に保存する独自フォーマットなので、キー名は API と違い
// camelCase (`createdAt`)。ここが変わると既存ユーザーの下書きが読めなくなる。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/draft.dart';

void main() {
  group('Draft', () {
    test('toJson → fromJson のラウンドトリップで全フィールドが保たれる', () {
      final draft = Draft(
        id: 'd1',
        title: '下書きタイトル',
        content: '本文です',
        createdAt: DateTime.parse('2026-01-15T10:00:00.000'),
      );
      final restored = Draft.fromJson(draft.toJson());
      expect(restored.id, draft.id);
      expect(restored.title, draft.title);
      expect(restored.content, draft.content);
      expect(restored.createdAt, draft.createdAt);
    });

    test('toJson のキーは camelCase (保存済み下書きとの互換)', () {
      final json = Draft(
        id: 'd1',
        title: 't',
        content: 'c',
        createdAt: DateTime.parse('2026-01-15T10:00:00.000'),
      ).toJson();
      expect(json.keys, containsAll(['id', 'title', 'content', 'createdAt']));
      expect(json['createdAt'], '2026-01-15T10:00:00.000');
    });
  });
}
