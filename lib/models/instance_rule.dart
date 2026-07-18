// lib/models/instance_rule.dart
//
// サーバルール (`/api/v1/instance` の `rules` 配列の各要素 / もしくは
// `/api/v1/instance/rules` の各要素)。通報フォームで「どのルールに違反
// したか」を選ぶときに表示する。
//
// 古い Mastodon (3.4 未満) や派生実装で rules がまったく無い場合は空配列
// 扱いで、通報フォームのルール選択セクションは非表示にする。

class InstanceRule {
  final String id;
  final String text;

  /// 4.x で追加された詳細説明 (任意)。null/空のサーバが多い。
  final String? hint;

  InstanceRule({
    required this.id,
    required this.text,
    this.hint,
  });

  factory InstanceRule.fromJson(Map<String, dynamic> json) {
    return InstanceRule(
      id: json['id'].toString(),
      text: (json['text'] as String?) ?? '',
      hint: json['hint'] as String?,
    );
  }
}
