// lib/models/profile_field.dart
//
// Mastodon の Account の `fields` 配列の各要素を表すモデル。
// プロフィール補足情報 (Web サイト / X / GitHub …) と、その認証情報
// (`verified_at` = サーバが rel="me" 検証して成功した時刻) を保持する。
//
// 旧実装は `Map<String, String>` で name / value だけ持っていたが、
// Mastodon の `verified_at` フィールドを落としていたので「認証済み」
// バッジが UI で出せなかった。

class ProfileField {
  /// 表示名 (例: "Website")
  final String name;

  /// 値 (HTML を含む)。<a href="..."> でリンクを返してくることがある。
  final String value;

  /// rel="me" 検証で OK だったときの ISO タイムスタンプ。null = 未認証。
  /// 値そのものは UI で使わず、null 判定だけ参照すればよい。
  final DateTime? verifiedAt;

  const ProfileField({
    required this.name,
    required this.value,
    this.verifiedAt,
  });

  /// 認証済みフィールドか。UI でチェックマーク + 緑系を出すかの分岐に使う。
  bool get isVerified => verifiedAt != null;

  factory ProfileField.fromJson(Map<String, dynamic> json) {
    return ProfileField(
      name: (json['name'] as String?) ?? '',
      value: (json['value'] as String?) ?? '',
      verifiedAt: json['verified_at'] != null
          ? DateTime.tryParse(json['verified_at'] as String)
          : null,
    );
  }
}
