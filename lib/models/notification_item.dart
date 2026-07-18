// lib/models/notification_item.dart

import 'dart:convert';
import 'account.dart';
import 'json_utils.dart';
import 'status.dart';

/// 通知の種類
enum NotificationType {
  mention,
  reply,
  favourite,
  reblog,
  follow,
  poll,
  reaction,      // emoji_reaction
  followRequest, // follow_request
  status,        // 投稿通知 (SSE の update)
  quote,         // 引用投稿 (Mastodon 4.4+ の `quote` 通知)
  addedToCollection, // added_to_collection (Mastodon 4.6+: コレクションに追加された)
  collectionUpdate,  // collection_update (Mastodon 4.6+: 参加コレクションが更新された)
  unknown,
}

/// 通知アイテムモデル
class NotificationItem {
  final String id;
  final NotificationType type;
  final DateTime createdAt;
  final Account account;
  final Status? status;
  String? sourceAccountId;

  /// added_to_collection / collection_update 通知が参照する Collection の id。
  /// **実機検証ゲート**: docs に正式なフィールド名が無いため、`collection_id` /
  /// 埋め込み `collection.id` の両方を寛容に拾う。実レスポンスで別名なら null の
  /// まま (通知タップはプロフィールにフォールバックする) なので害は無い。
  final String? collectionId;

  /// Mastodon 4.6+ の `fallback` 属性 (supported_types に含めなかったタイプの
  /// 通知に付く最小表現)。Kurage は supported_types を送らない運用なので通常は
  /// null だが、将来の配線に備えてパースだけ通しておく。
  final NotificationFallback? fallback;

  NotificationItem({
    required this.id,
    required this.type,
    required this.createdAt,
    required this.account,
    this.status,
    this.sourceAccountId,
    this.fallback,
    this.collectionId,
  });

  /// API `/notifications` レスポンスから
  factory NotificationItem.fromJson(Map<String, dynamic> json) {
    final raw = json['type'] as String;
    final type = NotificationType.values.firstWhere((e) {
      switch (e) {
        case NotificationType.mention:
          return raw == 'mention';
        case NotificationType.reply:
          return raw == 'reply';
        case NotificationType.favourite:
          return raw == 'favourite';
        case NotificationType.reblog:
          return raw == 'reblog';
        case NotificationType.follow:
          return raw == 'follow';
        case NotificationType.poll:
          return raw == 'poll';
        case NotificationType.reaction:
          return raw == 'emoji_reaction';
        case NotificationType.followRequest:
          return raw == 'follow_request';
        case NotificationType.status:
          return raw == 'status';
        case NotificationType.quote:
          return raw == 'quote';
        case NotificationType.addedToCollection:
          return raw == 'added_to_collection';
        case NotificationType.collectionUpdate:
          return raw == 'collection_update';
        case NotificationType.unknown:
          return false;
      }
    }, orElse: () => NotificationType.unknown);

    return NotificationItem(
      id: asIdString(json['id']),
      type: type,
      createdAt: parseDateTimeOr(json['created_at']),
      account: Account.fromJson(json['account'] as Map<String, dynamic>),
      status: json['status'] != null
          ? Status.fromJson(json['status'] as Map<String, dynamic>)
          : null,
      fallback: json['fallback'] is Map<String, dynamic>
          ? NotificationFallback.fromJson(
              json['fallback'] as Map<String, dynamic>)
          : null,
      collectionId: _parseCollectionId(json),
    );
  }

  /// 通知 JSON から Collection id を寛容に取り出す (実機検証ゲート)。
  /// `collection_id` (status_id 形式) → 埋め込み `collection.id` の順で試す。
  static String? _parseCollectionId(Map<String, dynamic> json) {
    final direct = asIdStringOrNull(json['collection_id']);
    if (direct != null) return direct;
    final embedded = json['collection'];
    if (embedded is Map<String, dynamic>) {
      return asIdStringOrNull(embedded['id']);
    }
    return null;
  }

  /// SSE `update` イベント → 投稿通知
  factory NotificationItem.fromStatus(Status s) {
    return NotificationItem(
      id: s.id,
      type: NotificationType.status,
      createdAt: s.createdAt,
      account: s.account,
      status: s,
    );
  }

  /// JSON 文字列 → `List<NotificationItem>`
  static List<NotificationItem> listFromJson(String body) {
    final data = json.decode(body) as List<dynamic>;
    return data
        .map((e) => NotificationItem.fromJson(e as Map<String, dynamic>))
        .where((n) => n.type != NotificationType.unknown)
        .toList();
  }
}

/// Mastodon 4.6+ の通知 `fallback` 属性。`supported_types` に含めなかった
/// タイプの通知に対し、サーバが「最小限の表現」を返してくる。docs に正式な
/// フィールド一覧が無いため、元 JSON を丸ごと保持しつつ `type` / `account`
/// だけ取り出す寛容パースのラッパーにする (未知フィールドを落とさない)。
class NotificationFallback {
  /// fallback が表す元の通知タイプ文字列 (例: `admin.sign_up`)。
  final String? type;

  /// 関連アカウント (あれば)。
  final Account? account;

  /// 取りこぼし防止のため元 JSON を丸ごと保持しておく。
  final Map<String, dynamic> raw;

  NotificationFallback({this.type, this.account, required this.raw});

  factory NotificationFallback.fromJson(Map<String, dynamic> json) {
    return NotificationFallback(
      type: json['type'] as String?,
      account: json['account'] is Map<String, dynamic>
          ? Account.fromJson(json['account'] as Map<String, dynamic>)
          : null,
      raw: json,
    );
  }
}
