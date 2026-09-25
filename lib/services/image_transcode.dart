// lib/services/image_transcode.dart
//
// サーバが受け付けない画像形式 (HEIC / HEIF / AVIF) を、アップロード前に
// JPEG へ変換する。
//
// Mastodon 4.7.2 は libvips の HEIF ローダを (セキュリティ上の理由で一時的に)
// 無効化したため、HEIC / HEIF / AVIF (AVIF も同じローダでデコードされる) の
// アップロードが処理段階で 500 になる (後続の修正 mastodon#40542 で、受け付け
// 自体を拒否して supported_mime_types からも外す形になった)。4.7.1 以前も
// サーバ側で JPEG に変換して保存していたので、クライアントで先に JPEG 化しても
// 投稿結果は変わらない。そのため、サーバのバージョンや supported_mime_types を
// 見ずに常に変換する (4.7.2 は受け付けられないのに supported_mime_types に載せた
// ままなので、そこを見て判断すると 4.7.2 で失敗する)。
//
// デコードは dart:ui (Flutter エンジン) に任せる。Android 9+ (AVIF は 12+) は
// OS の ImageDecoder、macOS は ImageIO 経由で読め、回転 (irot) も反映される。
// Windows / Linux では読めないので [ImageTranscodeException] になる。Web だけは
// ブラウザの <img> + <canvas> で変換する (image_transcode_web.dart。dart:ui の
// Web デコーダは Chrome で静止画 AVIF を読めないため)。Chrome / Firefox は AVIF
// のみ、Safari は HEIC も読める。iOS の image_picker は自前で JPEG にして
// 返すので、ここに HEIC が来るのは主に Android のギャラリーとデスクトップ /
// Web のドラッグ&ドロップ・貼り付け。

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'image_transcode_stub.dart'
    if (dart.library.js_interop) 'image_transcode_web.dart' as browser;

/// Mastodon がオリジナル画像を縮小する上限ピクセル数 (3840x2160 相当。
/// media_attachment.rb の `IMAGE_STYLES[:original][:pixels]`)。これより大きく
/// 送ってもサーバで縮められるだけなので、変換時にここまで縮小してメモリと
/// 転送量を抑える。
const int kMastodonMaxImagePixels = 8294400;

/// 変換後の JPEG 品質。
const int _jpegQuality = 90;

/// [isHeifFamilyImage] の判定に読む先頭バイト数。
const int _sniffLength = 64;

/// HEIF 系の ftyp ブランド (HEIC / HEIF の静止画・シーケンスと AVIF)。
const Set<String> _heifFamilyBrands = {
  'heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'hevm', 'hevs', // HEIC
  'mif1', 'msf1', // HEIF 汎用
  'avif', 'avis', // AVIF
};

/// JPEG への変換に失敗した (この環境のデコーダが HEIC / AVIF を読めない等)。
class ImageTranscodeException implements Exception {
  final Object cause;
  ImageTranscodeException(this.cause);

  @override
  String toString() => 'ImageTranscodeException: $cause';
}

/// JPEG に変換した画像。
class ConvertedImage {
  /// アップロードに使う XFile (`XFile.fromData`、image/jpeg)。
  final XFile file;

  /// 変換後の JPEG バイト列。`XFile.fromData` は io 実装だと実ファイルの
  /// path を持たず `Image.file` でプレビューできないので、`Image.memory` 用に
  /// 別途持たせる (クリップボード画像の `MediaItem.localBytes` と同じ扱い)。
  final Uint8List bytes;

  ConvertedImage(this.file, this.bytes);
}

