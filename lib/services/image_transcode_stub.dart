// lib/services/image_transcode_stub.dart
//
// Web 以外のプラットフォーム用スタブ。image_transcode.dart が条件付き import
// (dart.library.js_interop → image_transcode_web.dart) で切り替える。呼び出し側は
// kIsWeb で分岐しているため、これが実行されることはない (万一呼ばれたら throw)。

import 'dart:typed_data';

Future<Uint8List> transcodeToJpeg(
  Uint8List encoded, {
  required int maxPixels,
  required double quality,
}) async {
  throw UnsupportedError('browser transcodeToJpeg is Web-only');
}
