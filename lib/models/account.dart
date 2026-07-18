// lib/models/account.dart

import 'emoji.dart';
import 'json_utils.dart';
import 'profile_field.dart';

class Account {
  final String id;
  final String username;
  final String acct; // 完全なユーザーID (@username@domain または username)
  /// リモートプロフィールの正規 URL。リモートアカウントの場合は origin
  /// インスタンスの URL が入る (home インスタンス経由で取得しても origin を
  /// 指す)。「ブラウザで開く」導線で使用。欠落時は空文字。
  final String url;
  final String displayName;
  final String avatarUrl;
  final String headerUrl;
  final String note;
  final List<ProfileField> fields;
  final int followersCount;
  final int followingCount;
  final int statusesCount;
  final DateTime createdAt;
  final bool locked;
  final bool bot;
  final List<Emoji> emojis;

  Account({
    required this.id,
    required this.username,
    required this.acct,
    required this.url,
    required this.displayName,
    required this.avatarUrl,
    required this.headerUrl,
    required this.note,
    required this.fields,
    required this.followersCount,
    required this.followingCount,
    required this.statusesCount,
    required this.createdAt,
    required this.locked,
    required this.bot,
    required this.emojis,
  });

  factory Account.fromJson(Map<String, dynamic> json) {
    final ems = (json['emojis'] as List<dynamic>? ?? [])
        .map((e) => Emoji.fromJson(e as Map<String, dynamic>))
        .toList();

    // Misskey 系は display_name を null で返すことがある。username も
    // 防御的に空文字へ倒す (欠落した username は表示が崩れるだけで済む)。
    final username = json['username'] as String? ?? '';
    final displayName = json['display_name'] as String? ?? '';

    return Account(
      id: asIdString(json['id']),
      username: username,
      acct: json['acct'] as String? ?? username,
      url: json['url'] as String? ?? '',
      displayName: displayName.isNotEmpty ? displayName : username,
      avatarUrl: (json['avatar_static'] as String?)
              ?? (json['avatar'] as String? ?? ''),
      headerUrl: (json['header_static'] as String?)
              ?? (json['header'] as String? ?? ''),
      note: json['note'] as String? ?? '',
      fields: (json['fields'] as List<dynamic>? ?? [])
          .map((f) => ProfileField.fromJson(f as Map<String, dynamic>))
          .toList(),
      followersCount: json['followers_count'] as int? ?? 0,
      followingCount: json['following_count'] as int? ?? 0,
      statusesCount: json['statuses_count'] as int? ?? 0,
      createdAt: parseDateTimeOr(json['created_at']),
      locked: json['locked'] as bool? ?? false,
      bot: json['bot'] as bool? ?? false,
      emojis: ems,
    );
  }

  /// 指定フィールドだけ差し替えた複製を返す。相手サーバーから読み込んだ
  /// アカウント (acct が相手サーバー上のローカル名 = ドメイン無し) に、home
  /// 側のフルハンドル (`user@origin`) を被せて表示する用途で使う。
  Account copyWith({
    String? id,
    String? username,
    String? acct,
    String? url,
    String? displayName,
    String? avatarUrl,
    String? headerUrl,
    String? note,
    List<ProfileField>? fields,
    int? followersCount,
    int? followingCount,
    int? statusesCount,
    DateTime? createdAt,
    bool? locked,
    bool? bot,
    List<Emoji>? emojis,
  }) {
    return Account(
      id: id ?? this.id,
      username: username ?? this.username,
      acct: acct ?? this.acct,
      url: url ?? this.url,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      headerUrl: headerUrl ?? this.headerUrl,
      note: note ?? this.note,
      fields: fields ?? this.fields,
      followersCount: followersCount ?? this.followersCount,
      followingCount: followingCount ?? this.followingCount,
      statusesCount: statusesCount ?? this.statusesCount,
      createdAt: createdAt ?? this.createdAt,
      locked: locked ?? this.locked,
      bot: bot ?? this.bot,
      emojis: emojis ?? this.emojis,
    );
  }

  String get avatarStatic => avatarUrl;
  String get avatar       => avatarUrl;
  String get displayNameOrUsername =>
      displayName.isNotEmpty ? displayName : username;
}
