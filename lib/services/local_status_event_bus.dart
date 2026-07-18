// lib/services/local_status_event_bus.dart
//
// 「自分が投稿の編集 / 削除を行った」ことを各タイムライン (TL カラム /
// プロフィール / ハッシュタグ / 検索 / スレッド…) に即時通知するための
// 軽量 broadcast bus。
//
// 設計指針は [local_post_bus.dart] と同じ。違いは:
//
// - 新規投稿は since_id ベースの `_refresh()` で取れるので accountId だけ
//   流せば良いが、編集 / 削除はサーバ取得では拾えない (= 削除済みは API が
//   404 を返し、編集後は同じ id を再取得しないと最新が来ない)。なので
//   こちらは status 単位の event を流し、受信側が `_items` / `_statuses` /
//   `_posts` 等の **ローカルキャッシュを直接書き換える** 方式にする。
// - イベントは sealed class で `LocalStatusDeleted` / `LocalStatusEdited`
//   の 2 種。今後 reblog 状態の変化など他の即時反映が必要になれば追加。
//
// 「PostTile から各画面に直接 callback を生やす」案も検討したが、PostTile
// は timeline_view / profile / hashtag / search / thread / dm / 通知 と 7
// 箇所以上から使われるため、prop drilling が肥大化する。bus に集約する方が
// 既存 [local_post_bus.dart] のパターンとも揃って自然。

import 'dart:async';

import '../models/status.dart';

/// 自分の操作によるローカル status 変更イベント。
sealed class LocalStatusEvent {
  /// 操作元アカウントの id (= `AuthAccount.id`)。
  /// 各画面は自分が表示している status の `accountId` と一致するものだけを
  /// 処理する (別アカウントの TL に乗っている同等 status はインスタンスが
  /// 異なれば別 id なので、ここで弾いて問題ない)。
  final String accountId;

  /// 対象 status の id。
  final String statusId;

  const LocalStatusEvent({required this.accountId, required this.statusId});
}

/// 削除イベント。受信側は `_items` 等から `(accountId, statusId)` 一致の
/// PostItem を `removeWhere` で取り除く。
class LocalStatusDeleted extends LocalStatusEvent {
  const LocalStatusDeleted({required super.accountId, required super.statusId});
}

/// 編集イベント。`updated` が編集後の Status。
/// 受信側は `(accountId, status.id)` 一致のエントリを差し替える。
class LocalStatusEdited extends LocalStatusEvent {
  final Status updated;
  LocalStatusEdited({required super.accountId, required this.updated})
      : super(statusId: updated.id);
}

final StreamController<LocalStatusEvent> _controller =
    StreamController<LocalStatusEvent>.broadcast();

/// 各画面が `initState` で listen する。
Stream<LocalStatusEvent> get localStatusEventStream => _controller.stream;

/// 削除成功時に呼ぶ (`PostTile._deletePost` / `_deleteAndRedraft`)。
void publishLocalStatusDeleted({
  required String accountId,
  required String statusId,
}) {
  _controller.add(
    LocalStatusDeleted(accountId: accountId, statusId: statusId),
  );
}

/// 編集成功時に呼ぶ (`PostTile._editPost` が PostPage の戻り値を受けて)。
void publishLocalStatusEdited({
  required String accountId,
  required Status updated,
}) {
  _controller.add(
    LocalStatusEdited(accountId: accountId, updated: updated),
  );
}
