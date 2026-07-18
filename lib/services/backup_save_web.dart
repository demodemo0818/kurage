// lib/services/backup_save_web.dart
//
// Web のバックアップ保存。Blob + <a download> でブラウザのダウンロードを起こす。
// (file_selector の保存ダイアログは Web 非対応のため。)
// dart:html は deprecated のため package:web + dart:js_interop を使う。

import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<bool> saveBackupFile(String suggestedName, String contents) async {
  final bytes = Uint8List.fromList(utf8.encode(contents));
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'application/json'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = suggestedName;
  anchor.style.display = 'none';
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
  return true;
}
