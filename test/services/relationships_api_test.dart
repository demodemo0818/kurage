// fetchRelationships / fetchRelationship の HTTP 組み立てのテスト。
//
// フォロー中 / フォロワー一覧の各行にフォローボタンを出すため、relationship は
// 1 件ずつではなくまとめて取る。ここで押さえたい回帰は 3 つ:
//  - クエリキーは `id[]` (`ids[]` では Mastodon が無視して全件空で返る)
//  - id 数がサーバ上限を超えないよう複数リクエストに分割する
//  - 戻り値が accountId キーの Map になっている (行と突き合わせるため)
//
// `httpClient` を MockClient に差し替えて検証する (Hive は触らない関数群なので
// Hive 初期化は不要)。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kurage/services/mastodon_api.dart';

void main() {
  const base = 'https://ex.com';
  const token = 'tok';

  // 送られた全リクエストを到着順に記録する。
  late List<http.Request> captured;

  /// リクエストに含まれる id[] をそのまま echo するように振る舞う MockClient。
  void mockEcho() {
    captured = [];
    httpClient = MockClient((req) async {
      captured.add(req);
      final ids = req.url.queryParametersAll['id[]'] ?? const <String>[];
      return http.Response(
        jsonEncode([
          for (final id in ids) {'id': id, 'following': true},
        ]),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  }

  tearDown(() {
    httpClient = http.Client();
  });

  test('fetchRelationships は id[] を繰り返して 1 回で投げる', () async {
    mockEcho();
    final rels = await fetchRelationships(
      instanceUrl: base,
      accessToken: token,
      accountIds: ['1', '2', '3'],
    );

    expect(captured.length, 1);
    expect(captured.single.method, 'GET');
    expect(captured.single.url.path, '/api/v1/accounts/relationships');
    expect(captured.single.url.queryParametersAll['id[]'], ['1', '2', '3']);
    expect(captured.single.headers['Authorization'], 'Bearer $token');
    // accountId キーの Map になっている
    expect(rels.keys.toSet(), {'1', '2', '3'});
    expect(rels['2']!.following, true);
  });

  test('上限を超える件数はチャンク分割され、結果はマージされる', () async {
    mockEcho();
    final ids = List.generate(41, (i) => 'a$i');
    final rels = await fetchRelationships(
      instanceUrl: base,
      accessToken: token,
      accountIds: ids,
    );

    expect(captured.length, 2);
    expect(captured[0].url.queryParametersAll['id[]']!.length, 40);
    expect(captured[1].url.queryParametersAll['id[]'], ['a40']);
    expect(rels.length, 41);
    expect(rels['a40'], isNotNull);
  });

  test('空リストなら HTTP を叩かず空 Map を返す', () async {
    mockEcho();
    final rels = await fetchRelationships(
      instanceUrl: base,
      accessToken: token,
      accountIds: const [],
    );
    expect(captured, isEmpty);
    expect(rels, isEmpty);
  });

  test('id を返さないサーバでも返却順で要求 ID に対応づける', () async {
    // 一部の派生実装は relationship に id を載せてこない。ここで拾えないと
    // 単数取得の fetchRelationship が throw してプロフィール表示ごと落ちる。
    captured = [];
    httpClient = MockClient((req) async {
      captured.add(req);
      return http.Response(
        jsonEncode([
          {'following': true},
          {'following': false},
        ]),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final rels = await fetchRelationships(
      instanceUrl: base,
      accessToken: token,
      accountIds: ['9', '10'],
    );
    expect(rels.keys.toSet(), {'9', '10'});
    expect(rels['9']!.following, true);
    expect(rels['10']!.following, false);
  });

  test('fetchRelationship (単数) は該当 ID の Relationship を返す', () async {
    mockEcho();
    final rel = await fetchRelationship(
      instanceUrl: base,
      accessToken: token,
      accountId: '5',
    );
    expect(captured.single.url.queryParametersAll['id[]'], ['5']);
    expect(rel.id, '5');
    expect(rel.following, true);
  });
}
