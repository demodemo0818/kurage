// lib/models/timeline_gap.dart

/// 複数アカウント (= ソース) を統合した 1 つのカラム TL におけるギャップを
/// 表現するクラス。
///
/// 設計上のポイント:
/// - **ソースごとに ID 境界を保持する** ([perSource]) ことで、ギャップを埋める
///   フェッチ時に各ソースを独立してページングできる。
/// - フェッチ後に「取り切れなかったソース」だけを残ギャップに残す
///   ([perSource] に entry を残す / 取り切ったソースは削る) ことで、
///   ソース間の取得数の非対称 (A は 200 件残ってる、B は 5 件で完了 等) を
///   素直に扱える。
/// - 配置位置は [anchorNewerStatusId] (= 統合 TL の newest-first 順で「この
///   status の直下にギャップを置く」) を使う。ソース毎の境界とは独立。
class TimelineGap {
  /// 一意キー。dedup / `ValueKey` / `_items.indexWhere` に使う。
  final String id;

  /// 統合 TL における配置アンカー。`_items` (newest-first) でこの status の
  /// 直下にギャップを置く。`_maybeBuildGap` では「ギャップ上にある post」の
  /// id、`_buildBoundaryGaps` では「新着フェッチの最古 = ギャップ上にある
  /// post」の id が入る。
  final String anchorNewerStatusId;

  /// 各ソース (= アカウント id) ごとの境界 + timelineType。`_fillGap` は
  /// このマップを iterate して、ソースごとに `since_id` / `max_id` を渡して
  /// ページングする。exhausted (= 範囲内を完全に取り切った) になったソース
  /// は残ギャップ生成時に map から除外する。
  final Map<String, SourceGapBounds> perSource;

  /// 時間幅の上端 (新しい側)。`isSignificant` / UI 表示用。`perSource` の全
  /// ソースの「newer 側に隣接する既存投稿」の最新日時に相当 (作成時に計算)。
  final DateTime? newerDate;

  /// 時間幅の下端 (古い側)。同上の「older 側に隣接する既存投稿」の最古日時。
  final DateTime? olderDate;

  /// ローディング中フラグ。`GapTile` がスピナー表示に使う。`copyWith` で
  /// `_fillGap` 開始時に true、完了時に新ギャップ (or 削除) に差し替わる。
  final bool isLoading;

  TimelineGap({
    required this.id,
    required this.anchorNewerStatusId,
    required this.perSource,
    this.newerDate,
    this.olderDate,
    this.isLoading = false,
  });

  TimelineGap copyWith({
    String? id,
    String? anchorNewerStatusId,
    Map<String, SourceGapBounds>? perSource,
    DateTime? newerDate,
    DateTime? olderDate,
    bool? isLoading,
  }) {
    return TimelineGap(
      id: id ?? this.id,
      anchorNewerStatusId: anchorNewerStatusId ?? this.anchorNewerStatusId,
      perSource: perSource ?? this.perSource,
      newerDate: newerDate ?? this.newerDate,
      olderDate: olderDate ?? this.olderDate,
      isLoading: isLoading ?? this.isLoading,
    );
  }

  /// ギャップが意味のあるものかチェック（時間差が十分にあるか）。
  /// 5 分未満は dedup ノイズと判断してギャップ生成自体をスキップする。
  bool get isSignificant {
    if (newerDate == null || olderDate == null) return true;
    final timeDiff = newerDate!.difference(olderDate!);
    return timeDiff.inMinutes > 5;
  }

  @override
  String toString() {
    return 'TimelineGap{id: $id, anchor: $anchorNewerStatusId, '
        'sources: ${perSource.keys.join(",")}}';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TimelineGap && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// 1 つのソース (= account + timelineType) におけるギャップ境界。
///
/// fetch 時の `since_id` / `max_id` に直接マップされる:
/// - `since_id = olderStatusId` (これより新しい投稿だけ返す)
/// - `max_id = newerStatusId` (これより古い投稿だけ返す)
///
/// `null` は片側 open。例えば「このソースの最新投稿より新しいギャップ」なら
/// `newerStatusId = null`、`olderStatusId = そのソースの既存の最新 id`。
class SourceGapBounds {
  final String? newerStatusId;
  final String? olderStatusId;
  final String timelineType;

  const SourceGapBounds({
    this.newerStatusId,
    this.olderStatusId,
    required this.timelineType,
  });

  SourceGapBounds copyWith({
    String? newerStatusId,
    String? olderStatusId,
    String? timelineType,
  }) {
    return SourceGapBounds(
      newerStatusId: newerStatusId ?? this.newerStatusId,
      olderStatusId: olderStatusId ?? this.olderStatusId,
      timelineType: timelineType ?? this.timelineType,
    );
  }

  @override
  String toString() =>
      'SourceGapBounds{tlType: $timelineType, newer: $newerStatusId, older: $olderStatusId}';
}
