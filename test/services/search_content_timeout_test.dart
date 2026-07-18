// searchContent のタイムアウト伝播テスト。
//
// `resolve: true` の検索はサーバ側のリモート解決で長時間ブロックし得るため
// `.timeout()` を持つが、その TimeoutException が
// - v1 フォールバックに化けない (同じ resolve で二度詰まるのを防ぐ)
// - 空マップに握りつぶされない (「投稿が見つかりません」誤表示を防ぐ)
// ことを検証する。実タイマーは使わず、MockClient から TimeoutException を
// 投げて伝播経路だけを確認する。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:kurage/services/mastodon_api.dart' as api;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int v1RequestCount;
  late int v2RequestCount;

  tearDown(() {
    api.httpClient = http.Client();
  });

  test('v2 検索のタイムアウトは v1 にフォールバックせず伝播する', () async {
    v1RequestCount = 0;
    v2RequestCount = 0;
    api.httpClient = MockClient((request) {
      final path = request.url.path;
      if (path.contains('/api/v2/search')) {
        v2RequestCount++;
        throw TimeoutException('search timed out');
      }
      if (path.contains('/api/v1/search')) {
        v1RequestCount++;
        return Future.value(http.Response('{}', 200));
      }
      return Future.value(http.Response('', 404));
    });

    await expectLater(
      api.searchContent(
        instanceUrl: 'https://example.test',
        accessToken: 'token',
        query: 'https://remote.test/@user/1',
        type: 'statuses',
        resolve: true,
        limit: 1,
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(v2RequestCount, 1);
    expect(v1RequestCount, 0,
        reason: 'タイムアウト時に v1 へフォールバックすると同じ resolve で二度詰まる');
  });

  test('v1 フォールバック中のタイムアウトも空マップに握りつぶさず伝播する', () async {
    v1RequestCount = 0;
    api.httpClient = MockClient((request) {
      final path = request.url.path;
      if (path.contains('/api/v2/search')) {
        // v2 非対応サーバとして v1 フォールバックへ誘導
        return Future.value(http.Response('', 404));
      }
      if (path.contains('/api/v1/search')) {
        v1RequestCount++;
        throw TimeoutException('search timed out');
      }
      return Future.value(http.Response('', 404));
    });

    await expectLater(
      api.searchContent(
        instanceUrl: 'https://example.test',
        accessToken: 'token',
        query: 'https://remote.test/@user/1',
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(v1RequestCount, 1);
  });

  test('v2 の一般エラーは従来どおり v1 へフォールバックする', () async {
    v1RequestCount = 0;
    api.httpClient = MockClient((request) {
      final path = request.url.path;
      if (path.contains('/api/v2/search')) {
        return Future.value(http.Response('', 500));
      }
      if (path.contains('/api/v1/search')) {
        v1RequestCount++;
        return Future.value(http.Response(
          '{"statuses": [], "accounts": [], "hashtags": []}',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ));
      }
      return Future.value(http.Response('', 404));
    });

    final result = await api.searchContent(
      instanceUrl: 'https://example.test',
      accessToken: 'token',
      query: 'query',
    );
    expect(v1RequestCount, 1);
    expect(result['statuses'], isEmpty);
  });
}
