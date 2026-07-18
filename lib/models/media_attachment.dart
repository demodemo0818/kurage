// lib/models/media_attachment.dart

import 'json_utils.dart';

class MediaAttachment {
  final String id;
  final String type;
  final String url;
  final String previewUrl;

  /// 元画像のアスペクト比 (width / height)。
  /// 取得できなかった場合は 1.0 (正方形) にフォールバック。
  /// Mastodon の `meta.original.aspect` または `meta.original.width/height` から算出。
  final double aspectRatio;

  /// ALT 文 (`description`)。投稿編集時の初期値復元やアクセシビリティ表示で使う。
  /// サーバが返さない場合は null。
  final String? description;

  MediaAttachment({
    required this.id,
    required this.type,
    required this.url,
    required this.previewUrl,
    this.aspectRatio = 1.0,
    this.description,
  });

  factory MediaAttachment.fromJson(Map<String, dynamic> json) {
    // url はサーバ側のメディア処理が未完了 (非同期アップロード直後) や
    // リモート未取得時に null になる。remote_url → 空文字の順で倒し、
    // 表示側は空 URL を「読み込めないメディア」として扱う。
    final url =
        (json['url'] as String?) ?? (json['remote_url'] as String?) ?? '';
    return MediaAttachment(
      id: asIdString(json['id']),
      type: json['type'] as String? ?? 'unknown',
      url: url,
      previewUrl: (json['preview_url'] as String?) ?? url,
      aspectRatio: _extractAspectRatio(json),
      description: json['description'] as String?,
    );
  }

  static double _extractAspectRatio(Map<String, dynamic> json) {
    final meta = json['meta'] as Map<String, dynamic>?;
    if (meta == null) return 1.0;
    final original = meta['original'] as Map<String, dynamic>?;
    if (original == null) return 1.0;
    // aspect が直接ある場合 (Mastodon は画像/動画で返してくる)
    final aspect = original['aspect'];
    if (aspect is num) {
      final v = aspect.toDouble();
      if (v.isFinite && v > 0) return v;
    }
    // フォールバック: width / height
    final w = (original['width'] as num?)?.toDouble();
    final h = (original['height'] as num?)?.toDouble();
    if (w != null && h != null && h > 0) {
      final v = w / h;
      if (v.isFinite && v > 0) return v;
    }
    return 1.0;
  }

  /// メディアが動画かどうかを判定 (gifv も含む)
  bool get isVideo => type == 'video' || type == 'gifv';

  /// Mastodon サーバーが GIF を mp4 (gifv) に変換した「ループ再生用の動画」か。
  /// 通常の `video` と区別して、自動再生・ループ・無音・コントロール非表示
  /// で扱うために用いる。
  bool get isGif => type == 'gifv';

  /// メディアが画像かどうかを判定
  bool get isImage => type == 'image';

  /// メディアが音声かどうかを判定
  bool get isAudio => type == 'audio';
}
