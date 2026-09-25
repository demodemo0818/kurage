// lib/services/image_transcode_web.dart
//
// Web の JPEG 変換。ブラウザ自身の画像デコーダ (<img>) で読み、<canvas> で
// JPEG に書き出す。image_transcode.dart が kIsWeb の時にこちらを使う。
//
// dart:ui (Flutter エンジン) のデコードは Web では ImageDecoder API を
// `preferAnimation: true` 固定で呼ぶため、Chrome では静止画の AVIF が
// "Failed to retrieve track metadata" で必ず失敗する (Chrome 154 /
// Flutter 3.47.5 で確認。ブラウザの表示自体は問題ない)。<img> ならブラウザが
// 表示できる形式はそのまま読める (Chrome / Firefox の AVIF、Safari の HEIC)。
// エンコードもブラウザのネイティブ実装なので、dart2js の package:image で
// メインスレッドを止めることもない。
//
// このファイルは条件付き import の `if (dart.library.js_interop)` 側でのみ
// 読み込まれる。dart:html は deprecated のため package:web + dart:js_interop。

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'image_transcode.dart' show fitWithinPixels;

Future<Uint8List> transcodeToJpeg(
  Uint8List encoded, {
  required int maxPixels,
  required double quality,
}) async {
  final url = web.URL.createObjectURL(web.Blob([encoded.toJS].toJS));
  try {
    final img = web.HTMLImageElement()..src = url;
    // ブラウザが読めない形式 (Chrome の HEIC 等) はここで reject される。
    await img.decode().toDart;
    // naturalWidth / drawImage は EXIF の回転を反映した向きになる。
    final size =
        fitWithinPixels(img.naturalWidth, img.naturalHeight, maxPixels);
    final canvas = web.HTMLCanvasElement()
      ..width = size.width
      ..height = size.height;
    // JPEG は透過を持てないので、io 実装と同じく白で塗ってから描く。
    canvas.context2D
      ..fillStyle = 'white'.toJS
      ..fillRect(0, 0, size.width, size.height)
      ..drawImage(img, 0, 0, size.width, size.height);

    final completer = Completer<web.Blob?>();
    canvas.toBlob(
      ((web.Blob? blob) => completer.complete(blob)).toJS,
      'image/jpeg',
      quality.toJS,
    );
    final blob = await completer.future;
    if (blob == null) throw StateError('canvas.toBlob returned null');
    return (await blob.arrayBuffer().toDart).toDart.asUint8List();
  } finally {
    web.URL.revokeObjectURL(url);
  }
}
