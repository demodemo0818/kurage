// lib/models/emoji.dart

/// カスタム絵文字モデル
class Emoji {
  /// 例: "party_parrot"
  final String shortcode;

  /// 絵文字画像の URL（アニメーション）
  final String url;

  /// 静止画像の URL（アニメーションしない）
  final String? staticUrl;

  /// 絵文字が表示されるドメイン
  final List<String>? visibleInPicker;

  /// Mastodon サーバー側のカテゴリ名 (任意)。null の場合は未分類。
  final String? category;

  Emoji({
    required this.shortcode,
    required this.url,
    this.staticUrl,
    this.visibleInPicker,
    this.category,
  });

  /// アニメーション対応の URL を取得（デフォルトではアニメーション版を使用）
  String get animatedUrl => url;

  /// 静止画版の URL を取得
  String get nonAnimatedUrl => staticUrl ?? url;

  /// この絵文字がアニメーションかどうか
  bool get isAnimated => url.toLowerCase().endsWith('.gif') || 
                        (staticUrl != null && url != staticUrl);

  factory Emoji.fromJson(Map<String, dynamic> json) => Emoji(
        shortcode: json['shortcode'] as String,
        // アニメーション用のURLを優先的に使用
        url: json['url'] as String,
        staticUrl: json['static_url'] as String?,
        visibleInPicker: json['visible_in_picker'] == true ? [] : null,
        category: (json['category'] as String?)?.trim().isEmpty ?? true
            ? null
            : json['category'] as String?,
      );
}
