// lib/services/auth_service_web.dart
//
// dart:html は deprecated のため package:web + dart:js_interop を使う。

import 'dart:convert';
import 'dart:async';
import 'dart:js_interop';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;
import '../models/auth_account.dart';

/// ユーザージェスチャ内で同期的に先行オープンしたポップアップ。
/// iOS Safari は「ユーザージェスチャに同期しない window.open」をポップアップ
/// ブロッカーで弾くため、ボタン押下の瞬間に [prepareAuthWindow] で about:blank
/// を開いておき、アプリ登録 (非同期) 完了後に [login] がこの窓を認可 URL へ
/// 遷移させる。
web.Window? _pendingAuthWindow;

/// 認証用ポップアップを先行オープンする。
///
/// **必ずユーザージェスチャのハンドラ内から await を挟まずに同期で呼ぶこと。**
/// `await` の後で呼ぶと iOS Safari がジェスチャ外の window.open と見なして
/// ブロックする (このバグの原因そのもの)。
void prepareAuthWindow() {
  // 二重呼び出し等で残骸が居たら閉じておく。
  try {
    _pendingAuthWindow?.close();
  } catch (_) {}
  _pendingAuthWindow = null;
  try {
    _pendingAuthWindow = web.window.open(
      'about:blank',
      'oauth_auth',
      'width=500,height=600,scrollbars=yes,resizable=yes',
    );
  } catch (_) {
    _pendingAuthWindow = null;
  }
}

/// Web用のOAuth認証フロー
Future<AuthAccount> login({
  required String instanceUrl,
  List<String> scopes = const ['read', 'write', 'follow', 'push'],
  String redirectUri = 'jp.demo2.kurage://callback', // Web では使用されない
}) async {
  // ジェスチャ内で先行オープンされた窓を引き取る (無ければ後段で開く)。
  final preOpened = _pendingAuthWindow;
  _pendingAuthWindow = null;

  // 1) アプリを登録して client_id/secret を取得
  final http.Response appResp;
  try {
    appResp = await http.post(
      Uri.parse('$instanceUrl/api/v1/apps'),
      body: {
        'client_name': 'Kurage for mastodon (Web)',
        'redirect_uris': '${web.window.location.origin}/auth/callback.html',
        'scopes': scopes.join(' '),
        'website': web.window.location.origin,
      },
    );
  } catch (_) {
    // 登録に到達できなかった (ネットワーク等)。先行オープンした空ポップアップを
    // 残さないよう閉じてから投げ直す。
    preOpened?.close();
    rethrow;
  }

  if (appResp.statusCode != 200) {
    preOpened?.close();
    throw Exception('アプリ登録に失敗: ${appResp.statusCode}');
  }

  final appJson = jsonDecode(appResp.body);
  final clientId = appJson['client_id'] as String;
  final clientSecret = appJson['client_secret'] as String;

  // 2) 認可URLを構築
  final state = _generateRandomString(32);
  final authUrl = Uri.parse('$instanceUrl/oauth/authorize').replace(
    queryParameters: {
      'client_id': clientId,
      'redirect_uri': '${web.window.location.origin}/auth/callback.html',
      'response_type': 'code',
      'scope': scopes.join(' '),
      'state': state,
    },
  );

  // 3) 認証ページを開く
  final web.Window? authWindow;
  if (preOpened != null && !preOpened.closed) {
    // 先行オープン済みの窓 (ジェスチャ内で開いたのでブロックされていない) を
    // 認可 URL へ遷移させる。これが iOS Safari でも確実に開ける経路。
    preOpened.location.href = authUrl.toString();
    authWindow = preOpened;
  } else {
    // 先行オープンが無い / 既に閉じられている場合のフォールバック。
    // (ジェスチャ外なので環境によってはブロックされ得る。)
    authWindow = web.window.open(
      authUrl.toString(),
      'oauth_auth',
      'width=500,height=600,scrollbars=yes,resizable=yes',
    );

    // ポップアップブロッカーで弾かれた場合、window.open が null を返すか、
    // "壊れた" Window を返して `.closed` が直後に true になるパターンが多い。
    // ユーザーが何が起きたか分かるよう専用エラーを投げる (汎用「キャンセル
    // されました」と区別する)。
    // 注: 一部の環境では即時には closed=false でも、postMessage を一切
    // 受け取れずに 5 分タイムアウトに陥ることがある。完全検出は無理なので
    // best-effort の早期検知のみ。
    try {
      if (authWindow == null || authWindow.closed) {
        throw Exception(
          'ポップアップがブロックされました。'
          'ブラウザのアドレスバーからこのサイトのポップアップを許可してから'
          '再度ログインしてください。',
        );
      }
    } catch (e) {
      if (e is Exception && e.toString().contains('ポップアップ')) rethrow;
      // .closed アクセス自体が SecurityError 等で死ぬ系は一旦無視して
      // 通常の待機処理に流す (= タイムアウト or 後段のエラーで拾う)。
    }
  }

  // 4) 認証完了を待機
  final code = await _waitForAuthCode(authWindow, state);

  // 5) アクセストークンを取得
  final tokenResp = await http.post(
    Uri.parse('$instanceUrl/oauth/token'),
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: {
      'client_id': clientId,
      'client_secret': clientSecret,
      'redirect_uri': '${web.window.location.origin}/auth/callback.html',
      'grant_type': 'authorization_code',
      'code': code,
    },
  );

  if (tokenResp.statusCode != 200) {
    throw Exception('トークン取得に失敗: ${tokenResp.statusCode}');
  }

  final tokenJson = jsonDecode(tokenResp.body);
  final accessToken = tokenJson['access_token'] as String;

  // 6) アカウント情報を取得
  return _fetchUserAccount(instanceUrl, accessToken);
}

