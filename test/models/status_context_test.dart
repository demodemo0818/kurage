// StatusContext (スレッド表示用 ancestors/descendants) のパースのテスト。
//
// fromJson はサーバの返却順に依存せず createdAt 昇順 (古い順) に並べ替える。
// スレッドページの表示順の前提なので、シャッフルした入力で固定する。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/status_context.dart';

Map<String, dynamic> _statusJson(String id, String createdAt) => {
      'id': id,
      'content': '投稿 $id',
      'created_at': createdAt,
      'account': {
        'id': '1',
        'username': 'alice',
        'display_name': 'Alice',
        'created_at': '2024-01-01T00:00:00.000Z',
      },
    };

void main() {
  group('StatusContext.fromJson', () {
    test('ancestors / descendants が createdAt 昇順に並べ替えられる', () {
      final context = StatusContext.fromJson({
        'ancestors': [
          _statusJson('a3', '2026-01-15T12:00:00.000Z'),
          _statusJson('a1', '2026-01-15T10:00:00.000Z'),
          _statusJson('a2', '2026-01-15T11:00:00.000Z'),
        ],
        'descendants': [
          _statusJson('d2', '2026-01-15T14:00:00.000Z'),
          _statusJson('d1', '2026-01-15T13:00:00.000Z'),
        ],
      });
      expect(context.ancestors.map((s) => s.id), ['a1', 'a2', 'a3']);
      expect(context.descendants.map((s) => s.id), ['d1', 'd2']);
    });

    test('空配列でもパースできる', () {
      final context =
          StatusContext.fromJson({'ancestors': [], 'descendants': []});
      expect(context.ancestors, isEmpty);
      expect(context.descendants, isEmpty);
    });
  });
}
