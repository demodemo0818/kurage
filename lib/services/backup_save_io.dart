// lib/services/backup_save_io.dart
//
// ネイティブ (モバイル / デスクトップ) のバックアップ保存。
// - モバイル (Android / iOS): file_selector に保存ダイアログが無いため、一時
//   ファイルに書き出して共有シート (share_plus) に渡し、保存先を選ばせる。
// - デスクトップ (Windows / macOS / Linux): ネイティブ保存ダイアログ
//   (file_selector の getSaveLocation)。
//
// XFile は file_selector / share_plus 双方が cross_file から再エクスポートして
// いるので、曖昧さ回避のため file_selector 側を hide して share_plus 由来に統一。

import 'dart:io';

import 'package:file_selector/file_selector.dart' hide XFile;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

Future<bool> saveBackupFile(String suggestedName, String contents) async {
  if (Platform.isAndroid || Platform.isIOS) {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$suggestedName');
    await file.writeAsString(contents);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: 'application/json', name: suggestedName)],
      subject: suggestedName,
    ));
    // 共有シートの結果 (実際にどこへ保存したか) までは取得できないので、
    // シートを開けたら成功扱いにする。
    return true;
  }

  // デスクトップはネイティブ保存ダイアログ。
  const group = XTypeGroup(label: 'JSON', extensions: <String>['json']);
  final location = await getSaveLocation(
    acceptedTypeGroups: const [group],
    suggestedName: suggestedName,
  );
  if (location == null) return false; // キャンセル
  await File(location.path).writeAsString(contents);
  return true;
}
