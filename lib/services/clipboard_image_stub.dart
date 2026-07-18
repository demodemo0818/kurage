// lib/services/clipboard_image_stub.dart
//
// モバイル (Android/iOS) / 未対応プラットフォーム用フォールバック。
// クリップボード画像の貼り付け添付は Web / Desktop 専用なので全て no-op。
// dart:io も dart:js_interop も触らない素実装。

import 'clipboard_image.dart' show ClipboardImage;

bool get clipboardPullSupported => false;

Future<List<ClipboardImage>> readClipboardImages() async => const [];

void Function() listenPasteImages({
  required bool Function() shouldAccept,
  required void Function(List<ClipboardImage>) onImages,
}) =>
    () {}; // 解除も no-op