/// 先頭バイト列が HEIC / HEIF / AVIF (ISO BMFF の `ftyp` ボックスのブランドで
/// 判定) か。拡張子や MIME は当てにしない (Android の image_picker はキャッシュ
/// へのコピー時に拡張子を付け直すので、中身と一致する保証が無い)。
bool isHeifFamilyImage(Uint8List head) {
  if (head.length < 16) return false;
  // [0..4) ボックスサイズ (big endian), [4..8) 'ftyp', [8..12) major brand,
  // [12..16) minor version, 以降ボックス末尾まで compatible brands。
  if (String.fromCharCodes(head, 4, 8) != 'ftyp') return false;
  final boxSize =
      (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
  if (_heifFamilyBrands.contains(String.fromCharCodes(head, 8, 12))) {
    return true;
  }
  final end = math.min(boxSize, head.length);
  for (var i = 16; i + 4 <= end; i += 4) {
    if (_heifFamilyBrands.contains(String.fromCharCodes(head, i, i + 4))) {
      return true;
    }
  }
  return false;
}

/// [file] が HEIC / HEIF / AVIF なら JPEG に変換して返す。それ以外は null
/// (変換不要なのでそのままアップロードしてよい)。
///
/// 変換できなければ [ImageTranscodeException] を投げる。先頭の読み取り自体に
/// 失敗した場合は判定できないので null (本来のアップロード経路にエラー処理を
/// 任せる)。
Future<ConvertedImage?> convertHeifFamilyToJpeg(XFile file) async {
  final Uint8List head;
  try {
    head = await _readHead(file);
  } catch (e) {
    debugPrint('画像形式の判定に失敗 (${file.name}): $e');
    return null;
  }
  if (!isHeifFamilyImage(head)) return null;

  final Uint8List jpeg;
  try {
    jpeg = await transcodeToJpeg(await file.readAsBytes());
  } catch (e) {
    throw ImageTranscodeException(e);
  }
  final name = _jpegFileName(file.name);
  final converted = XFile.fromData(
    jpeg,
    name: name,
    // io 実装の XFile.fromData は name を無視して path から導出する (空 filename
    // は 422 の温床。docs/pitfalls.md)。中身はメモリ上にあり path は開かれない
    // ので、ファイル名だけを path に入れる。Web は name が効き、path を渡すと
    // blob URL が作られなくなるので渡さない。
    path: kIsWeb ? null : name,
    mimeType: 'image/jpeg',
    length: jpeg.length,
  );
  return ConvertedImage(converted, jpeg);
}

/// エンコード済み画像 [encoded] を JPEG に変換する。[maxPixels] を超える画像は
/// アスペクト比を保って縮小し、透過部分は白で塗る。
Future<Uint8List> transcodeToJpeg(
  Uint8List encoded, {
  int maxPixels = kMastodonMaxImagePixels,
}) async {
  if (kIsWeb) {
    return browser.transcodeToJpeg(encoded,
        maxPixels: maxPixels, quality: _jpegQuality / 100);
  }

  // バッファの所有権は codec の生成で移る (dispose は不要)。
  final buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
  final codec = await ui.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (width, height) {
      final size = fitWithinPixels(width, height, maxPixels);
      return ui.TargetImageSize(width: size.width, height: size.height);
    },
  );
  final int width;
  final int height;
  final ByteData rgba;
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      width = image.width;
      height = image.height;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        throw StateError('toByteData returned null');
      }
      rgba = data;
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }

  // JPEG エンコードは 8MP で数百 ms かかるので別 isolate で。
  return compute(
    _encodeJpeg,
    _JpegJob(rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
        width, height),
  );
}

/// [width] x [height] を、アスペクト比を保って [maxPixels] 以下に収めた寸法。
/// 収まっていればそのまま返す。
({int width, int height}) fitWithinPixels(
    int width, int height, int maxPixels) {
  if (width * height <= maxPixels) return (width: width, height: height);
  final scale = math.sqrt(maxPixels / (width * height));
  return (
    width: math.max(1, (width * scale).floor()),
    height: math.max(1, (height * scale).floor()),
  );
}

Future<Uint8List> _readHead(XFile file) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.openRead(0, _sniffLength)) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

/// 拡張子を .jpg に付け替えたファイル名。
String _jpegFileName(String name) {
  if (name.isEmpty) return 'image.jpg';
  final dot = name.lastIndexOf('.');
  return '${dot > 0 ? name.substring(0, dot) : name}.jpg';
}

class _JpegJob {
  /// premultiplied alpha の RGBA (ui.ImageByteFormat.rawRgba)。
  final Uint8List rgba;
  final int width;
  final int height;
  _JpegJob(this.rgba, this.width, this.height);
}

Uint8List _encodeJpeg(_JpegJob job) {
  final rgba = job.rgba;
  final rgb = Uint8List(job.width * job.height * 3);
  for (var i = 0, j = 0; i < rgba.length; i += 4, j += 3) {
    // premultiplied なので、白背景への合成は「色 + (255 - alpha)」で済む。
    final bg = 255 - rgba[i + 3];
    rgb[j] = rgba[i] + bg;
    rgb[j + 1] = rgba[i + 1] + bg;
    rgb[j + 2] = rgba[i + 2] + bg;
  }
  final image = img.Image.fromBytes(
    width: job.width,
    height: job.height,
    bytes: rgb.buffer,
    numChannels: 3,
  );
  return img.encodeJpg(image, quality: _jpegQuality);
}
