// NotificationGroup の組み立て / マージ / v2 パースの回帰テスト。
//
// 通知プロバイダは「サーバ集約グループ」も「SSE 単発通知」も同じ
// NotificationGroup として扱う。client-side マージ (canMerge / mergedWith) と
// v2 レスポンスのパース (fromV2Json) はバグると通知の重複表示・取りこぼし・
// 件数ズレに直結する。特に引用通知 (quote) は「各引用が別投稿」なので
// canMerge が常に false であることを守る必要がある。
//
// canMerge / mergedWith / single はオブジェクトを直接組んで入力にする
// (status_test.dart と同じ方針)。fromV2Json は最小 JSON Map で検証する。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/account.dart';
import 'package:kurage/models/notification_group.dart';
import 'package:kurage/models/notification_item.dart';
import 'package:kurage/models/status.dart';

Account _account(String id) => Account(
      id: id,
      username: 'u$id',
      acct: 'u$id',
      url: '',
      displayName: 'User $id',
      avatarUrl: '',
      headerUrl: '',
      note: '',
      fields: const [],
      followersCount: 0,
      followingCount: 0,
      statusesCount: 0,
      createdAt: DateTime(2024, 1, 1),
      locked: false,
      bot: false,
      emojis: const [],
    );

Status _status(String id) => Status(
      id: id,
      content: '',
      createdAt: DateTime(2026, 1, 15, 10, 0),
      account: _account('a1'),
      visibility: 'public',
      favourited: false,
      reblogged: false,
      bookmarked: false,
    );

NotificationItem _item({
  required NotificationType type,
  String id = 'n1',
  String sourceAccountId = 'acc1',
  Status? status,
  DateTime? createdAt,
  String? collectionId,
}) =>
    NotificationItem(
      id: id,
      type: type,
      createdAt: createdAt ?? DateTime(2026, 1, 15, 10, 0),
      account: _account('a1'),
      status: status,
      sourceAccountId: sourceAccountId,
      collectionId: collectionId,
    );

/// canMerge / mergedWith 用にフィールドを自由に組める NotificationGroup。
NotificationGroup _group({
  required NotificationType type,
  String groupKey = 'g',
  String? sourceAccountId = 'acc1',
  Status? status,
  DateTime? latestAt,
  List<Account>? sampleAccounts,
  int count = 1,
}) =>
    NotificationGroup(
      id: groupKey,
      groupKey: groupKey,
      type: type,
      latestAt: latestAt ?? DateTime(2026, 1, 15, 10, 0),
      notificationsCount: count,
      sampleAccounts: sampleAccounts ?? [_account('a1')],
      mostRecentNotificationId: groupKey,
      status: status,
      sourceAccountId: sourceAccountId,
    );

/// fromV2Json 用の最小グループ JSON。`type` は必須 (非 null String)。
Map<String, dynamic> _v2GroupJson(
  String type, {
  String groupKey = 'gk1',
  Object mostRecentId = 'n1',
}) =>
    {
      'type': type,
      'group_key': groupKey,
      'most_recent_notification_id': mostRecentId,
    };

