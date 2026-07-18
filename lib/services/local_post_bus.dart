// lib/services/local_post_bus.dart
//
// 「自分が投稿した」ことを各タイムラインに知らせるための軽量 broadcast bus。
//
// 受信側 (`ColumnTimelineView`) は accountId が自カラムのソースに含まれて
// いれば `_refresh()` を発火する。`_refresh()` は `since_id` ベースなので、
// SSE が OFF / 切断中でも自分の投稿を含む新着を取り込める。SSE が生きて
// いるケースで SSE 経由でも届くが、`_knownStatusIds` の id 重複排除で
// 二重表示にならない。
//
// 予約投稿は実際にタイムラインに乗るのが未来時刻なので publish しない。
// 編集 (PUT /statuses/:id) も別経路 (現状未対応) のためここでは扱わない。
//
// 設計上、Status オブジェクトを直接流す手もあったが、そうすると
// timeline_view 側で visibility / timelineType の分岐を持たねばならず
// (hashtag/list は client では正しく判定できない)、結局サーバ側真実に
// 任せる `_refresh()` 経由のほうが網羅性も実装量も良い、という判断。

import 'dart:async';

final StreamController<String> _localPostController =
    StreamController<String>.broadcast();

/// 各 `ColumnTimelineView` が `initState` で listen する。引数は
/// 投稿元の `AuthAccount.id`。
Stream<String> get localPostStream => _localPostController.stream;

/// `post_page._submit()` から呼ばれる。即時投稿成功時のみ。
void publishLocalPost({required String accountId}) {
  _localPostController.add(accountId);
}
