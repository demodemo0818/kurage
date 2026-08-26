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

  group('Relationship の id / requested', () {
    test('id をパースする (数値で来ても文字列化する)', () {
      expect(Relationship.fromJson({'id': '42'}).id, '42');
      expect(Relationship.fromJson({'id': 42}).id, '42');
    });

    test('id 欠落時は空文字 (一括取得の Map から除外される目印)', () {
      expect(Relationship.fromJson({}).id, '');
    });

    test('requested をパースする。欠落時は false', () {
      // 鍵アカウントへフォロー申請中は following=false / requested=true。
      // requested を見ないと「フォロー」ボタンが押す前に戻ったように見える。
      final rel = Relationship.fromJson({'following': false, 'requested': true});
      expect(rel.following, false);
      expect(rel.requested, true);
      expect(Relationship.fromJson({}).requested, false);
    });

    test('copyWith が id と requested を保持する', () {
      final rel = Relationship.fromJson({'id': '7', 'requested': true});
      final copied = rel.copyWith(note: 'メモ');
      expect(copied.id, '7');
      expect(copied.requested, true);
      expect(copied.note, 'メモ');
    });
  });
}
