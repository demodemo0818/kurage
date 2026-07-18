// lib/models/announcement.dart

import 'dart:convert';
import 'emoji.dart';

/// Mastodon サーバ管理者からのお知らせ (`/api/v1/announcements`)。
///
/// マルチアカウントでマージ表示するため、Provider 側で
/// [sourceAccountId] を埋めてどのアカウント (= どのインスタンス) のお知らせ
/// なのかを保持する。
class Announcement {
  final String id;
  final String content; // HTML
  final DateTime? startsAt;
  final DateTime? endsAt;
  final DateTime publishedAt;
  final DateTime updatedAt;
  final bool read;
  final List<Emoji> emojis;
  final List<AnnouncementReaction> reactions;

  /// Provider 側で「どのアカウント (instance) のお知らせか」をセットする。
  /// 同じ id のお知らせが別インスタンスに存在する可能性もあるので、
  /// 一覧表示の dedupe は `(sourceAccountId, id)` 複合キーで行う。
  String? sourceAccountId;

  Announcement({
    required this.id,
    required this.content,
    required this.startsAt,
    required this.endsAt,
    required this.publishedAt,
    required this.updatedAt,
    required this.read,
    required this.emojis,
    required this.reactions,
    this.sourceAccountId,
  });

  factory Announcement.fromJson(Map<String, dynamic> json) {
    return Announcement(
      id: json['id'].toString(),
      content: json['content'] as String? ?? '',
      startsAt: _parseDateTime(json['starts_at']),
      endsAt: _parseDateTime(json['ends_at']),
      // published_at / updated_at は v4 で必須。古いサーバ互換で created_at
      // にフォールバック (published_at が無い場合)。
      publishedAt: _parseDateTime(json['published_at']) ??
          _parseDateTime(json['updated_at']) ??
          DateTime.now(),
      updatedAt: _parseDateTime(json['updated_at']) ??
          _parseDateTime(json['published_at']) ??
          DateTime.now(),
      read: json['read'] as bool? ?? false,
      emojis: (json['emojis'] as List<dynamic>? ?? [])
          .map((e) => Emoji.fromJson(e as Map<String, dynamic>))
          .toList(),
      reactions: (json['reactions'] as List<dynamic>? ?? [])
          .map((e) =>
              AnnouncementReaction.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  static DateTime? _parseDateTime(dynamic v) {
    if (v == null) return null;
    if (v is String && v.isNotEmpty) {
      try {
        return DateTime.parse(v);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// レスポンス JSON 文字列 → `List<Announcement>`
  static List<Announcement> listFromJson(String body) {
    final data = json.decode(body) as List<dynamic>;
    return data
        .map((e) => Announcement.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

/// お知らせに付けられたリアクション。`me: true` なら自分が付けている。
/// カスタム絵文字なら `url` / `staticUrl` が入る。Unicode 絵文字なら null。
class AnnouncementReaction {
  final String name;
  final int count;
  final bool me;
  final String? url;
  final String? staticUrl;

  AnnouncementReaction({
    required this.name,
    required this.count,
    required this.me,
    this.url,
    this.staticUrl,
  });

  factory AnnouncementReaction.fromJson(Map<String, dynamic> json) {
    return AnnouncementReaction(
      name: json['name'] as String,
      count: (json['count'] as num?)?.toInt() ?? 0,
      me: json['me'] as bool? ?? false,
      url: json['url'] as String?,
      staticUrl: json['static_url'] as String?,
    );
  }
}
