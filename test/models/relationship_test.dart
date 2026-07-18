// Relationship のパースのテスト。
//
// 核心: Mastodon API のフィールド名は `notifying` (NOT `notifications`)。
// モデルのプロパティ名が notifications なので取り違えやすく、間違った
// キーで読むと「投稿通知購読中」が常に false になる回帰を起こす。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/relationship.dart';

void main() {
  group('Relationship.fromJson', () {
    test('notifying キーで notifications プロパティが立つ', () {
      final rel = Relationship.fromJson({'notifying': true});
      expect(rel.notifications, true);
    });

    test('"notifications" キーでは読まれない (正しいキーは notifying)', () {
      final rel = Relationship.fromJson({'notifications': true});
      expect(rel.notifications, false);
    });

    test('全フィールド欠落時は全 false + note 空文字', () {
      final rel = Relationship.fromJson({});
      expect(rel.following, false);
      expect(rel.followedBy, false);
      expect(rel.blocking, false);
      expect(rel.muting, false);
      expect(rel.notifications, false);
      expect(rel.note, '');
    });

    test('各フラグと note をパースできる', () {
      final rel = Relationship.fromJson({
        'following': true,
        'followed_by': true,
        'blocking': false,
        'muting': true,
        'notifying': false,
        'note': 'メモ',
      });
      expect(rel.following, true);
      expect(rel.followedBy, true);
      expect(rel.muting, true);
      expect(rel.note, 'メモ');
    });
  });

  group('Relationship.copyWith', () {
    test('note だけ差し替え、フラグは保持する', () {
      final rel = Relationship.fromJson({'following': true, 'note': '旧メモ'});
      final copied = rel.copyWith(note: '新メモ');
      expect(copied.note, '新メモ');
      expect(copied.following, true);
    });

    test('引数なしなら note を保持する', () {
      final rel = Relationship.fromJson({'note': 'メモ'});
      expect(rel.copyWith().note, 'メモ');
    });
  });
}
