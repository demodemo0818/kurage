// lib/services/clipboard_image_web.dart
//
// Web のクリップボード画像取得 (push 型)。document の `paste` イベントを購読し、
// 画像が貼り付けられたら取り出してコールバックする。
//
// async Clipboard API (`navigator.clipboard.read`) は権限プロンプト必須 + Firefox
// 非対応なので使わず、`paste` イベント (ClipboardEvent.clipboardData.items) から
// 同期的に画像 File を取り出す方式にする。これなら権限不要・全ブラウザ対応で、
// Ctrl/Cmd+V でもコンテキストメニューの「貼り付け」でも反応する。
//
// このファイルは条件付き import の `if (dart.library.js_interop)` 側でのみ読み込ま
// れるため、dart:io / pasteboard は一切触らない。

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'clipboard_image.dart' show ClipboardImage;

// Web は paste イベント (push) で取得するので、Ctrl+V による pull は使わない。
bool get clipboardPullSupported => false;

Future<List<ClipboardImage>> readClipboardImages() async => const [];

void Function() listenPasteImages({
  required bool Function() shouldAccept,
  required void Function(List<ClipboardImage>) onImages,
}) {
  void handler(web.ClipboardEvent event) {
    // 本文がフォーカスされていない (= 裏のタイムラインや他の入力欄での貼り付け)
    // ときは奪わない。
    if (!shouldAccept()) return;

    final data = event.clipboardData;
    if (data == null) return;

    // 画像 File を同期的に取り出す。DataTransferItem は event の間しか有効で
    // ないので、getAsFile() はここで済ませる (File 参照は後で非同期に読める)。
    final items = data.items;
    final files = <web.File>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.kind == 'file' && item.type.startsWith('image/')) {
        final f = item.getAsFile();
        if (f != null) files.add(f);
      }
    }

    // 画像が無ければ何もしない (= テキストのみの貼り付け)。preventDefault も
    // 呼ばないので TextField の通常テキストペーストはそのまま動く。
    if (files.isEmpty) return;

    // 画像を処理するときだけ既定動作を抑止し、本文にゴミテキストが入るのを防ぐ。
    event.preventDefault();
    unawaited(_decodeAll(files, onImages));
  }

  // removeEventListener には addEventListener と同一の JSFunction 参照を渡す
  // 必要があるため、ここで一度だけ .toJS してクロージャに閉じ込め、解除関数で
  // 同じ参照を使う。
  final jsHandler = handler.toJS;
  web.document.addEventListener('paste', jsHandler);
  return () => web.document.removeEventListener('paste', jsHandler);
}

Future<void> _decodeAll(
  List<web.File> files,
  void Function(List<ClipboardImage>) onImages,
) async {
  final out = <ClipboardImage>[];
  for (final f in files) {
    final buffer = await f.arrayBuffer().toDart; // JSArrayBuffer
    final bytes = buffer.toDart.asUint8List();
    if (bytes.isEmpty) continue;
    final mime = f.type.isNotEmpty ? f.type : 'image/png';
    final name = f.name.isNotEmpty
        ? f.name
        : 'pasted-${DateTime.now().millisecondsSinceEpoch}.${_extForMime(mime)}';
    out.add(ClipboardImage(bytes: bytes, mimeType: mime, suggestedName: name));
  }
  if (out.isNotEmpty) onImages(out);
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
