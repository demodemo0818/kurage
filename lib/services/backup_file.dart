// lib/services/backup_file.dart
//
// バックアップファイルの保存 / 読み込みのプラットフォーム差を吸収する層。
// 保存は方法がプラットフォームごとに違う (モバイル=共有シート / デスクトップ=
// 保存ダイアログ / Web=ダウンロード) ので条件付き import で実装を切り替える。
// 読み込み (openFile) は file_selector が全プラットフォームで動くので共通実装。

import 'dart:convert';

import 'package:file_selector/file_selector.dart';

import 'backup_save_stub.dart'
    if (dart.library.io) 'backup_save_io.dart'
    if (dart.library.js_interop) 'backup_save_web.dart' as saver;

/// バックアップ JSON をファイルとして保存する。
/// 保存 / 共有を開始できたら true、ユーザーがキャンセルしたら false。
Future<bool> saveBackupFile(String suggestedName, String contents) =>
    saver.saveBackupFile(suggestedName, contents);

/// バックアップファイルをユーザーに選ばせ、中身 (文字列) を返す。
/// キャンセル時は null。`openFile` は全プラットフォーム (Web 含む) で動く。
Future<String?> pickBackupFile() async {
  const group = XTypeGroup(label: 'JSON', extensions: <String>['json']);
  final file = await openFile(acceptedTypeGroups: const [group]);
  if (file == null) return null;
  // XFile.readAsString は bytes 由来の XFile (file_selector_android / web は
  // これ) だと encoding 引数を無視して String.fromCharCodes (= Latin-1 相当)
  // でデコードしてしまい、UTF-8 の日本語が文字化けする。生バイトを取って
  // 明示的に UTF-8 デコードする (CLAUDE.md の「XFile は readAsBytes を使う」方針)。
  final bytes = await file.readAsBytes();
  var text = utf8.decode(bytes, allowMalformed: true);
  // 先頭 BOM (U+FEFF) があると jsonDecode が失敗するので取り除く。
  if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
    text = text.substring(1);
  }
  return text;
}
