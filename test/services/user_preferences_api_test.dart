// ユーザー設定 API (GET /api/v1/preferences /
// PATCH update_credentials source[privacy]) のパース / キャッシュのテスト。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kurage/services/mastodon_api.dart';

void main() {
  const base = 'https://ex.com';
  const token = 'tok';
  late http.Request captured;
  late int requestCount;

  void mock(String body, {int status = 200}) {
    requestCount = 0;
    httpClient = MockClient((req) async {
      captured = req;
      requestCount++;
      return http.Response(body, status,
          headers: {'content-type': 'application/json'});
    });
  }

  setUp(() {
    clearUserPreferencesCache();
  });

  tearDown(() {
    httpClient = http.Client();
  });

  test('fetchPreferences は posting:default:* をパースする', () async {
    mock(jsonEncode({
      'posting:default:visibility': 'unlisted',
      'posting:default:language': 'ja',
      'posting:default:sensitive': true,
      'reading:expand:media': 'default',
    }));
    final prefs =
        await fetchPreferences(instanceUrl: base, accessToken: token);
    expect(prefs.defaultVisibility, 'unlisted');
    expect(prefs.defaultLanguage, 'ja');
    expect(prefs.defaultSensitive, isTrue);
    expect(captured.url.toString(), '$base/api/v1/preferences');
    expect(captured.headers['Authorization'], 'Bearer $token');
  });

  test('fetchPreferences は欠落キーをデフォルトで埋める', () async {
    mock(jsonEncode(<String, dynamic>{}));
    final prefs =
        await fetchPreferences(instanceUrl: base, accessToken: token);
    expect(prefs.defaultVisibility, 'public');
    expect(prefs.defaultLanguage, isNull);
    expect(prefs.defaultSensitive, isFalse);
  });

  test('fetchPreferences は 2 回目をキャッシュから返す', () async {
    mock(jsonEncode({'posting:default:visibility': 'private'}));
    final first =
        await fetchPreferences(instanceUrl: base, accessToken: token);
    final second =
        await fetchPreferences(instanceUrl: base, accessToken: token);
    expect(first.defaultVisibility, 'private');
    expect(identical(first, second), isTrue);
    expect(requestCount, 1);
  });

  test('fetchPreferences のキャッシュはアカウント (トークン) 単位', () async {
    mock(jsonEncode({'posting:default:visibility': 'private'}));
    await fetchPreferences(instanceUrl: base, accessToken: token);
    await fetchPreferences(instanceUrl: base, accessToken: 'other-token');
    expect(requestCount, 2);
  });

  test('fetchPreferences は非 200 で例外を投げる (キャッシュ汚染なし)', () async {
    mock('', status: 500);
    expect(
      () => fetchPreferences(instanceUrl: base, accessToken: token),
      throwsException,
    );
  });

  test('updateDefaultPostVisibility は PATCH source[privacy] を送る', () async {
    mock(jsonEncode({'id': '1', 'username': 'u', 'acct': 'u'}));
    await updateDefaultPostVisibility(
        instanceUrl: base, accessToken: token, visibility: 'unlisted');
    expect(captured.method, 'PATCH');
    expect(captured.url.toString(),
        '$base/api/v1/accounts/update_credentials');
    expect(captured.bodyFields['source[privacy]'], 'unlisted');
  });

  test('updateDefaultPostVisibility 成功後は fetchPreferences が新値を返す',
      () async {
    // まず旧値をキャッシュに乗せる
    mock(jsonEncode({
      'posting:default:visibility': 'public',
      'posting:default:language': 'ja',
    }));
    await fetchPreferences(instanceUrl: base, accessToken: token);

    mock(jsonEncode({'id': '1', 'username': 'u', 'acct': 'u'}));
    await updateDefaultPostVisibility(
        instanceUrl: base, accessToken: token, visibility: 'private');

    // 追加 HTTP なしでキャッシュ済みの新値が返る (他フィールドは維持)
    final prefs =
        await fetchPreferences(instanceUrl: base, accessToken: token);
    expect(prefs.defaultVisibility, 'private');
    expect(prefs.defaultLanguage, 'ja');
    expect(requestCount, 1); // update の 1 回だけ (fetch はキャッシュ)
  });

  test('updateDefaultPostVisibility は非 200 で例外 + キャッシュ据え置き',
      () async {
    mock(jsonEncode({'posting:default:visibility': 'public'}));
    await fetchPreferences(instanceUrl: base, accessToken: token);

    mock('', status: 422);
    await expectLater(
      updateDefaultPostVisibility(
          instanceUrl: base, accessToken: token, visibility: 'direct'),
      throwsException,
    );

    final prefs =
        await fetchPreferences(instanceUrl: base, accessToken: token);
    expect(prefs.defaultVisibility, 'public');
  });
}
