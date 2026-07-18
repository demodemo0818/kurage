// AuthNotifier.upsertAccount の unit test。
//
// 再ログイン (同一サーバ・同一 ID) で重複登録せず置換すること、
// および別インスタンスの偶然の ID 一致を誤置換しないことを検証する。
// 重複登録を許すと通知 SSE が同一アカウントに 2 本張られて
// 通知が二重表示になる (notifications_provider 側の回帰の温床)。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kurage/models/auth_account.dart';
import 'package:kurage/providers/auth_provider.dart';

AuthAccount _acct({
  String id = 'id-1',
  String instanceUrl = 'https://example.test',
  String accessToken = 'token-old',
  String username = 'alice',
  Color? accountColor,
}) =>
    AuthAccount(
      id: id,
      instanceUrl: instanceUrl,
      accessToken: accessToken,
      username: username,
      displayName: username,
      avatarUrl: '',
      accountColor: accountColor,
    );

void main() {
  test('新規アカウントは末尾に追加される', () {
    final existing = [_acct()];
    final result = AuthNotifier.upsertAccount(
      existing,
      _acct(id: 'id-2', username: 'bob', accessToken: 'token-b'),
    );
    expect(result.replaced, isFalse);
    expect(result.accounts, hasLength(2));
    expect(result.accounts.last.id, 'id-2');
  });

  test('同一サーバ・同一 ID の再ログインは追加せず置換する', () {
    final existing = [
      _acct(accountColor: Colors.teal),
      _acct(id: 'id-2', username: 'bob'),
    ];
    final result = AuthNotifier.upsertAccount(
      existing,
      _acct(accessToken: 'token-new', accountColor: Colors.red),
    );
    expect(result.replaced, isTrue);
    expect(result.accounts, hasLength(2), reason: '再ログインで重複登録された');
    // 位置と色は維持、トークンは新しいものに更新
    expect(result.accounts.first.id, 'id-1');
    expect(result.accounts.first.accessToken, 'token-new');
    expect(result.accounts.first.accountColor, Colors.teal,
        reason: 'ユーザーが割り当てた色は再ログインで失われない');
  });

  test('別インスタンスの同一 ID は別アカウントとして追加する', () {
    final existing = [_acct()];
    final result = AuthNotifier.upsertAccount(
      existing,
      _acct(instanceUrl: 'https://other.test', accessToken: 'token-other'),
    );
    expect(result.replaced, isFalse);
    expect(result.accounts, hasLength(2),
        reason: 'サーバローカル ID の偶然一致で誤置換された');
  });

  test('旧アカウントに色が無ければ新しい色を採用する', () {
    final existing = [_acct(accountColor: null)];
    final result = AuthNotifier.upsertAccount(
      existing,
      _acct(accessToken: 'token-new', accountColor: Colors.blue),
    );
    expect(result.replaced, isTrue);
    expect(result.accounts.first.accountColor, Colors.blue);
  });
}
