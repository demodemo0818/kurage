// lib/services/backup_service.dart
//
// 設定・カラム・アカウントをまとめてエクスポート / インポートする
// 「フルバックアップ」ロジック (別端末へのアプリデータ移行に使える)。
//
// **重要**: アカウントの `accessToken` を平文で含むため、書き出した JSON
// ファイルは「ログイン情報そのもの」。流出するとアカウント乗っ取りに繋がる。
// UI 側でエクスポート時に必ず警告を出すこと。
//
// ファイルの保存 / 読み込み自体はプラットフォーム差があるため
// [backup_file.dart] (条件付き import) に委譲し、ここは JSON の組み立てと
// 復元 (providers への反映) だけを担当する。

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auth_account.dart';
import '../providers/auth_provider.dart';
import '../providers/column_provider.dart';
import '../providers/settings_provider.dart';

/// バックアップファイルの識別子。インポート時にこの値で「Kurage の
/// バックアップか」を判定する。
const String kBackupType = 'kurage-backup';

/// バックアップフォーマットのバージョン。将来フォーマットを変えたら +1 して、
/// インポート側で必要なら移行する。
const int kBackupVersion = 1;

/// 現在の設定・カラム・アカウントをまとめたバックアップ JSON 文字列を作る
/// (人が読めるよう 2 スペースインデント)。
///
/// accounts はアクセストークンを含むので、生成物の取り扱いに注意。
String buildBackupJson(WidgetRef ref, {required DateTime exportedAt}) {
  final settings = ref.read(settingsProvider);
  final columns = ref.read(columnProvider);
  final accounts = ref.read(authProvider).accounts;

  final map = <String, dynamic>{
    'type': kBackupType,
    'version': kBackupVersion,
    'app': 'kurage',
    'exportedAt': exportedAt.toIso8601String(),
    'settings': settings.toJson(),
    'columns': columns,
    'accounts': accounts.map((a) => a.toJson()).toList(),
  };
  return const JsonEncoder.withIndent('  ').convert(map);
}

/// パース済みバックアップの中身。各セクションは存在しなければ null。
class BackupContent {
  final Map<String, dynamic>? settings;
  final List<Map<String, dynamic>>? columns;
  final List<AuthAccount>? accounts;

  const BackupContent({this.settings, this.columns, this.accounts});

  int get accountCount => accounts?.length ?? 0;
  int get columnCount => columns?.length ?? 0;
  bool get hasSettings => settings != null;
}

/// バックアップ JSON を検証 + パースする。
/// 不正な内容のときは [FormatException] (日本語メッセージ付き) を投げる。
BackupContent parseBackupJson(String jsonStr) {
  late final Map<String, dynamic> root;
  try {
    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('バックアップ形式ではありません');
    }
    root = decoded;
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('JSON として読み取れませんでした');
  }

  if (root['type'] != kBackupType) {
    throw const FormatException('Kurage のバックアップファイルではありません');
  }

  final settings = (root['settings'] as Map?)?.cast<String, dynamic>();

  final columns = (root['columns'] as List?)
      ?.map((e) => (e as Map).cast<String, dynamic>())
      .toList();

  final accounts = (root['accounts'] as List?)
      ?.map((e) => AuthAccount.fromJson((e as Map).cast<String, dynamic>()))
      .toList();

  return BackupContent(
    settings: settings,
    columns: columns,
    accounts: accounts,
  );
}

/// パース済みバックアップをアプリに反映する (既存データを置き換える)。
/// 含まれていないセクションはそのまま (置き換えない)。
///
/// providers の state を直接差し替えるので、アプリ再起動なしで即座に反映される
/// (テーマ・カラム・アカウント一覧が更新される)。
Future<void> applyBackup(WidgetRef ref, BackupContent content) async {
  if (content.settings != null) {
    await ref.read(settingsProvider.notifier).importFromJson(content.settings!);
  }
  if (content.accounts != null) {
    await ref.read(authProvider.notifier).importAccounts(content.accounts!);
  }
  if (content.columns != null) {
    await ref.read(columnProvider.notifier).save(content.columns!);
  }
}
