// Collections API (Mastodon 4.6+) の HTTP 組み立てのテスト。
//
// 各関数が正しい HTTP メソッド / パス / 必須パラメタを送ることを、
// `httpClient` を MockClient に差し替えて検証する (Hive キャッシュは
// 触らない関数群なので Hive 初期化は不要)。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kurage/services/mastodon_api.dart';

void main() {
  const base = 'https://ex.com';
  const token = 'tok';

  // 直近のリクエストを捕捉する。
  late http.Request captured;

  /// 指定ボディ / ステータスを返し、リクエストを captured に記録する MockClient。
  void mock(String body, {int status = 200}) {
    httpClient = MockClient((req) async {
      captured = req;
      return http.Response(body, status,
          headers: {'content-type': 'application/json'});
    });
  }

  tearDown(() {
    httpClient = http.Client();
  });

  String collectionJson({String id = '1'}) => jsonEncode({
        'id': id,
        'account_id': '99',
        'name': 'c',
        'created_at': '2026-01-01T00:00:00.000Z',
      });

  test('createCollection は POST /api/v1/collections に name を送る', () async {
    mock(collectionJson());
    final c = await createCollection(
      instanceUrl: base,
      accessToken: token,
      name: 'お気に入り',
      description: '説明',
      accountIds: ['a1', 'a2'],
    );
    expect(captured.method, 'POST');
    expect(captured.url.toString(), '$base/api/v1/collections');
    expect(captured.headers['Authorization'], 'Bearer $token');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['name'], 'お気に入り');
    expect(body['description'], '説明');
    expect(body['account_ids'], ['a1', 'a2']);
    expect(c.id, '1');
  });

  test('fetchCollection は GET /api/v1/collections/:id (collection + accounts ラッパー)',
      () async {
    mock(jsonEncode({
      'collection': {
        'id': '42',
        'account_id': '99',
        'name': 'c',
        'created_at': '2026-01-01T00:00:00.000Z',
        'items': [
          {
            'id': 'i1',
            'account_id': 'a1',
            'state': 'accepted',
            'created_at': '2026-01-01T00:00:00.000Z',
          },
        ],
      },
      'accounts': [
        {'id': 'a1', 'username': 'u1', 'acct': 'u1'},
      ],
    }));
    final result = await fetchCollection(
      instanceUrl: base,
      accessToken: token,
      collectionId: '42',
    );
    expect(captured.method, 'GET');
    expect(captured.url.toString(), '$base/api/v1/collections/42');
    expect(result.collection.id, '42');
    expect(result.collection.items.single.accountId, 'a1');
    expect(result.accounts.single.id, 'a1');
  });

  test('fetchCollection は bare Collection (ラッパー無し) も読める', () async {
    mock(collectionJson(id: '7'));
    final result = await fetchCollection(
      instanceUrl: base,
      accessToken: token,
      collectionId: '7',
    );
    expect(result.collection.id, '7');
    expect(result.accounts, isEmpty);
  });

  test('updateCollection は PATCH /api/v1/collections/:id', () async {
    mock(collectionJson(id: '7'));
    await updateCollection(
      instanceUrl: base,
      accessToken: token,
      collectionId: '7',
      name: '新名称',
    );
    expect(captured.method, 'PATCH');
    expect(captured.url.toString(), '$base/api/v1/collections/7');
    expect((jsonDecode(captured.body) as Map)['name'], '新名称');
  });

  test('deleteCollection は DELETE /api/v1/collections/:id', () async {
    mock('', status: 200);
    await deleteCollection(
      instanceUrl: base,
      accessToken: token,
      collectionId: '9',
    );
    expect(captured.method, 'DELETE');
    expect(captured.url.toString(), '$base/api/v1/collections/9');
  });

  test('addCollectionItem は POST .../items に account_id を送る (本文はパースしない)',
      () async {
    // 成功時に collection ラッパー等を返すサーバでも例外にしないことを担保。
    mock(jsonEncode({
      'collection': {'id': '3', 'account_id': '99'},
      'accounts': [],
    }));
    await addCollectionItem(
      instanceUrl: base,
      accessToken: token,
      collectionId: '3',
      accountId: 'a1',
    );
    expect(captured.method, 'POST');
    expect(captured.url.toString(), '$base/api/v1/collections/3/items');
    expect((jsonDecode(captured.body) as Map)['account_id'], 'a1');
  });

  test('removeCollectionItem は DELETE .../items/:item_id', () async {
    mock('', status: 200);
    await removeCollectionItem(
      instanceUrl: base,
      accessToken: token,
      collectionId: '3',
      itemId: 'i9',
    );
    expect(captured.method, 'DELETE');
    expect(captured.url.toString(), '$base/api/v1/collections/3/items/i9');
  });

  test('revokeCollectionItem は POST .../items/:item_id/revoke', () async {
    mock('', status: 200);
    await revokeCollectionItem(
      instanceUrl: base,
      accessToken: token,
      collectionId: '3',
      itemId: 'i9',
    );
    expect(captured.method, 'POST');
    expect(
        captured.url.toString(), '$base/api/v1/collections/3/items/i9/revoke');
  });

  test('acceptCollectionItem は POST .../items/:item_id/accept', () async {
    mock('', status: 200);
    await acceptCollectionItem(
      instanceUrl: base,
      accessToken: token,
      collectionId: '3',
      itemId: 'i9',
    );
    expect(captured.method, 'POST');
    expect(
        captured.url.toString(), '$base/api/v1/collections/3/items/i9/accept');
  });

  test('fetchAccountCollections は GET accounts/:id/collections に limit/offset',
      () async {
    mock('[]');
    final list = await fetchAccountCollections(
      instanceUrl: base,
      accessToken: token,
      accountId: '99',
      limit: 20,
      offset: 40,
    );
    expect(captured.method, 'GET');
    expect(captured.url.path, '/api/v1/accounts/99/collections');
    expect(captured.url.queryParameters['limit'], '20');
    expect(captured.url.queryParameters['offset'], '40');
    expect(list, isEmpty);
  });

  test('fetchAccountCollections は {collections:[...]} ラッパーを読む', () async {
    mock(jsonEncode({
      'collections': [
        {
          'id': '1',
          'account_id': '99',
          'name': 'A',
          'created_at': '2026-01-01T00:00:00.000Z',
        },
        {
          'id': '2',
          'account_id': '99',
          'name': 'B',
          'created_at': '2026-01-01T00:00:00.000Z',
        },
      ],
    }));
    final list = await fetchAccountCollections(
      instanceUrl: base,
      accessToken: token,
      accountId: '99',
    );
    expect(list.map((c) => c.id), ['1', '2']);
  });

  test('fetchAccountInCollections は GET accounts/:id/in_collections', () async {
    mock('[]');
    await fetchAccountInCollections(
      instanceUrl: base,
      accessToken: token,
      accountId: '99',
    );
    expect(captured.url.path, '/api/v1/accounts/99/in_collections');
  });

  test('fetchAccountCollections は 404 を空リストとして扱う (0 件/未対応をエラーにしない)',
      () async {
    mock('', status: 404);
    final list = await fetchAccountCollections(
      instanceUrl: base,
      accessToken: token,
      accountId: '99',
    );
    expect(list, isEmpty);
  });

  test('fetchAccountInCollections も 404 を空リストとして扱う', () async {
    mock('', status: 404);
    final list = await fetchAccountInCollections(
      instanceUrl: base,
      accessToken: token,
      accountId: '99',
    );
    expect(list, isEmpty);
  });

  test('fetchAccountsByIds は GET /api/v1/accounts に id[] を並べる', () async {
    mock(jsonEncode([
      {'id': 'a1', 'username': 'u1', 'acct': 'u1'},
      {'id': 'a2', 'username': 'u2', 'acct': 'u2'},
    ]));
    final list = await fetchAccountsByIds(
      instanceUrl: base,
      accessToken: token,
      accountIds: ['a1', 'a2'],
    );
    expect(captured.method, 'GET');
    expect(captured.url.path, '/api/v1/accounts');
    expect(captured.url.queryParametersAll['id[]'], ['a1', 'a2']);
    expect(list.map((a) => a.id), ['a1', 'a2']);
  });

  test('fetchAccountsByIds は空リストならリクエストしない', () async {
    var called = false;
    httpClient = MockClient((req) async {
      called = true;
      return http.Response('[]', 200);
    });
    final list = await fetchAccountsByIds(
      instanceUrl: base,
      accessToken: token,
      accountIds: const [],
    );
    expect(called, isFalse);
    expect(list, isEmpty);
  });
}
