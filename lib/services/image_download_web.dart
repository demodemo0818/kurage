// lib/services/image_download_web.dart
//
// Web の画像ダウンロード。Blob + <a download> でブラウザのダウンロードを
// 起こす (backup_save_web.dart と同じ方式)。Flutter Web の CanvasKit 描画は
// 画像を <canvas> のピクセルとして描くため、ブラウザの右クリック「名前を
// 付けて画像を保存」が使えない。そのためアプリ側の保存ボタンからこれを呼ぶ。
// dart:html は deprecated のため package:web + dart:js_interop を使う。

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<void> downloadBytes(
  Uint8List bytes, {
  required String fileName,
  required String mimeType,
}) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName;
  anchor.style.display = 'none';
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}

/// 画像 URL を新しいタブで開く。CORS 未対応 CDN で bytes を fetch できない
/// 画像のフォールバック (タブ側は素の <img> になるのでブラウザの保存メニュー
/// が使える)。クリック直後の transient user activation が残っているうちに
/// 呼ぶこと (経過するとポップアップブロックされ得る)。
void openInNewTab(String url) {
  web.window.open(url, '_blank');
}
