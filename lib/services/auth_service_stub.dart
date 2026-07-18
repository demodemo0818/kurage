// lib/services/auth_service_stub.dart

import '../models/auth_account.dart';

/// スタブ実装（このファイルは実際には使用されません）
Future<AuthAccount> login({
  required String instanceUrl,
  List<String> scopes = const ['read', 'write', 'follow', 'push'],
  String redirectUri = 'jp.demo2.kurage://callback',
}) async {
  throw UnimplementedError('プラットフォーム固有の実装が見つかりません');
}

/// Web 専用の先行オープンに対応するための no-op (このスタブは未使用)。
void prepareAuthWindow() {}