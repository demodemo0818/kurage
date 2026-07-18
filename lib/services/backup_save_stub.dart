// lib/services/backup_save_stub.dart
//
// 条件付き import のフォールバック。実機では dart.library.io / dart.library.html
// のどちらかが必ず使われるので、このスタブが実際に呼ばれることはない。

Future<bool> saveBackupFile(String suggestedName, String contents) async {
  throw UnsupportedError('このプラットフォームではバックアップの保存に未対応です');
}
