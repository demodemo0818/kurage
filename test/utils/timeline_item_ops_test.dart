// timeline_item_ops (insertGapsByAnchor / unreadIdsAboveAnchor) のテスト。
//
// ColumnTimelineView は `_items` を投稿ベースで全再構築する経路 (refresh /
// SSE フラッシュのフォールバック / loadMore) で必ず insertGapsByAnchor を
// 通してギャップを保全する。ここが壊れると「ストリーミング中にギャップ
// ボタンが消える」回帰になる。
//
// unreadIdsAboveAnchor は未読バッジの「未読 = 視点より上の新着」セマンティクス
// の本体。アンカーより下に interleave された投稿を未読に積むと、上スクロール
// で通過せず可視判定で消えないため、バッジ件数が実際と合わなくなる。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/account.dart';
import 'package:kurage/models/status.dart';
import 'package:kurage/models/timeline_gap.dart';
import 'package:kurage/models/timeline_item.dart';
import 'package:kurage/utils/timeline_item_ops.dart';

/// id と作成日時だけ意味を持つ最小 Status で PostItem を組む。
PostItem _post(String id, {String accountId = 'acc1'}) {
  final account = Account(
    id: 'a1',
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
  return PostItem(
    status: Status(
      id: id,
      content: '',
      createdAt: DateTime(2024, 1, 1),
      account: account,
      visibility: 'public',
      favourited: false,
      reblogged: false,
      bookmarked: false,
    ),
    accountId: accountId,
  );
}

GapItem _gap(String id, String anchorNewerStatusId) {
  return GapItem(
    gap: TimelineGap(
      id: id,
      anchorNewerStatusId: anchorNewerStatusId,
      perSource: {
        'acc1': const SourceGapBounds(timelineType: 'home'),
      },
    ),
  );
}

/// リストを「post id / gap id」の文字列リストに落として比較しやすくする。
List<String> _ids(List<TimelineItem> items) => [
      for (final it in items)
        switch (it) {
          PostItem(:final status) => 'p:${status.id}',
          GapItem(:final gap) => 'g:${gap.id}',
          _ => '?',
        },
    ];

void main() {
  group('insertGapsByAnchor', () {
    test('preservedGap がアンカー投稿の直下に挿入される', () {
      final rebuilt = <TimelineItem>[_post('3'), _post('2'), _post('1')];
      final result =
          insertGapsByAnchor(rebuilt, const [], [_gap('gap_2_1', '2')]);
      expect(_ids(result), ['p:3', 'p:2', 'g:gap_2_1', 'p:1']);
    });

    test('newGap も同様に挿入される', () {
      final rebuilt = <TimelineItem>[_post('3'), _post('2'), _post('1')];
      final result =
          insertGapsByAnchor(rebuilt, [_gap('gap_3_2', '3')], const []);
      expect(_ids(result), ['p:3', 'g:gap_3_2', 'p:2', 'p:1']);
    });

    test('アンカー投稿が存在しないギャップは silent drop される', () {
      final rebuilt = <TimelineItem>[_post('3'), _post('1')];
      final result =
          insertGapsByAnchor(rebuilt, const [], [_gap('gap_x', 'deleted')]);
      expect(_ids(result), ['p:3', 'p:1']);
    });

    test('newGaps と preservedGaps で id が重なる場合は 1 つだけ挿入される', () {
      final rebuilt = <TimelineItem>[_post('3'), _post('2'), _post('1')];
      final result = insertGapsByAnchor(
        rebuilt,
        [_gap('gap_2_1', '2')],
        [_gap('gap_2_1', '2')],
      );
      expect(_ids(result), ['p:3', 'p:2', 'g:gap_2_1', 'p:1']);
    });

    test('同一 id のギャップが重複していても 1 つだけ挿入される (防御)', () {
      final rebuilt = <TimelineItem>[_post('2'), _post('1')];
      final result = insertGapsByAnchor(
        rebuilt,
        const [],
        [_gap('gap_2_1', '2'), _gap('gap_2_1', '2')],
      );
      expect(_ids(result), ['p:2', 'g:gap_2_1', 'p:1']);
    });

    test('異なるアンカーの複数ギャップが両方挿入される', () {
      final rebuilt =
          <TimelineItem>[_post('4'), _post('3'), _post('2'), _post('1')];
      final result = insertGapsByAnchor(
        rebuilt,
        [_gap('gap_4_3', '4')],
        [_gap('gap_2_1', '2')],
      );
      expect(_ids(result),
          ['p:4', 'g:gap_4_3', 'p:3', 'p:2', 'g:gap_2_1', 'p:1']);
    });

    test('空リストにギャップを渡しても何も起きない', () {
      final result =
          insertGapsByAnchor(<TimelineItem>[], const [], [_gap('g', '1')]);
      expect(result, isEmpty);
    });
  });

  group('unreadIdsAboveAnchor', () {
    test('アンカーより上の candidate だけ返す (下に interleave された分は除外)', () {
      // 5 (新着) / 4 (アンカー = 視点) / 3 (新着だが視点より下に interleave) / 2
      final items = <TimelineItem>[_post('5'), _post('4'), _post('3'), _post('2')];
      final result = unreadIdsAboveAnchor(
        items: items,
        anchorKey: 'post:4',
        candidateIds: {'5', '3'},
      );
      expect(result, {'5'});
    });

    test('アンカーが GapItem でも正しく打ち切る', () {
      final items = <TimelineItem>[
        _post('5'),
        _gap('gap_5_2', '5'),
        _post('2'),
      ];
      final result = unreadIdsAboveAnchor(
        items: items,
        anchorKey: 'gap:gap_5_2',
        candidateIds: {'5', '2'},
      );
      expect(result, {'5'});
    });

    test('anchorKey が null なら全件返す (フォールバック)', () {
      final items = <TimelineItem>[_post('2'), _post('1')];
      final result = unreadIdsAboveAnchor(
        items: items,
        anchorKey: null,
        candidateIds: {'2', '1'},
      );
      expect(result, {'2', '1'});
    });

    test('アンカーがリストに存在しなければ全件返す (フォールバック)', () {
      final items = <TimelineItem>[_post('2'), _post('1')];
      final result = unreadIdsAboveAnchor(
        items: items,
        anchorKey: 'post:deleted',
        candidateIds: {'2', '1'},
      );
      expect(result, {'2', '1'});
    });

    test('candidate が items に存在しない場合は含まれない (アンカー到達で打ち切り)', () {
      final items = <TimelineItem>[_post('3'), _post('2'), _post('1')];
      final result = unreadIdsAboveAnchor(
        items: items,
        anchorKey: 'post:2',
        candidateIds: {'3', 'not_in_list'},
      );
      expect(result, {'3'});
    });

    test('アンカーが index 0 なら空集合', () {
      final items = <TimelineItem>[_post('3'), _post('2'), _post('1')];
      final result = unreadIdsAboveAnchor(
        items: items,
        anchorKey: 'post:3',
        candidateIds: {'2', '1'},
      );
      expect(result, isEmpty);
    });

    test('candidateIds が空なら空集合', () {
      final items = <TimelineItem>[_post('1')];
      final result = unreadIdsAboveAnchor(
        items: items,
        anchorKey: 'post:1',
        candidateIds: const {},
      );
      expect(result, isEmpty);
    });

    test('全 candidate がアンカー前に見つかったら早期終了しても結果は同じ', () {
      final items = <TimelineItem>[
        _post('5'),
        _post('4'),
        _post('3'),
        _post('2'),
        _post('1'),
      ];
      final result = unreadIdsAboveAnchor(
        items: items,
        anchorKey: 'post:1',
        candidateIds: {'5', '4'},
      );
      expect(result, {'5', '4'});
    });
  });
}
