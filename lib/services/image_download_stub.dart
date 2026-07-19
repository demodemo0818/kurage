// lib/services/image_download_stub.dart
//
// Web 以外のプラットフォーム用スタブ。full_screen_image_page.dart が
// 条件付き import (dart.library.js_interop → image_download_web.dart) で
// 切り替える。呼び出し側は kIsWeb で分岐しているため、これらが実行される
// ことはない (万一呼ばれたら明示的に throw)。

import 'dart:typed_data';

Future<void> downloadBytes(
  Uint8List bytes, {
  required String fileName,
  required String mimeType,
}) async {
  throw UnsupportedError('downloadBytes is Web-only');
}

void openInNewTab(String url) {
  throw UnsupportedError('openInNewTab is Web-only');
}
