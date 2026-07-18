// lib/utils/instance_utils.dart

/// インスタンス関連のユーティリティ関数
library;


/// インスタンスURLからインスタンス名（ホスト名）を抽出
String extractInstanceName(String instanceUrl) {
  try {
    final uri = Uri.parse(instanceUrl);
    return uri.host;
  } catch (e) {
    return instanceUrl.replaceAll(RegExp(r'https?://'), '');
  }
}

/// ユーザー名とインスタンスURLから完全なユーザーIDを作成
/// 例: createFullUserId('username', 'https://mastodon.example.com') -> '@username@mastodon.example.com'
String createFullUserId(String username, String instanceUrl) {
  final instanceName = extractInstanceName(instanceUrl);
  return '@$username@$instanceName';
}

/// Mastodonのacctフィールドから完全なユーザーIDを作成
/// acctフィールドが既に完全な形式なら@を付けて返し、そうでなければ現在のインスタンスを補完
/// 例: formatAcct('user@example.com', 'https://local.com') -> '@user@example.com'
/// 例: formatAcct('localuser', 'https://local.com') -> '@localuser@local.com'
String formatAcct(String acct, String fallbackInstanceUrl) {
  if (acct.contains('@')) {
    // 既に完全な形式の場合は@を先頭に付ける
    return '@$acct';
  } else {
    // ローカルユーザーの場合は現在のインスタンスを補完
    final instanceName = extractInstanceName(fallbackInstanceUrl);
    return '@$acct@$instanceName';
  }
}