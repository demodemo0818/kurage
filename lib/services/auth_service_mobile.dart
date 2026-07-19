// lib/services/auth_service_mobile.dart
//
// `dart.library.io` 環境 (= Android / iOS / macOS / Windows / Linux) 共通の
// OAuth 実装。条件付き import (auth_service.dart) では Windows と Android を
// 区別できない (どちらも dart.library.io) ため、プラットフォーム差は
// **実行時の Platform 判定** で吸収する:
//
// - Android / iOS / macOS … `flutter_appauth` (システムのカスタムタブ + カスタム
//   スキーム redirect)。このパッケージは Windows / Linux を **サポートしない**。
// - Windows / Linux … flutter_appauth が使えないため、**ループバック redirect 方式**
//   (RFC 8252) を自前実装。`127.0.0.1` のエフェメラルポートにローカル HTTP サーバを
//   立て、システムブラウザで認可 → `code` をコールバックで受信 → token 交換する。
//
// 投稿の「via」(application 名) は OAuth アプリ登録時の client_name でサーバ側に
// 固定されるので、プラットフォームごとに登録名を変えている (Web は "(Web)" 付き)。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:http/http.dart' as http;
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/l10n.dart';
import '../models/auth_account.dart';

// FlutterAppAuth のインスタンス (Android / iOS / macOS でのみメソッドを呼ぶ。
// インスタンス生成自体は native を叩かないので Windows でも安全)。
final FlutterAppAuth _appAuth = FlutterAppAuth();

/// build.gradle.kts の buildTypes.debug で applicationIdSuffix=".debug"
/// + appAuthRedirectScheme="jp.demo2.kurage.debug" を設定しているので、
/// debug ビルドでは Dart 側もそれに合わせて redirect URI のスキームを
/// 切り替える必要がある。これを怠ると AppAuth が intent-filter にマッチ
/// せずコールバックを受け取れない。
///
/// kDebugMode は const bool で、profile / release では false。
/// profile / release は applicationIdSuffix が無いので `jp.demo2.kurage`
/// のまま、つまりこの分岐が ちょうど Android 側設定と 1:1 で対応する。
const String _redirectScheme =
    kDebugMode ? 'jp.demo2.kurage.debug' : 'jp.demo2.kurage';
const String _defaultRedirectUri = '$_redirectScheme://callback';

/// Windows / Linux は flutter_appauth 非対応なのでループバック方式を使う。
/// macOS は flutter_appauth が対応しているので従来どおり (デスクトップ扱いしない)。
bool get _useLoopbackOAuth => Platform.isWindows || Platform.isLinux;

/// デスクトップ (Windows / Linux) 用の OAuth アプリ登録名。
/// 投稿の via に出るので、Web ("(Web)") と同様プラットフォームを明示する。
String get _desktopClientName {
  if (Platform.isWindows) return 'Kurage for mastodon (Windows)';
  if (Platform.isLinux) return 'Kurage for mastodon (Linux)';
  return 'Kurage for mastodon (Desktop)';
}

/// Web 専用の先行オープンに対応するための no-op。
/// モバイルは flutter_appauth がシステムのブラウザタブを開くので不要。
/// デスクトップもループバック方式側でブラウザを開くので不要。
void prepareAuthWindow() {}

/// OAuth 認証フロー (io プラットフォーム共通エントリ)。
Future<AuthAccount> login({
  required String instanceUrl,
  List<String> scopes = const ['read', 'write', 'follow', 'push'],
  String redirectUri = _defaultRedirectUri,
}) async {
  if (_useLoopbackOAuth) {
    return _loginDesktop(instanceUrl: instanceUrl, scopes: scopes);
  }

  // ----- Android / iOS / macOS: flutter_appauth フロー -----
  // 1) アプリを登録して client_id/secret を取得
  final appResp = await http.post(
    Uri.parse('$instanceUrl/api/v1/apps'),
    body: {
      'client_name': 'Kurage for mastodon',
      'redirect_uris': redirectUri,
      'scopes': scopes.join(' '),
      'website': '',
    },
  );
  if (appResp.statusCode != 200) {
    throw Exception(l10n.authAppRegistrationFailed(appResp.statusCode));
  }
  final appJson = jsonDecode(appResp.body);
  final clientId = appJson['client_id'] as String;
  final clientSecret = appJson['client_secret'] as String;

  // 2) 認可 → コード取得 & トークン交換 を一度に実行
  final AuthorizationTokenResponse result =
      await _appAuth.authorizeAndExchangeCode(
    AuthorizationTokenRequest(
      clientId,
      redirectUri,
      serviceConfiguration: AuthorizationServiceConfiguration(
        authorizationEndpoint: '$instanceUrl/oauth/authorize',
        tokenEndpoint: '$instanceUrl/oauth/token',
      ),
      scopes: scopes,
      clientSecret: clientSecret,
    ),
  );
  if (result.accessToken == null) {
    throw Exception(l10n.authOAuthExchangeFailed);
  }
  final accessToken = result.accessToken!;

  // 3) アカウント情報を取得
  return _fetchUserAccount(instanceUrl, accessToken);
}

