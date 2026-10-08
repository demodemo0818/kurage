// lib/utils/timeline_item_ops.dart
//
// ColumnTimelineView の `_items` 再構築まわりの純粋ロジックを切り出したもの。
// widget / プラグインに依存しないので `flutter test` で直接テストできる
// (test/utils/timeline_item_ops_test.dart)。

import '../models/timeline_item.dart';

/// 投稿のみのリスト `rebuilt` に対し、ギャップを各 `anchorNewerStatusId`
/// (= ギャップの直上にあるべき投稿) の直下へ挿入して返す。
///
/// - `newGaps`: 今回検出した境界ギャップ
/// - `preservedGaps`: 既にタイムラインに存在していた、削らずに維持したい
///   ギャップ (両者で id が重なる場合は newGaps を優先)
/// - アンカー投稿が `rebuilt` に居ない場合は silent drop
///   (境界投稿が削除された等の極端なケース。ギャップ情報の片側が壊れて
///   いるので維持しない)
/// - 同一 id のギャップは最初の 1 つだけ挿入する (重複挿入防御)
///
/// `rebuilt` を直接変更して返す (呼び出し側が使い捨てのリストを渡す前提)。
List<TimelineItem> insertGapsByAnchor(
  List<TimelineItem> rebuilt,
  List<GapItem> newGaps,
  List<GapItem> preservedGaps,
) {
  final seenGapIds = <String>{};

  void insertGap(GapItem gapItem) {
    if (!seenGapIds.add(gapItem.gap.id)) return;
    final anchorId = gapItem.gap.anchorNewerStatusId;
    final idx = rebuilt.indexWhere(
      (it) => it is PostItem && it.status.id == anchorId,
    );
    if (idx >= 0) {
      rebuilt.insert(idx + 1, gapItem);
    }
  }

  for (final g in newGaps) {
    insertGap(g);
  }
  for (final g in preservedGaps) {
    insertGap(g);
  }
  return rebuilt;
}

/// `candidateIds` のうち、`items` 上で「アンカーより上 (= index が小さい)」に
/// 位置する投稿 id だけを返す。未読バッジの「未読 = 現在の視点より上にある
/// 新着」セマンティクス用。
///
/// ソート再構築で新着がアンカーより**下**に interleave された場合 (複数
/// アカウント統合カラムで遅れていたソースの取得分や、連合遅延の SSE 投稿)、
/// それらを未読に積むと上スクロールで通過せず可視判定で消えないため、
/// バッジ件数が実際と合わなくなる。アンカー上だけ数えることで防ぐ。
///
/// - `anchorKey` は `_captureScrollAnchor` が返す `'post:<id>'` / `'gap:<id>'`
///   形式 (更新前に画面上端付近に見えていたアイテム)。
/// - `anchorKey` が null (位置情報なし) または `items` に見つからない場合は
///   `candidateIds` 全体を返す (従来挙動への保守的フォールバック。直後の
///   orphan prune と最上部到達時の自己修復に任せる)。
Set<String> unreadIdsAboveAnchor({
  required List<TimelineItem> items,
  required String? anchorKey,
  required Set<String> candidateIds,
}) {
  if (candidateIds.isEmpty) return const {};
  if (anchorKey == null) return candidateIds;

  final above = <String>{};
  for (final item in items) {
    final key = switch (item) {
      PostItem(:final status) => 'post:${status.id}',
      GapItem(:final gap) => 'gap:${gap.id}',
      _ => null,
    };
    if (key == anchorKey) return above; // アンカー到達 = ここから下は対象外
    if (item is PostItem && candidateIds.contains(item.status.id)) {
      above.add(item.status.id);
      if (above.length == candidateIds.length) return above; // 全件発見済み
    }
  }
  // アンカーがリストから消えていた: 位置が定まらないので全件追加に
  // フォールバック (上の走査結果は「アンカー不在」では使えない)。
  return candidateIds;
}

/// タイムライン分割 (上 = ライブ / 下 = 履歴ペイン) を「ライブペインを閉じて
/// 履歴ペインを残す」形で解除するとき、ライブ側と履歴側の item を 1 本に
/// 統合する。統合後のリストで履歴ペインのアンカーを復元するため、両者の
/// 投稿の和集合を持つ必要がある (履歴側は分割後に下方向へ追加読み込み
/// しているので、ライブ側に無い古い投稿を持ちうる)。
///
/// - 投稿は id で重複排除 (ライブ側の PostItem を優先)。`sortByTime` なら
///   `createdAt` 降順に並べ直す (同時刻は元の並び順を保つ安定ソート)
/// - ギャップ: 履歴側のギャップは全て維持。ライブ側のギャップは「履歴側も
///   同じギャップを持つ」か「アンカー投稿が履歴側に無い (= 分割後に
///   ライブ側だけで生まれた)」場合だけ維持する。アンカー投稿が履歴側に
///   あるのにギャップが無いのは履歴ペインで補完済みということなので、
///   残すと埋まった区間にギャップボタンが復活してしまう
List<TimelineItem> mergeSplitHistory({
  required List<TimelineItem> live,
  required List<TimelineItem> history,
  required bool sortByTime,
}) {
  final seen = <String>{};
  final posts = <PostItem>[];
  for (final it in [...live, ...history]) {
    if (it is PostItem && seen.add(it.status.id)) posts.add(it);
  }
  if (sortByTime) {
    final order = {for (var i = 0; i < posts.length; i++) posts[i]: i};
    posts.sort((a, b) {
      final c = b.createdAt.compareTo(a.createdAt);
      return c != 0 ? c : order[a]!.compareTo(order[b]!);
    });
  }

  final historyPostIds = {
    for (final it in history)
      if (it is PostItem) it.status.id,
  };
  final historyGaps = history.whereType<GapItem>().toList();
  final historyGapIds = {for (final g in historyGaps) g.gap.id};
  final gaps = [
    for (final g in live.whereType<GapItem>())
      if (historyGapIds.contains(g.gap.id) ||
          !historyPostIds.contains(g.gap.anchorNewerStatusId))
        g,
    ...historyGaps,
  ];
  return insertGapsByAnchor(<TimelineItem>[...posts], const [], gaps);
}

/// status id 同士を比較して古い方 (= 小さい方) を返す。Mastodon の id は
/// 桁数が揃わない数値文字列、Pleroma 系は固定長の flake id なので、
/// 「桁数 → 辞書順」で比べれば両方で時系列順になる。
String olderStatusId(String a, String b) {
  if (a.length != b.length) return a.length < b.length ? a : b;
  return a.compareTo(b) <= 0 ? a : b;
}

/// ソースごとの `max_id` (追加読み込みの起点) を統合する。両方にあるキーは
/// より古い方を採る (= より遠くまで読み込んだ側から続きを取得する)。
Map<String, String> mergeOlderMaxIds(
  Map<String, String> a,
  Map<String, String> b,
) {
  final result = Map<String, String>.of(a);
  b.forEach((key, id) {
    final cur = result[key];
    result[key] = cur == null ? id : olderStatusId(cur, id);
  });
  return result;
}
