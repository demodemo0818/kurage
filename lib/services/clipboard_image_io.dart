// lib/services/clipboard_image_io.dart
//
// Desktop (Windows/macOS/Linux) のクリップボード画像取得 (pull 型)。
// 呼び出し側 (post_page) の Ctrl/Cmd+V キーハンドラやメニュー契機で
// `Pasteboard.image` を読む。
//
// このファイルは条件付き import の `if (dart.library.io)` 側でのみ読み込まれる
// ため、Web バンドルには入らない (= Web で dart:io / pasteboard を踏まない)。

import 'dart:io' show File, Platform;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pasteboard/pasteboard.dart';

import 'clipboard_image.dart' show ClipboardImage;

bool get clipboardPullSupported =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

Future<List<ClipboardImage>> readClipboardImages() async {
  if (!clipboardPullSupported) return const [];
  try {
    // 1) ビットマップ画像 (Windows = CF_DIB / macOS・Linux = NSPasteboard 画像)。
    //    スクリーンショットやブラウザ等の「画像をコピー」はここで取れる。
    final Uint8List? raw = await Pasteboard.image; // 画像なしなら null
    if (raw != null && raw.isNotEmpty) {
      final img = await _clipboardImageFromBytes(raw);
      if (img != null) return [img];
    }

    // 2) ファイル (Windows = CF_HDROP)。エクスプローラ / Finder で画像ファイルを
    //    「コピー」した場合はビットマップ形式がクリップボードに乗らず (1) が
    //    null になるため、ファイルパス経由で画像を拾う。これが無いと「画像
    //    ファイルをコピーして貼り付け」が無反応になる (= Windows で貼り付け
    //    できないという報告の主因。スクショ派の環境では (1) で取れるので
    //    再現しない)。
    final List<String> files = await Pasteboard.files();
    if (files.isNotEmpty) {
      final out = <ClipboardImage>[];
      for (final path in files) {
        if (!_looksLikeImagePath(path)) continue;
        try {
          final bytes = await File(path).readAsBytes();
          final img = await _clipboardImageFromBytes(bytes, sourcePath: path);
          if (img != null) out.add(img);
        } catch (_) {
          // 読めない / 消えたファイルはスキップ
        }
      }
      if (out.isNotEmpty) return out;
    }

    return const [];
  } catch (_) {
    // クリップボードアクセス失敗 (temp ファイルの権限・ロック等) は握りつぶして
    // 空扱いにする。呼び出し側がメニュー経由なら「画像がありません」を出す。
    return const [];
  }
}

/// 生バイト列 1 枚分を Mastodon が受け付ける [ClipboardImage] に整える。
/// Mastodon は BMP を受け付けない (png/jpeg/gif/webp/heic のみ) ので、解釈
/// できないフォーマット (Windows クリップボードの BMP や未知) は dart:ui で
/// PNG に変換する。デコード不能なら null。
Future<ClipboardImage?> _clipboardImageFromBytes(
  Uint8List raw, {
  String? sourcePath,
}) async {
  final knownMime = _sniffMime(raw);
  Uint8List bytes;
  String mime;
  if (knownMime != null) {
    bytes = raw;
    mime = knownMime;
  } else {
    final png = await _toPng(raw);
    if (png == null || png.isEmpty) return null;
    bytes = png;
    mime = 'image/png';
  }

  final ext = _extForMime(mime);
  // 既知フォーマットのファイル由来なら元ファイル名を活かす (拡張子はそのまま)。
  // PNG 変換した / メモリ画像なら一意名を振る。いずれにせよ空 filename にしない
  // (空だと uploadMedia 側のフォールバックが要る / 422 の温床になる)。
  final base = sourcePath != null ? _baseName(sourcePath) : '';
  final name = (knownMime != null && base.isNotEmpty)
      ? base
      : 'pasted-${DateTime.now().millisecondsSinceEpoch}.$ext';
  return ClipboardImage(bytes: bytes, mimeType: mime, suggestedName: name);
}

/// パスの拡張子が画像っぽいか (CF_HDROP で来たファイルの粗フィルタ)。実判定は
/// 読み込み後の [_sniffMime] が行うので、ここは巨大な非画像を読まないための足切り。
bool _looksLikeImagePath(String path) {
  final lower = path.toLowerCase();
  const exts = [
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.heic',
    '.heif',
  ];
  for (final e in exts) {
    if (lower.endsWith(e)) return true;
  }
  return false;
}

/// パス末尾のファイル名部分 (`/` と `\` 両対応)。
String _baseName(String path) {
  final i = path.lastIndexOf(RegExp(r'[\\/]'));
  return i >= 0 ? path.substring(i + 1) : path;
}

// Web push 経路用。Desktop では呼ばれないが、条件付き import のシグネチャ整合の
// ため no-op を提供する。
void Function() listenPasteImages({
  required bool Function() shouldAccept,
  required void Function(List<ClipboardImage>) onImages,
}) =>
    () {};

/// 任意の画像バイト列を PNG に変換する。Skia (dart:ui の image codec) は BMP /
/// WBMP 等もデコードできるので、Windows クリップボードの BMP を PNG 化できる。
/// デコード不能なら null。
Future<Uint8List?> _toPng(Uint8List bytes) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

/// 画像バイト列の先頭マジックバイトから Mastodon が受け付ける MIME を推定する。
/// 該当しないフォーマット (BMP / 未知) は null を返し、呼び出し側で PNG 変換させる。
String? _sniffMime(Uint8List b) {
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return 'image/png';
  }
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (b.length >= 6 &&
      b[0] == 0x47 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x38) {
    return 'image/gif';
  }
  // RIFF....WEBP
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'image/webp';
  }
  return null; // BMP ("BM") などはここに来る → PNG に変換する
}

String _extForMime(String mime) {
  switch (mime) {
    case 'image/jpeg':
      return 'jpg';
    case 'image/gif':
      return 'gif';
    case 'image/webp':
      return 'webp';
    case 'image/png':
    default:
      return 'png';
  }
}
