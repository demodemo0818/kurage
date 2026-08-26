// lib/models/relationship.dart

class Relationship {
  /// 対象アカウントの ID。一括取得 (`fetchRelationships`) の結果を ID キーの
  /// Map に詰めるために使う。単数取得の経路では使わないので必須にしない。
  final String id;

  final bool following;     // フォロー中か
  final bool followedBy;    // 相手が自分をフォロー中か
  final bool blocking;      // ブロック中か
  final bool muting;        // ミュート中か
  final bool notifications; // 投稿通知購読中か（API のフィールドは "notifying"）

  /// 非公開アカウントへのフォローリクエストを送信して承認待ちか。
  /// この状態では `following` は false のままなので、これを見ないと
  /// 「フォロー」ボタンを押した直後に元に戻ったように見えてしまう。
  final bool requested;

  /// このアカウントに対して自分だけが見える private note (Mastodon 標準機能)。
  /// 未設定の場合は空文字。
  final String note;

  Relationship({
    this.id = '',
    required this.following,
    required this.followedBy,
    required this.blocking,
    required this.muting,
    required this.notifications,
    this.requested = false,
    required this.note,
  });

  Relationship copyWith({String? note}) {
    return Relationship(
      id: id,
      following: following,
      followedBy: followedBy,
      blocking: blocking,
      muting: muting,
      notifications: notifications,
      requested: requested,
      note: note ?? this.note,
    );
  }

  factory Relationship.fromJson(Map<String, dynamic> json) {
    return Relationship(
      id: json['id']?.toString() ?? '',
      following: json['following'] as bool? ?? false,
      followedBy: json['followed_by'] as bool? ?? false,
      blocking: json['blocking'] as bool? ?? false,
      muting: json['muting'] as bool? ?? false,
      notifications: json['notifying'] as bool? ?? false, // "notifying" が正しいキー
      requested: json['requested'] as bool? ?? false,
      note: json['note'] as String? ?? '',
    );
  }
}
