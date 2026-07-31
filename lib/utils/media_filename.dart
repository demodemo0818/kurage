// lib/utils/media_filename.dart
//
// 保存するメディアのファイル名 (拡張子) を決める純粋ロジック。
// 拡張子を .jpg 決め打ちにしていたため動画が JPG として保存されていた
// (Issue #5) 回帰を防ぐため、ここに切り出して unit test を付けている。

/// Content-Type の MIME から拡張子を導出する。
/// サブタイプがそのまま拡張子にならないもの (image/jpeg, video/quicktime 等)
/// だけ明示マッピングし、残りはサブタイプをそのまま使う。
String extensionFromMime(String mime) {
  final m = mime.split(';').first.trim().toLowerCase();
  const overrides = <String, String>{
    'image/jpeg': 'jpg',
    'image/svg+xml': 'svg',
    'video/quicktime': 'mov',
    'video/x-matroska': 'mkv',
    'video/x-msvideo': 'avi',
    'audio/mpeg': 'mp3',
    'audio/mp4': 'm4a',
    'audio/x-m4a': 'm4a',
    'audio/wav': 'wav',
    'audio/x-wav': 'wav',
    'audio/vnd.wave': 'wav',
  };
  final mapped = overrides[m];
  if (mapped != null) return mapped;
  final sub = m.split('/').last;
  if (sub.isEmpty) return 'jpg';
  return sub;
}

/// 保存ファイル名に使う拡張子を決める。
///
/// Content-Type が image/video/audio なら MIME を信用し、
/// application/octet-stream 等の汎用 MIME や欠落時は URL の path 末尾に倒す。
/// どちらからも取れなければ従来どおり jpg。
String resolveMediaExtension(String url, String? contentType) {
  final mime = (contentType ?? '').split(';').first.trim().toLowerCase();
  if (mime.startsWith('image/') ||
      mime.startsWith('video/') ||
      mime.startsWith('audio/')) {
    return extensionFromMime(mime);
  }
  final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
  final dot = path.lastIndexOf('.');
  if (dot != -1 && dot < path.length - 1) {
    final ext = path.substring(dot + 1);
    if (RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext)) return ext;
  }
  return 'jpg';
}