/// Windows / Linux: ループバック redirect 方式の OAuth フロー。
///
/// flutter_appauth に依存せず dart:io の HttpServer + url_launcher だけで完結する。
/// ローカルサーバは 127.0.0.1 のエフェメラルポートに立て、redirect_uri を
/// `http://127.0.0.1:<port>/` として **その都度** アプリ登録する (ポートが毎回
/// 変わるため。Mastodon は任意の redirect_uri を受け付ける)。
Future<AuthAccount> _loginDesktop({
  required String instanceUrl,
  required List<String> scopes,
}) async {
  // 1) ループバックサーバを先に立ててポートを確定させる
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  try {
    final redirectUri = 'http://127.0.0.1:${server.port}/';

    // 2) アプリ登録 (client_name = Windows/Linux 用、redirect は確定したポート)
    final appResp = await http.post(
      Uri.parse('$instanceUrl/api/v1/apps'),
      body: {
        'client_name': _desktopClientName,
        'redirect_uris': redirectUri,
        'scopes': scopes.join(' '),
        'website': '',
      },
    );
    if (appResp.statusCode != 200) {
      throw Exception(l10n.authAppRegistrationFailed(appResp.statusCode));
    }
    final appJson = jsonDecode(appResp.body) as Map<String, dynamic>;
    final clientId = appJson['client_id'] as String;
    final clientSecret = appJson['client_secret'] as String;

    // 3) state を生成して認可 URL を組み立て、システムブラウザで開く
    final state = _randomState();
    final authUrl = Uri.parse('$instanceUrl/oauth/authorize').replace(
      queryParameters: {
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': scopes.join(' '),
        'state': state,
      },
    );
    final launched = await launchUrl(
      authUrl,
      mode: LaunchMode.externalApplication,
    );
    if (!launched) {
      throw Exception(l10n.authBrowserOpenFailed);
    }

    // 4) コールバック (code) を待つ。放置対策に 5 分でタイムアウト。
    final code = await _waitForAuthCode(server, state).timeout(
      const Duration(minutes: 5),
      onTimeout: () => throw Exception(l10n.authTimeout5Min),
    );

    // 5) authorization_code → access_token
    final tokenResp = await http.post(
      Uri.parse('$instanceUrl/oauth/token'),
      body: {
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': clientId,
        'client_secret': clientSecret,
        'redirect_uri': redirectUri,
        'scope': scopes.join(' '),
      },
    );
    if (tokenResp.statusCode != 200) {
      throw Exception(l10n.authTokenExchangeFailed(tokenResp.statusCode));
    }
    final accessToken =
        (jsonDecode(tokenResp.body) as Map<String, dynamic>)['access_token']
            as String;

    // 6) アカウント情報を取得
    return _fetchUserAccount(instanceUrl, accessToken);
  } finally {
    await server.close(force: true);
  }
}

/// ループバックサーバへのコールバックを待ち、`code` を返す。
/// `code` も `error` も無いリクエスト (favicon 等) は 404 を返して無視する。
Future<String> _waitForAuthCode(HttpServer server, String expectedState) {
  final completer = Completer<String>();
  late final StreamSubscription<HttpRequest> sub;
  sub = server.listen((req) async {
    final params = req.uri.queryParameters;
    final code = params['code'];
    final error = params['error'];
    final state = params['state'];

    if (code == null && error == null) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }

    // ブラウザに完了ページを返してからアプリへ復帰してもらう
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(_callbackHtml(error: error));
    await req.response.close();

    if (completer.isCompleted) return;
    if (error != null) {
      completer.completeError(Exception(l10n.authDenied(error)));
    } else if (state != expectedState) {
      // 別タブの古い認可など。CSRF 対策で破棄。
      completer.completeError(Exception(l10n.authStateMismatch));
    } else {
      completer.complete(code);
    }
    await sub.cancel();
  });
  return completer.future;
}

/// ブラウザに表示する認証完了ページ (日本語)。
String _callbackHtml({String? error}) {
  final body = error == null
      ? '<h2>${l10n.authCallbackSuccessTitle}</h2><p>${l10n.authCallbackSuccessBody}</p>'
      : '<h2>${l10n.authCallbackFailTitle}</h2><p>${l10n.authCallbackFailBody(error)}</p>';
  return '<!doctype html><html lang="ja"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<title>Kurage</title></head>'
      '<body style="font-family:sans-serif;text-align:center;padding:48px 16px;">'
      '$body</body></html>';
}

/// CSRF 対策用のランダム state (URL-safe)。
String _randomState() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(24, (_) => rnd.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// アカウント情報を取得する共通メソッド
Future<AuthAccount> _fetchUserAccount(String instanceUrl, String accessToken) async {
  final userResp = await http.get(
    Uri.parse('$instanceUrl/api/v1/accounts/verify_credentials'),
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (userResp.statusCode != 200) {
    throw Exception(l10n.authAccountInfoFailed(userResp.statusCode));
  }
  final userJson = jsonDecode(userResp.body) as Map<String, dynamic>;

  // AuthAccount オブジェクトを返却
  return AuthAccount(
    id: userJson['id'] as String,
    instanceUrl: instanceUrl,
    accessToken: accessToken,
    username: userJson['username'] as String,
    displayName: userJson['display_name'] as String,
    avatarUrl: userJson['avatar_static'] as String,
  );
}