/// アカウント情報を取得する共通メソッド
Future<AuthAccount> _fetchUserAccount(String instanceUrl, String accessToken) async {
  final userResp = await http.get(
    Uri.parse('$instanceUrl/api/v1/accounts/verify_credentials'),
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (userResp.statusCode != 200) {
    throw Exception('アカウント情報取得に失敗: ${userResp.statusCode}');
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

/// 認証完了を待機（Web用）
Future<String> _waitForAuthCode(
    web.Window? authWindow, String expectedState) async {
  final completer = Completer<String>();
  late StreamSubscription subscription;
  Timer? timeoutTimer;
  Timer? watchTimer;

  // どの経路で完了してもリスナー・タイマーを残さない
  void cleanup() {
    subscription.cancel();
    timeoutTimer?.cancel();
    watchTimer?.cancel();
  }

  // メッセージリスナーを設定
  subscription = web.EventStreamProviders.messageEvent
      .forTarget(web.window)
      .listen((event) {
    if (event.origin != web.window.location.origin) return;

    // callback.html が postMessage する JS object を Dart Map に変換してから
    // 既存の判定をそのまま使う。
    final data = event.data.dartify();
    if (data is Map && data['type'] == 'oauth_callback') {
      cleanup();
      authWindow?.close();

      final code = data['code'] as String?;
      final state = data['state'] as String?;
      final error = data['error'] as String?;

      if (error != null) {
        completer.completeError(Exception('認証エラー: $error'));
      } else if (code == null || state == null) {
        completer.completeError(Exception('認証パラメータが不正です'));
      } else if (state != expectedState) {
        completer.completeError(Exception('State パラメータが一致しません'));
      } else {
        completer.complete(code);
      }
    }
  });

  // タイムアウト設定（5分）
  timeoutTimer = Timer(const Duration(minutes: 5), () {
    if (!completer.isCompleted) {
      cleanup();
      authWindow?.close();
      completer.completeError(Exception('認証がタイムアウトしました'));
    }
  });

  // ウィンドウが閉じられた場合の処理
  watchTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
    if (authWindow == null || authWindow.closed) {
      if (!completer.isCompleted) {
        cleanup();
        completer.completeError(Exception('認証がキャンセルされました'));
      } else {
        timer.cancel();
      }
    }
  });

  return completer.future;
}

/// ランダム文字列を生成
String _generateRandomString(int length) {
  const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final random = Random.secure();
  return String.fromCharCodes(
    List.generate(length, (index) => chars.codeUnitAt(random.nextInt(chars.length))),
  );
}
