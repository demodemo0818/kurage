// lib/models/media_attachment.dart

import 'json_utils.dart';

class MediaAttachment {
  final String id;
  final String type;
  final String url;
  final String previewUrl;

  /// 連合元の元ファイル URL (`remote_url`)。ローカル投稿やサーバが返さない
  /// 場合は null。gifv の場合、サーバ側で mp4 に変換される前の元 GIF を
  /// 指していることがあり、動画再生できないプラットフォームのフォール
  /// バックに使う ([animatedRemoteOriginalUrl])。
  final String? remoteUrl;

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
    this.remoteUrl,
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
      remoteUrl: json['remote_url'] as String?,
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

  /// type は video/gifv だが実ファイルがアニメーション画像のままのケース。
  /// Misskey 等は GIF を mp4 に変換せず type だけ gifv で返す (URL は .gif の
  /// まま)。GIF は動画コーデックではないため動画プレイヤーでは再生できず
  /// (ExoPlayer / Media Foundation とも非対応)、表示側はこれが true なら
  /// 画像デコーダ (GIF/APNG/WebP アニメ対応) で再生する。
  bool get isAnimatedImageFile => isVideo && _hasAnimatedImagePath(url);

  /// gifv がサーバ側で mp4 変換済みでも、連合元の元ファイル (`remote_url`) が
  /// アニメーション画像 (.gif 等) ならその URL を返す。video_player 実装が
  /// 無い Linux で、mp4 の代わりに元 GIF を画像デコーダで再生するための
  /// フォールバック (Windows は video_player_win で動画再生できる)。
  /// 該当しなければ null。
  String? get animatedRemoteOriginalUrl {
    final remote = remoteUrl;
    if (!isVideo || remote == null) return null;
    return _hasAnimatedImagePath(remote) ? remote : null;
  }

  /// URL の path 部分がアニメーション画像の拡張子か (クエリ付き URL も path で
  /// 判定する)。
  static bool _hasAnimatedImagePath(String url) {
    final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
    return path.endsWith('.gif') ||
        path.endsWith('.apng') ||
        path.endsWith('.webp');
  }

  /// メディアが画像かどうかを判定
  bool get isImage => type == 'image';

  /// メディアが音声かどうかを判定
  bool get isAudio => type == 'audio';
}