void main() {
  group('NotificationGroup.single', () {
    test('単発通知を件数 1 のグループにラップし、各フィールドを引き継ぐ', () {
      final item = _item(
        type: NotificationType.quote,
        id: 'n42',
        sourceAccountId: 'accX',
        status: _status('s9'),
      );
      final g = NotificationGroup.single(item);

      expect(g.notificationsCount, 1);
      expect(g.isGroup, isFalse);
      expect(g.type, NotificationType.quote);
      expect(g.id, 'n42');
      expect(g.groupKey, 'n42');
      expect(g.mostRecentNotificationId, 'n42');
      expect(g.sourceAccountId, 'accX');
      expect(g.status?.id, 's9');
      expect(g.sampleAccounts.single.id, item.account.id);
    });

    test('collectionId も引き継ぐ (4.6)', () {
      final item = _item(
        type: NotificationType.addedToCollection,
        collectionId: 'col9',
      );
      expect(NotificationGroup.single(item).collectionId, 'col9');
    });
  });

  group('NotificationGroup.fromV2Json type / ID 正規化', () {
    test('"quote" → quote', () {
      final g = NotificationGroup.fromV2Json(_v2GroupJson('quote'), {}, {});
      expect(g.type, NotificationType.quote);
    });

    test('"favourite" → favourite', () {
      final g = NotificationGroup.fromV2Json(_v2GroupJson('favourite'), {}, {});
      expect(g.type, NotificationType.favourite);
    });

    test('"added_to_collection" → addedToCollection (4.6)', () {
      final g = NotificationGroup.fromV2Json(
          _v2GroupJson('added_to_collection'), {}, {});
      expect(g.type, NotificationType.addedToCollection);
    });

    test('"collection_update" → collectionUpdate (4.6)', () {
      final g = NotificationGroup.fromV2Json(
          _v2GroupJson('collection_update'), {}, {});
      expect(g.type, NotificationType.collectionUpdate);
    });

    test('未知の type → unknown', () {
      final g =
          NotificationGroup.fromV2Json(_v2GroupJson('mystery'), {}, {});
      expect(g.type, NotificationType.unknown);
    });

    test('数値の most_recent_notification_id は文字列へ正規化 (Pleroma/Akkoma 対応)',
        () {
      final g = NotificationGroup.fromV2Json(
        _v2GroupJson('quote', mostRecentId: 123),
        {},
        {},
      );
      expect(g.mostRecentNotificationId, '123');
    });

    test('collection_id / collection.id を寛容に拾う (4.6)', () {
      final direct = _v2GroupJson('added_to_collection')
        ..['collection_id'] = 'col1';
      expect(NotificationGroup.fromV2Json(direct, {}, {}).collectionId, 'col1');

      final embedded = _v2GroupJson('collection_update')
        ..['collection'] = {'id': 'col2'};
      expect(
          NotificationGroup.fromV2Json(embedded, {}, {}).collectionId, 'col2');

      final none = _v2GroupJson('favourite');
      expect(NotificationGroup.fromV2Json(none, {}, {}).collectionId, isNull);
    });
  });

  group('NotificationGroup.canMerge', () {
    test('quote 同士は常に false (各引用は別投稿)', () {
      final base = _group(type: NotificationType.quote, status: _status('s1'));
      final incoming =
          _group(type: NotificationType.quote, status: _status('s2'));
      expect(base.canMerge(incoming), isFalse);
    });

    test('favourite で同じ status_id なら true', () {
      final base =
          _group(type: NotificationType.favourite, status: _status('s1'));
      final incoming =
          _group(type: NotificationType.favourite, status: _status('s1'));
      expect(base.canMerge(incoming), isTrue);
    });

    test('favourite で status_id が違えば false', () {
      final base =
          _group(type: NotificationType.favourite, status: _status('s1'));
      final incoming =
          _group(type: NotificationType.favourite, status: _status('s2'));
      expect(base.canMerge(incoming), isFalse);
    });

    test('sourceAccountId が違えば (同 type でも) false', () {
      final base = _group(
        type: NotificationType.favourite,
        sourceAccountId: 'acc1',
        status: _status('s1'),
      );
      final incoming = _group(
        type: NotificationType.favourite,
        sourceAccountId: 'acc2',
        status: _status('s1'),
      );
      expect(base.canMerge(incoming), isFalse);
    });

    test('follow は 5 分以内なら true', () {
      final t = DateTime(2026, 1, 15, 10, 0);
      final base = _group(type: NotificationType.follow, latestAt: t);
      final incoming = _group(
          type: NotificationType.follow,
          latestAt: t.add(const Duration(minutes: 3)));
      expect(base.canMerge(incoming), isTrue);
    });

    test('follow は 5 分を超えると false', () {
      final t = DateTime(2026, 1, 15, 10, 0);
      final base = _group(type: NotificationType.follow, latestAt: t);
      final incoming = _group(
          type: NotificationType.follow,
          latestAt: t.add(const Duration(minutes: 10)));
      expect(base.canMerge(incoming), isFalse);
    });

    test('mention は常に false', () {
      final base = _group(type: NotificationType.mention, status: _status('s1'));
      final incoming =
          _group(type: NotificationType.mention, status: _status('s1'));
      expect(base.canMerge(incoming), isFalse);
    });

    test('collection 通知 (4.6) は常に false (singleton)', () {
      final addBase = _group(type: NotificationType.addedToCollection);
      final addIncoming = _group(type: NotificationType.addedToCollection);
      expect(addBase.canMerge(addIncoming), isFalse);
      final updBase = _group(type: NotificationType.collectionUpdate);
      final updIncoming = _group(type: NotificationType.collectionUpdate);
      expect(updBase.canMerge(updIncoming), isFalse);
    });
  });

  group('NotificationGroup.mergedWith', () {
    test('新規アクターは件数 +1、先頭に追加、latestAt は新しい方', () {
      final t = DateTime(2026, 1, 15, 10, 0);
      final base = _group(
        type: NotificationType.favourite,
        sampleAccounts: [_account('a1')],
        count: 1,
        latestAt: t,
      );
      final incoming = _group(
        type: NotificationType.favourite,
        sampleAccounts: [_account('a2')],
        latestAt: t.add(const Duration(minutes: 1)),
      );
      final merged = base.mergedWith(incoming);

      expect(merged.notificationsCount, 2);
      expect(merged.sampleAccounts.map((a) => a.id), ['a2', 'a1']);
      expect(merged.latestAt, t.add(const Duration(minutes: 1)));
    });

    test('重複アクターは件数据え置きで先頭へ移動', () {
      final base = _group(
        type: NotificationType.favourite,
        sampleAccounts: [_account('a1'), _account('a2')],
        count: 2,
      );
      final incoming = _group(
        type: NotificationType.favourite,
        sampleAccounts: [_account('a2')],
      );
      final merged = base.mergedWith(incoming);

      expect(merged.notificationsCount, 2);
      expect(merged.sampleAccounts.map((a) => a.id), ['a2', 'a1']);
    });

    test('sampleAccounts は最大 6 件で打ち切る', () {
      final base = _group(
        type: NotificationType.favourite,
        sampleAccounts: [for (var i = 1; i <= 6; i++) _account('a$i')],
        count: 6,
      );
      final incoming = _group(
        type: NotificationType.favourite,
        sampleAccounts: [_account('a7')],
      );
      final merged = base.mergedWith(incoming);

      expect(merged.sampleAccounts, hasLength(6));
      expect(merged.sampleAccounts.first.id, 'a7');
      expect(merged.notificationsCount, 7);
    });

    test('古い incoming でも latestAt は元の新しい方を維持', () {
      final t = DateTime(2026, 1, 15, 10, 0);
      final base = _group(
        type: NotificationType.favourite,
        sampleAccounts: [_account('a1')],
        latestAt: t,
      );
      final incoming = _group(
        type: NotificationType.favourite,
        sampleAccounts: [_account('a2')],
        latestAt: t.subtract(const Duration(minutes: 5)),
      );
      final merged = base.mergedWith(incoming);
      expect(merged.latestAt, t);
    });
  });

  group('NotificationGroup.mergeFetched', () {
    final t = DateTime(2026, 1, 15, 10, 0);

    test('同一 groupKey は fetched (server 側) の値で置換される', () {
      final current = [
        _group(type: NotificationType.favourite, groupKey: 'g1', count: 1),
      ];
      final fetched = [
        _group(type: NotificationType.favourite, groupKey: 'g1', count: 3),
      ];
      final merged = NotificationGroup.mergeFetched(fetched, current);
      expect(merged, hasLength(1));
      expect(merged.single.notificationsCount, 3);
    });

    test('新規 groupKey は追加される', () {
      final current = [
        _group(type: NotificationType.favourite, groupKey: 'g1'),
      ];
      final fetched = [
        _group(type: NotificationType.reblog, groupKey: 'g2'),
      ];
      final merged = NotificationGroup.mergeFetched(fetched, current);
      expect(merged.map((g) => g.groupKey).toSet(), {'g1', 'g2'});
    });

    test('結果は latestAt 降順にソートされる', () {
      final current = [
        _group(
          type: NotificationType.favourite,
          groupKey: 'old',
          latestAt: t.subtract(const Duration(hours: 1)),
        ),
      ];
      final fetched = [
        _group(type: NotificationType.reblog, groupKey: 'newest', latestAt: t),
        _group(
          type: NotificationType.mention,
          groupKey: 'middle',
          latestAt: t.subtract(const Duration(minutes: 30)),
        ),
      ];
      final merged = NotificationGroup.mergeFetched(fetched, current);
      expect(merged.map((g) => g.groupKey), ['newest', 'middle', 'old']);
    });

    test('fetched が空でも current は維持される', () {
      final current = [
        _group(type: NotificationType.favourite, groupKey: 'g1'),
      ];
      final merged = NotificationGroup.mergeFetched(const [], current);
      expect(merged, hasLength(1));
      expect(merged.single.groupKey, 'g1');
    });
  });
}
