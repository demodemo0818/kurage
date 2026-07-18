// lib/models/profile.dart
//
// Mastodon 4.6+ の `GET/PATCH /api/v1/profile` が返す Profile エンティティ。
//
// **Account とは別モデルにしている。** 理由:
//  - `Profile.note` / `fields[].value` は *raw text* (編集フォームに入れる元の
//    テキスト)。一方 `Account.note` / `fields[].value` は *HTML* (表示用)。同じ
//    フィールド名で意味が違うものを 1 クラスに同居させると、表示側が raw を
//    HTML 描画する (またはその逆の) 事故を招く。
//  - `show_media` / `avatar_description` 等は「自分のプロフィール編集」専用で、
//    他人の Account には付かない。Account に混ぜると常に無意味な null を持つ。
//
// docs に正式なフィールド一覧があるものはそれに従い、欠落耐性のため
// json_utils 流の防御的パースを通す。

import 'json_utils.dart';

/// Profile の `fields[]` 要素 (raw text 版)。`ProfileField` (HTML 版) と
/// 区別するため別クラスにしている。name / value はサーバ側エスケープ前の
/// 生テキストで、そのまま編集フォームに入れられる。
class ProfileFieldRaw {
  final String name;
  final String value;

  /// rel="me" 検証 OK のタイムスタンプ。null = 未認証。
  final DateTime? verifiedAt;

  const ProfileFieldRaw({
    required this.name,
    required this.value,
    this.verifiedAt,
  });

  bool get isVerified => verifiedAt != null;

  factory ProfileFieldRaw.fromJson(Map<String, dynamic> json) {
    return ProfileFieldRaw(
      name: (json['name'] as String?) ?? '',
      value: (json['value'] as String?) ?? '',
      verifiedAt: tryParseDateTime(json['verified_at']),
    );
  }
}

class Profile {
  final String id;

  /// 表示名 (raw)。
  final String displayName;

  /// 自己紹介 (raw text。HTML ではない)。
  final String note;

  /// プロフィール補足フィールド (raw)。
  final List<ProfileFieldRaw> fields;

  final String avatar;
  final String avatarStatic;

  /// アバターの代替テキスト (視覚障碍者向け)。未設定なら null。
  final String? avatarDescription;

  final String header;
  final String headerStatic;

  /// ヘッダーの代替テキスト。未設定なら null。
  final String? headerDescription;

  final bool locked;
  final bool bot;

  /// フォロー/フォロワーを隠す。docs 上 nullable。
  final bool? hideCollections;

  /// ディレクトリ等での発見を許可。docs 上 nullable。
  final bool? discoverable;

  /// 検索エンジンによるインデックスを許可。
  final bool indexable;

  /// プロフィールの「メディア」タブ表示。
  final bool showMedia;

  /// メディアタブに返信を含める。
  final bool showMediaReplies;

  /// 「ピックアップ (featured)」タブ表示。
  final bool showFeatured;

  /// 著者クレジットを許可するドメイン群 (attribution_domains)。
  final List<String> attributionDomains;

  const Profile({
    required this.id,
    this.displayName = '',
    this.note = '',
    this.fields = const [],
    this.avatar = '',
    this.avatarStatic = '',
    this.avatarDescription,
    this.header = '',
    this.headerStatic = '',
    this.headerDescription,
    this.locked = false,
    this.bot = false,
    this.hideCollections,
    this.discoverable,
    this.indexable = false,
    this.showMedia = false,
    this.showMediaReplies = false,
    this.showFeatured = false,
    this.attributionDomains = const [],
  });

  factory Profile.fromJson(Map<String, dynamic> json) {
    final rawFields = (json['fields'] as List<dynamic>?) ?? const [];
    final rawDomains = (json['attribution_domains'] as List<dynamic>?) ?? const [];
    return Profile(
      id: asIdString(json['id']),
      displayName: (json['display_name'] as String?) ?? '',
      note: (json['note'] as String?) ?? '',
      fields: rawFields
          .whereType<Map<String, dynamic>>()
          .map(ProfileFieldRaw.fromJson)
          .toList(),
      avatar: (json['avatar'] as String?) ?? '',
      avatarStatic: (json['avatar_static'] as String?) ?? '',
      avatarDescription: json['avatar_description'] as String?,
      header: (json['header'] as String?) ?? '',
      headerStatic: (json['header_static'] as String?) ?? '',
      headerDescription: json['header_description'] as String?,
      locked: (json['locked'] as bool?) ?? false,
      bot: (json['bot'] as bool?) ?? false,
      hideCollections: json['hide_collections'] as bool?,
      discoverable: json['discoverable'] as bool?,
      indexable: (json['indexable'] as bool?) ?? false,
      showMedia: (json['show_media'] as bool?) ?? false,
      showMediaReplies: (json['show_media_replies'] as bool?) ?? false,
      showFeatured: (json['show_featured'] as bool?) ?? false,
      attributionDomains:
          rawDomains.whereType<String>().toList(),
    );
  }
}
