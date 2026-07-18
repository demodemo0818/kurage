// lib/services/auth_service.dart

import '../models/auth_account.dart';

// 条件付きimport
import 'auth_service_stub.dart'
    if (dart.library.js_interop) 'auth_service_web.dart'
    if (dart.library.io) 'auth_service_mobile.dart' as auth_impl;

class AuthService {
  /// Mastodon OAuth ログインフロー
  ///
  /// - [instanceUrl]: インスタンスの URL（例: https://mastodon.example）
  /// - [scopes]: リクエストするスコープ
  ///
  /// redirect URI は意図的にここで指定しない。プラットフォーム実装側
  /// ([auth_service_mobile.dart] / [auth_service_web.dart]) がそれぞれ
  /// プラットフォーム + ビルドモードに応じた正しい URI を選ぶ
  /// (mobile は kDebugMode で `jp.demo2.kurage.debug` / `jp.demo2.kurage`
  /// を切り替え、web は `window.location.origin/auth/callback.html`)。
  /// ここでデフォルト値を渡してしまうと、release 用スキームを debug
  /// ビルドに上書きしてしまい、OAuth コールバックがアプリに戻らない。
  static Future<AuthAccount> login({
    required String instanceUrl,
    List<String> scopes = const ['read', 'write', 'follow', 'push'],
  }) async {
    return auth_impl.login(
      instanceUrl: instanceUrl,
      scopes: scopes,
    );
  }

  /// 認証用ポップアップの先行オープン (Web 専用、他プラットフォームは no-op)。
  ///
  /// iOS Safari はユーザージェスチャに同期しない `window.open` をブロックする
  /// ため、Web ではログインボタン押下のハンドラ内から **await を挟まず同期で**
  /// これを呼んでおく必要がある。[login] が後でこの窓を認可 URL へ遷移させる。
  static void prepareAuthWindow() => auth_impl.prepareAuthWindow();
}