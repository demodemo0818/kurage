// lib/services/auth_service_stub.dart

import '../l10n/l10n.dart';
import '../models/auth_account.dart';

/// スタブ実装（このファイルは実際には使用されません）
Future<AuthAccount> login({
  required String instanceUrl,
  List<String> scopes = const ['read', 'write', 'follow', 'push'],
  String redirectUri = 'jp.demo2.kurage://callback',
}) async {
  throw UnimplementedError(l10n.authPlatformNotImplemented);
}

/// Web 専用の先行オープンに対応するための no-op (このスタブは未使用)。
void prepareAuthWindow() {}