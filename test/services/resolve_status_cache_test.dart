// resolveStatusOnInstanceCached のキャッシュ挙動テスト。
//
// リモートビュー (プロフィールの「相手サーバーから読み込む」等) の投稿への
// リアクションは、実行のたびに URL → ホーム側 status ID の解決 (search
// resolve=true、サーバ側のリモート fetch を伴い遅い) が必要になる。
// 同じ投稿への 2 回目以降のアクションで search を再発行しないこと、および
// 解決失敗 (未連合など) はキャッシュされず再試行されることを検証する。

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:kurage/services/mastodon_api.dart' as api;

/// v2 search レスポンスに載せる最小の status JSON。
/// Status.fromJson は account 以外ほぼ optional (`asIdString` / `??` で防御)。
String _searchResponse(String localId) =>
    '{"accounts": [], "hashtags": [], "statuses": ['
    '{"id": "$localId", "account": {"id": "1", "username": "alice"}}'
    ']}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    api.httpClient = http.Client();
    api.clearResolvedStatusIdCacheForTest();
  });

  test('成功した解決はキャッシュされ 2 回目は search を発行しない', () async {
    api.clearResolvedStatusIdCacheForTest();
    var searchCount = 0;
    api.httpClient = MockClient((request) {
      if (request.url.path.contains('/api/v2/search')) {
        searchCount++;
        return Future.value(http.Response(
          _searchResponse('9999'),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ));
      }
      return Future.value(http.Response('', 404));
    });

    final first = await api.resolveStatusOnInstanceCached(
      instanceUrl: 'https://home.test',
      accessToken: 'token',
      originalStatusUrl: 'https://remote.test/@bob/12345',
    );
    expect(first, '9999');
    expect(searchCount, 1);

    final second = await api.resolveStatusOnInstanceCached(
      instanceUrl: 'https://home.test',
      accessToken: 'token',
      originalStatusUrl: 'https://remote.test/@bob/12345',
    );
    expect(second, '9999');
    expect(searchCount, 1, reason: '2 回目はキャッシュヒットで search を飛ばさない');
  });

  test('インスタンスが異なれば別エントリとして解決する', () async {
    api.clearResolvedStatusIdCacheForTest();
    var searchCount = 0;
    api.httpClient = MockClient((request) {
      if (request.url.path.contains('/api/v2/search')) {
        searchCount++;
        return Future.value(http.Response(
          _searchResponse('$searchCount'),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ));
      }
      return Future.value(http.Response('', 404));
    });

    final a = await api.resolveStatusOnInstanceCached(
      instanceUrl: 'https://home-a.test',
      accessToken: 'token',
      originalStatusUrl: 'https://remote.test/@bob/12345',
    );
    final b = await api.resolveStatusOnInstanceCached(
      instanceUrl: 'https://home-b.test',
      accessToken: 'token',
      originalStatusUrl: 'https://remote.test/@bob/12345',
    );
    expect(a, '1');
    expect(b, '2', reason: '同じ URL でもインスタンスごとにローカル ID は異なる');
    expect(searchCount, 2);
  });

  test('解決失敗 (statuses 空) はキャッシュされず毎回再試行する', () async {
    api.clearResolvedStatusIdCacheForTest();
    var searchCount = 0;
    api.httpClient = MockClient((request) {
      if (request.url.path.contains('/api/v2/search')) {
        searchCount++;
        // 1〜2 回目: 未連合等で解決できない。3 回目: 連合が追いついて成功。
        if (searchCount < 3) {
          return Future.value(http.Response(
            '{"accounts": [], "hashtags": [], "statuses": []}',
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));
        }
        return Future.value(http.Response(
          _searchResponse('7777'),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ));
      }
      return Future.value(http.Response('', 404));
    });

    const url = 'https://remote.test/@carol/555';
    final first = await api.resolveStatusOnInstanceCached(
      instanceUrl: 'https://home.test',
      accessToken: 'token',
      originalStatusUrl: url,
    );
    expect(first, isNull);

    final second = await api.resolveStatusOnInstanceCached(
      instanceUrl: 'https://home.test',
      accessToken: 'token',
      originalStatusUrl: url,
    );
    expect(second, isNull);
    expect(searchCount, 2, reason: '失敗は null キャッシュせず再試行する');

    final third = await api.resolveStatusOnInstanceCached(
      instanceUrl: 'https://home.test',
      accessToken: 'token',
      originalStatusUrl: url,
    );
    expect(third, '7777', reason: '後から連合が追いつけば成功に転じる');
    expect(searchCount, 3);
  });
}
