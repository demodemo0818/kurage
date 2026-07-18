// lib/models/collection.dart
//
// Mastodon 4.6+ の Collection エンティティ (公開キュレーション・アカウント
// リスト)。`/api/v1/collections` 系が返す。entity が members (items) を
// 自己内包し、Notification v2 のような accounts[]/statuses[] 参照分離が無いので、
// Status / Account と同じ素直な fromJson にしている (レスポンスラッパー不要)。

import 'json_utils.dart';

/// Collection に紐づくハッシュタグ (topic)。
class CollectionTag {
  final String name;
  final String url;

  const CollectionTag({required this.name, required this.url});

  factory CollectionTag.fromJson(Map<String, dynamic> json) {
    return CollectionTag(
      name: (json['name'] as String?) ?? '',
      url: (json['url'] as String?) ?? '',
    );
  }
}

/// Collection に含まれる 1 アカウント (メンバー)。
class CollectionItem {
  final String id;
  final String accountId;

  /// "accepted" (本人が承認 or 不要) | "pending" (本人の承認待ち)。
  /// enum 化せず String のまま保持 (将来値が増えても落とさない)。
  final String state;

  final DateTime createdAt;

  const CollectionItem({
    required this.id,
    required this.accountId,
    required this.state,
    required this.createdAt,
  });

  /// 本人の承認待ちか。UI で「承認待ち」バッジを出すかの分岐に使う。
  bool get isPending => state == 'pending';

  factory CollectionItem.fromJson(Map<String, dynamic> json) {
    return CollectionItem(
      id: asIdString(json['id']),
      accountId: asIdString(json['account_id']),
      state: (json['state'] as String?) ?? 'accepted',
      createdAt: parseDateTimeOr(json['created_at']),
    );
  }
}

class Collection {
  final String id;
  final String accountId;
  final String uri;
  final String url;
  final String name;
  final String description;
  final String language;
  final bool local;
  final bool sensitive;
  final bool discoverable;

  /// 関連ハッシュタグ (topic)。未設定なら null。
  final CollectionTag? tag;

  final int itemCount;

  /// メンバー一覧。一覧取得系では空のことがある (詳細取得で埋まる)。
  final List<CollectionItem> items;

  final DateTime createdAt;
  final DateTime updatedAt;

  const Collection({
    required this.id,
    required this.accountId,
    this.uri = '',
    this.url = '',
    this.name = '',
    this.description = '',
    this.language = '',
    this.local = false,
    this.sensitive = false,
    this.discoverable = false,
    this.tag,
    this.itemCount = 0,
    this.items = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  factory Collection.fromJson(Map<String, dynamic> json) {
    final rawItems = (json['items'] as List<dynamic>?) ?? const [];
    final createdAt = parseDateTimeOr(json['created_at']);
    return Collection(
      id: asIdString(json['id']),
      accountId: asIdString(json['account_id']),
      uri: (json['uri'] as String?) ?? '',
      url: (json['url'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      language: (json['language'] as String?) ?? '',
      local: (json['local'] as bool?) ?? false,
      sensitive: (json['sensitive'] as bool?) ?? false,
      discoverable: (json['discoverable'] as bool?) ?? false,
      tag: json['tag'] is Map<String, dynamic>
          ? CollectionTag.fromJson(json['tag'] as Map<String, dynamic>)
          : null,
      itemCount: (json['item_count'] as int?) ?? rawItems.length,
      items: rawItems
          .whereType<Map<String, dynamic>>()
          .map(CollectionItem.fromJson)
          .toList(),
      createdAt: createdAt,
      // updated_at 欠落時は created_at に倒す。
      updatedAt: parseDateTimeOr(json['updated_at'], createdAt),
    );
  }

  /// JSON 文字列 (配列) → `List<Collection>`。
  /// `/accounts/:id/collections` 等の一覧レスポンス用。
  static List<Collection> listFromJson(List<dynamic> data) {
    return data
        .whereType<Map<String, dynamic>>()
        .map(Collection.fromJson)
        .toList();
  }
}
