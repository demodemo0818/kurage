// lib/services/image_save_io.dart
//
// デスクトップ (Windows / macOS / Linux) で画像バイト列をディスクに保存する。
// モバイル (Android = Pictures + media scanner / iOS = サンドボックス) の保存は
// full_screen_image_page.dart 側の従来ロジックが担当し、ここは扱わない。
//
// backup_save_io.dart と同じく file_selector + dart:io のトップレベル関数。
// dart:io を使うので Web からは呼ばないこと (呼び出し側で isDesktop() ガード)。

import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';

/// デスクトップで画像バイト列を保存する。
///
/// - [askLocation] が true: ネイティブ「名前を付けて保存」ダイアログ
///   (getSaveLocation) で保存先 + ファイル名を選ばせる。**キャンセル時は null**。
/// - [askLocation] が false: [preferredDir] (非空かつ存在すれば) → なければ
///   ダウンロードフォルダ → 最後に Documents の順で決めたフォルダへ
///   [suggestedName] で直接保存する。
///
/// 戻り値: 保存したフルパス (成功) / null (ダイアログをキャンセル)。
/// ダウンロード失敗・書き込み失敗は呼び出し側で扱えるよう throw のままにする。
Future<String?> saveImageToDesktop(
  Uint8List bytes, {
  required String suggestedName,
  String? preferredDir,
  required bool askLocation,
}) async {
  if (askLocation) {
    const group = XTypeGroup(
      label: 'Image',
      extensions: <String>['jpg', 'jpeg', 'png'],
    );
    final location = await getSaveLocation(
      acceptedTypeGroups: const [group],
      suggestedName: suggestedName,
    );
    if (location == null) return null; // キャンセル
    await File(location.path).writeAsBytes(bytes);
    return location.path;
  }

  Directory? dir;
  if (preferredDir != null && preferredDir.trim().isNotEmpty) {
    dir = Directory(preferredDir);
  }
  if (dir == null || !await dir.exists()) {
    dir = await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
  }
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  final path = '${dir.path}${Platform.pathSeparator}$suggestedName';
  await File(path).writeAsBytes(bytes);
  return path;
}

/// 設定画面で既定の保存先フォルダを選ばせる。キャンセル時は null。
Future<String?> pickSaveDirectory() => getDirectoryPath();
