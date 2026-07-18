// NotificationItem のパース (fromJson / listFromJson) の回帰テスト。
//
// 背景: 引用投稿の通知 (Mastodon 4.4+ の `type: "quote"`) が NotificationType
// に未定義だった頃、SSE では unknown のまま「その他」に表示される一方、REST
// リロード経路 (`listFromJson`) は unknown を除外していたため、引き下げ更新で
// 引用通知が消えていた。`quote` を第一級の型として追加して修正したので、その
// 型マッピングと「listFromJson が quote を捨てない」ことを恒久的に守る。
//
// fromJson は account を非 null 前提で `Account.fromJson` に渡す
// (notification_item.dart) ため、最小だが妥当な account JSON を必ず添える。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/notification_item.dart';

/// `Account.fromJson` の必須項目 (id / username / display_name / created_at)
/// だけ持つ最小 account JSON。他はフォールバックがあるので省略する。
Map<String, dynamic> _accountJson({String id = '789'}) => {
      'id': id,
      'username': 'alice',
      'display_name': 'Alice',
      'created_at': '2024-01-01T00:00:00.000Z',
    };

/// `Status.fromJson` の必須項目だけ持つ最小 status JSON。
Map<String, dynamic> _statusJson({String id = '456'}) => {
      'id': id,
      'content': '引用された投稿',
      'created_at': '2026-01-15T10:00:00.000Z',
      'account': _accountJson(),
    };

/// 通知 1 件分の最小 JSON。`type` を差し替えて型マッピングを検証する。
Map<String, dynamic> _notifJson(
  String type, {
  String id = '123',
  bool withStatus = false,
}) =>
    {
      'id': id,
      'type': type,
      'created_at': '2026-01-15T10:30:00.000Z',
      'account': _accountJson(),
      if (withStatus) 'status': _statusJson(),
    };

void main() {
  group('NotificationItem.fromJson type マッピング', () {
    // API の type 文字列 → NotificationType 列挙のマッピング表。
    const cases = <String, NotificationType>{
      'mention': NotificationType.mention,
      'reply': NotificationType.reply,
      'favourite': NotificationType.favourite,
      'reblog': NotificationType.reblog,
      'follow': NotificationType.follow,
      'poll': NotificationType.poll,
      'emoji_reaction': NotificationType.reaction,
      'follow_request': NotificationType.followRequest,
      'status': NotificationType.status,
      'quote': NotificationType.quote, // ← 今回の回帰の核
      'added_to_collection': NotificationType.addedToCollection, // Mastodon 4.6
      'collection_update': NotificationType.collectionUpdate, // Mastodon 4.6
    };

    cases.forEach((raw, expected) {
      test('"$raw" → $expected', () {
        final item = NotificationItem.fromJson(_notifJson(raw));
        expect(item.type, expected);
      });
    });

    test('未知の type は unknown にフォールバックする', () {
      final item = NotificationItem.fromJson(_notifJson('admin.report'));
      expect(item.type, NotificationType.unknown);
    });

    test('id / createdAt / account も正しくパースされる', () {
      final item = NotificationItem.fromJson(_notifJson('quote', id: 'n42'));
      expect(item.id, 'n42');
      expect(item.createdAt, DateTime.parse('2026-01-15T10:30:00.000Z'));
      expect(item.account.username, 'alice');
    });
  });

  group('NotificationItem.fromJson status の有無', () {
    test('status 有りなら item.status は non-null', () {
      final item =
          NotificationItem.fromJson(_notifJson('quote', withStatus: true));
      expect(item.status, isNotNull);
      expect(item.status!.id, '456');
    });

    test('status 無しなら item.status は null', () {
      final item = NotificationItem.fromJson(_notifJson('follow'));
      expect(item.status, isNull);
    });
  });

  group('NotificationItem.listFromJson のフィルタ', () {
    test('quote を含む配列は quote が残る (リロードで消えないことの回帰)', () {
      final body = json.encode([_notifJson('quote', id: 'q1')]);
      final items = NotificationItem.listFromJson(body);
      expect(items, hasLength(1));
      expect(items.single.type, NotificationType.quote);
      expect(items.single.id, 'q1');
    });

    test('collection 通知 (4.6) は listFromJson で残る (黙って消えない回帰)', () {
      final body = json.encode([
        _notifJson('added_to_collection', id: 'c1'),
        _notifJson('collection_update', id: 'c2'),
      ]);
      final items = NotificationItem.listFromJson(body);
      expect(items.map((i) => i.id), ['c1', 'c2']);
      expect(items.map((i) => i.type), [
        NotificationType.addedToCollection,
        NotificationType.collectionUpdate,
      ]);
    });

    test('真に未知の type は除外される (unknown フィルタは維持)', () {
      final body = json.encode([_notifJson('severed_relationships')]);
      final items = NotificationItem.listFromJson(body);
      expect(items, isEmpty);
    });

    test('quote + favourite + 未知 の混在は known の 2 件だけ残る', () {
      final body = json.encode([
        _notifJson('quote', id: 'q1'),
        _notifJson('favourite', id: 'f1'),
        _notifJson('some_future_type', id: 'x1'),
      ]);
      final items = NotificationItem.listFromJson(body);
      expect(items.map((i) => i.id), ['q1', 'f1']);
      expect(items.map((i) => i.type),
          [NotificationType.quote, NotificationType.favourite]);
    });
  });

  group('NotificationItem.fromJson fallback (4.6)', () {
    test('fallback 属性があれば type / account / raw を取り出す', () {
      final j = _notifJson('mention', id: 'n1');
      j['fallback'] = {
        'type': 'admin.sign_up',
        'account': _accountJson(id: 'fb1'),
      };
      final item = NotificationItem.fromJson(j);
      expect(item.fallback, isNotNull);
      expect(item.fallback!.type, 'admin.sign_up');
      expect(item.fallback!.account?.id, 'fb1');
      expect(item.fallback!.raw['type'], 'admin.sign_up');
    });

    test('fallback が無ければ null', () {
      final item = NotificationItem.fromJson(_notifJson('favourite'));
      expect(item.fallback, isNull);
    });
  });

  group('NotificationItem.fromJson collectionId (4.6, 寛容パース)', () {
    test('collection_id 直接指定を拾う', () {
      final j = _notifJson('added_to_collection');
      j['collection_id'] = 'col1';
      expect(NotificationItem.fromJson(j).collectionId, 'col1');
    });

    test('埋め込み collection.id を拾う', () {
      final j = _notifJson('collection_update');
      j['collection'] = {'id': 'col2', 'name': 'x'};
      expect(NotificationItem.fromJson(j).collectionId, 'col2');
    });

    test('数値 id も文字列へ正規化', () {
      final j = _notifJson('added_to_collection');
      j['collection_id'] = 99;
      expect(NotificationItem.fromJson(j).collectionId, '99');
    });

    test('collection 参照が無ければ null (プロフィールへフォールバックする側)', () {
      expect(
          NotificationItem.fromJson(_notifJson('favourite')).collectionId,
          isNull);
    });
  });
}
