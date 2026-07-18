// lib/services/clipboard_image.dart
//
// 投稿コンポーズ画面でクリップボードの画像を貼り付け添付するための取得層。
//
// クリップボード画像の取得は Web と Desktop で仕組みが根本的に違うため、
// auth_service.dart と同じ「条件付き import で実装を差し替える」流儀で分離する:
//
//  - Web (`clipboard_image_web.dart`): ブラウザの `paste` イベント (push 型)。
//    `ClipboardEvent.clipboardData.items` から画像 File を同期取得する。権限
//    プロンプト不要・全ブラウザ対応。Ctrl/Cmd+V を自前で拾う必要はなく、貼り付け
//    操作そのものに反応する。async Clipboard API (`navigator.clipboard.read`)
//    は Firefox 非対応 + 権限必須なので使わない。
//  - Desktop (`clipboard_image_io.dart`): `paste` イベントが無いので、呼び出し側
//    (post_page) の Ctrl/Cmd+V キーハンドラ契機で `pasteboard` の `Pasteboard.image`
//    を pull する。
//  - モバイル/フォールバック (`clipboard_image_stub.dart`): 全て no-op。
//
// 取得層が返すのは「画像バイト列 + MIME + 推奨ファイル名」(= [ClipboardImage]) まで。
// XFile 化と実アップロードは呼び出し側 (post_page) が既存の `_uploadImageFile`
// 経路で行う (関心の分離)。

import 'dart:typed_data';

import 'clipboard_image_stub.dart'
    if (dart.library.js_interop) 'clipboard_image_web.dart'
    if (dart.library.io) 'clipboard_image_io.dart' as impl;

/// クリップボードから取得した 1 枚の画像。
class ClipboardImage {
  /// 画像の生バイト列。
  final Uint8List bytes;

  /// MIME タイプ (例: `image/png`, `image/jpeg`)。アップロード時の Content-Type
  /// と拡張子推定に使う。
  final String mimeType;

  /// 添付時のファイル名 (例: `pasted-1718000000.png`)。MIME に対応した拡張子を
  /// 付けておくと `uploadMedia` の MIME フォールバック (`lookupMimeType`) とも
  /// 整合する。
  final String suggestedName;

  const ClipboardImage({
    required this.bytes,
    required this.mimeType,
    required this.suggestedName,
  });
}

/// このプラットフォームで「Ctrl/Cmd+V による pull 取得」をサポートするか。
///
/// Desktop (Windows/macOS/Linux) のみ true。Web は push (paste イベント) を
/// 使うので false。モバイルも false。呼び出し側はこれを見て Ctrl+V キーハンドラ
/// やメニュー項目の出し分けに使う。
bool get clipboardPullSupported => impl.clipboardPullSupported;

/// Desktop 用: Ctrl/Cmd+V やメニュー契機でクリップボードから画像を pull する。
///
/// 画像が無ければ空リスト。Web/モバイルでは常に空 (push 経路を使うため)。
Future<List<ClipboardImage>> readClipboardImages() => impl.readClipboardImages();

/// Web 用: document の `paste` イベントを購読し、画像が貼り付けられたら
/// [onImages] に渡す。戻り値は購読解除関数 (initState で登録し dispose で呼ぶ)。
/// Desktop/モバイルでは no-op を返す。
///
/// [shouldAccept] は「今このペーストを受け取ってよいか」を返すゲート (例: 本文
/// TextField にフォーカスがある時のみ true)。true を返したときだけ画像を処理し、
/// イベントの既定動作 (テキストペースト) を抑止する。
void Function() listenPasteImages({
  required bool Function() shouldAccept,
  required void Function(List<ClipboardImage>) onImages,
}) =>
    impl.listenPasteImages(shouldAccept: shouldAccept, onImages: onImages);
