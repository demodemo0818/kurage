// lib/models/preview_card.dart

/// Mastodon の `status.card` フィールド (OGP プレビュー)。
///
/// サーバ側で OGP を取得済みなのでクライアントから再フェッチ不要。
/// 最初から幅・高さ込みでレイアウトできるためタイムラインのカクつきを抑えられる。
class PreviewCard {
  final String url;
  final String title;
  final String description;
  final String? image; // OGP 画像 URL (なし or 空の場合あり)
  final int width; // 元画像のピクセル幅 (0 の場合あり)
  final int height; // 元画像のピクセル高さ
  final String type; // link | photo | video | rich

  /// Mastodon 4.6+: リンク先のドメインが投稿者の `attribution_domains` に
  /// 含まれず、帰属 (著者クレジット) が一致しないことを示す。なりすまし
  /// プレビュー対策の表示判断に使う。古いサーバでは欠落するので既定 false。
  final bool missingAttribution;

  PreviewCard({
    required this.url,
    required this.title,
    required this.description,
    this.image,
    this.width = 0,
    this.height = 0,
    this.type = 'link',
    this.missingAttribution = false,
  });

  factory PreviewCard.fromJson(Map<String, dynamic> json) {
    return PreviewCard(
      url: (json['url'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      image: json['image'] as String?,
      width: (json['width'] as int?) ?? 0,
      height: (json['height'] as int?) ?? 0,
      type: (json['type'] as String?) ?? 'link',
      missingAttribution: (json['missing_attribution'] as bool?) ?? false,
    );
  }

  bool get hasImage => image != null && image!.isNotEmpty;
}
