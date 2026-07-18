// lib/models/relationship.dart

class Relationship {
  final bool following;     // フォロー中か
  final bool followedBy;    // 相手が自分をフォロー中か
  final bool blocking;      // ブロック中か
  final bool muting;        // ミュート中か
  final bool notifications; // 投稿通知購読中か（API のフィールドは "notifying"）

  /// このアカウントに対して自分だけが見える private note (Mastodon 標準機能)。
  /// 未設定の場合は空文字。
  final String note;

  Relationship({
    required this.following,
    required this.followedBy,
    required this.blocking,
    required this.muting,
    required this.notifications,
    required this.note,
  });

  Relationship copyWith({String? note}) {
    return Relationship(
      following: following,
      followedBy: followedBy,
      blocking: blocking,
      muting: muting,
      notifications: notifications,
      note: note ?? this.note,
    );
  }

  factory Relationship.fromJson(Map<String, dynamic> json) {
    return Relationship(
      following: json['following'] as bool? ?? false,
      followedBy: json['followed_by'] as bool? ?? false,
      blocking: json['blocking'] as bool? ?? false,
      muting: json['muting'] as bool? ?? false,
      notifications: json['notifying'] as bool? ?? false, // "notifying" が正しいキー
      note: json['note'] as String? ?? '',
    );
  }
}
