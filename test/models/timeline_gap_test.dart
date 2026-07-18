// TimelineGap / SourceGapBounds のテスト。
//
// isSignificant は「5 分未満は dedup ノイズとしてギャップ生成をスキップ」の
// 判定 (`> 5` なので 5 分ちょうどは false)。境界をテストで固定する。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/timeline_gap.dart';

TimelineGap _gap({
  String id = 'g1',
  DateTime? newerDate,
  DateTime? olderDate,
  bool isLoading = false,
}) =>
    TimelineGap(
      id: id,
      anchorNewerStatusId: 's100',
      perSource: {
        'acc1': const SourceGapBounds(
          newerStatusId: 's100',
          olderStatusId: 's50',
          timelineType: 'home',
        ),
      },
      newerDate: newerDate,
      olderDate: olderDate,
      isLoading: isLoading,
    );

void main() {
  group('TimelineGap.isSignificant', () {
    final base = DateTime(2026, 1, 15, 12, 0);

    test('newerDate / olderDate のどちらかが null なら true', () {
      expect(_gap(newerDate: base).isSignificant, true);
      expect(_gap(olderDate: base).isSignificant, true);
      expect(_gap().isSignificant, true);
    });

    test('時間差 5 分ちょうどは false (`> 5` の境界)', () {
      final gap = _gap(
        newerDate: base,
        olderDate: base.subtract(const Duration(minutes: 5)),
      );
      expect(gap.isSignificant, false);
    });

    test('時間差 6 分は true', () {
      final gap = _gap(
        newerDate: base,
        olderDate: base.subtract(const Duration(minutes: 6)),
      );
      expect(gap.isSignificant, true);
    });
  });

  group('TimelineGap.copyWith', () {
    test('isLoading だけ差し替え、他フィールドは保持する', () {
      final gap = _gap(newerDate: DateTime(2026, 1, 15));
      final loading = gap.copyWith(isLoading: true);
      expect(loading.isLoading, true);
      expect(loading.id, gap.id);
      expect(loading.anchorNewerStatusId, gap.anchorNewerStatusId);
      expect(loading.perSource, gap.perSource);
      expect(loading.newerDate, gap.newerDate);
    });
  });

  group('TimelineGap == / hashCode', () {
    test('id が同じなら他フィールドが違っても等価 (dedup 用)', () {
      final a = _gap(newerDate: DateTime(2026, 1, 15));
      final b = _gap(isLoading: true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('id が違えば等価でない', () {
      expect(_gap() == _gap(id: 'g2'), false);
    });
  });

  group('SourceGapBounds.copyWith', () {
    test('指定フィールドのみ差し替える', () {
      const bounds = SourceGapBounds(
        newerStatusId: 's100',
        olderStatusId: 's50',
        timelineType: 'home',
      );
      final copied = bounds.copyWith(olderStatusId: 's75');
      expect(copied.olderStatusId, 's75');
      expect(copied.newerStatusId, 's100');
      expect(copied.timelineType, 'home');
    });
  });
}
