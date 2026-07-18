// AuthAccount (マルチアカウント認証情報) のシリアライズと host 抽出のテスト。
//
// SharedPreferences['accounts'] に保存される独自フォーマット (camelCase キー)。
// accountColor は Color ↔ int (ARGB32) の変換を挟むのでラウンドトリップで固定する。

import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/auth_account.dart';

AuthAccount _account({String instanceUrl = 'https://example.com', Color? color}) =>
    AuthAccount(
      id: 'a1',
      instanceUrl: instanceUrl,
      accessToken: 'token',
      username: 'alice',
      displayName: 'Alice',
      avatarUrl: 'https://example.com/a.png',
      accountColor: color,
    );

void main() {
  group('AuthAccount.host', () {
    test('https URL からホスト部分を抽出する', () {
      expect(_account().host, 'example.com');
      expect(
          _account(instanceUrl: 'https://example.com/path').host, 'example.com');
    });

    test('スキーム無し文字列は Uri.host が空なので regex フォールバック', () {
      expect(_account(instanceUrl: 'mastodon.social').host, 'mastodon.social');
    });
  });

  group('toJson / fromJson', () {
    test('accountColor null のラウンドトリップ', () {
      final restored = AuthAccount.fromJson(_account().toJson());
      expect(restored.id, 'a1');
      expect(restored.instanceUrl, 'https://example.com');
      expect(restored.accessToken, 'token');
      expect(restored.username, 'alice');
      expect(restored.displayName, 'Alice');
      expect(restored.avatarUrl, 'https://example.com/a.png');
      expect(restored.accountColor, isNull);
    });

    test('accountColor 非 null のラウンドトリップ (ARGB32 経由)', () {
      const color = Color(0xFF6750A4);
      final json = _account(color: color).toJson();
      expect(json['accountColor'], color.toARGB32());
      final restored = AuthAccount.fromJson(json);
      expect(restored.accountColor, color);
    });
  });
}
