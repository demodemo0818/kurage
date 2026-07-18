// TimelineItem (PostItem / GapItem) のテスト。
//
// マージ TL の dedup は `==` (id のみ比較) に依存しているため、
// 「id が同じなら他が違っても等価」をここで固定する。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/account.dart';
import 'package:kurage/models/status.dart';
import 'package:kurage/models/timeline_gap.dart';
import 'package:kurage/models/timeline_item.dart';

Status _status({String id = 's1', DateTime? createdAt}) {
  final account = Account(
    id: '1',
    username: 'alice',
    acct: 'alice',
    url: '',
    displayName: 'Alice',
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
  return Status(
    id: id,
    content: '投稿',
    createdAt: createdAt ?? DateTime(2026, 1, 15, 10, 0),
    account: account,
    visibility: 'public',
    favourited: false,
    reblogged: false,
    bookmarked: false,
  );
}

TimelineGap _gap({
  String id = 'g1',
  DateTime? newerDate,
  Map<String, SourceGapBounds>? perSource,
}) =>
    TimelineGap(
      id: id,
      anchorNewerStatusId: 's100',
      perSource: perSource ??
          {'acc1': const SourceGapBounds(timelineType: 'home')},
      newerDate: newerDate,
    );

void main() {
  group('PostItem', () {
    test('id / createdAt は status へ委譲される', () {
      final created = DateTime(2026, 1, 15, 10, 0);
      final item =
          PostItem(status: _status(createdAt: created), accountId: 'acc1');
      expect(item.id, 's1');
      expect(item.createdAt, created);
      expect(item.accountId, 'acc1');
    });

    test('== は id のみで決まる (accountId が違っても等価)', () {
      final a = PostItem(status: _status(), accountId: 'acc1');
      final b = PostItem(status: _status(), accountId: 'acc2');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a == PostItem(status: _status(id: 's2'), accountId: 'acc1'),
        false,
      );
    });
  });

  group('GapItem', () {
    test('createdAt は newerDate (非 null 時)', () {
      final newer = DateTime(2026, 1, 15, 12, 0);
      expect(GapItem(gap: _gap(newerDate: newer)).createdAt, newer);
    });

    test('newerDate null 時は now にフォールバックする', () {
      final item = GapItem(gap: _gap());
      expect(
        item.createdAt.difference(DateTime.now()).abs(),
        lessThan(const Duration(seconds: 5)),
      );
    });

    test('accountId は perSource の最初のキー、空 map なら空文字', () {
      expect(GapItem(gap: _gap()).accountId, 'acc1');
      expect(GapItem(gap: _gap(perSource: {})).accountId, '');
    });

    test('== は id のみで決まる', () {
      final a = GapItem(gap: _gap(newerDate: DateTime(2026, 1, 15)));
      final b = GapItem(gap: _gap());
      expect(a, b);
      expect(a == GapItem(gap: _gap(id: 'g2')), false);
    });
  });
}
