// Account のパース・フォールバックのテスト。
//
// Misskey 系サーバは `display_name` を null で返し、Pleroma/Akkoma 系は
// ID を JSON int で返すことがある。1 アカウントのパース失敗がタイムライン
// 全体を巻き込むため、null / 欠落 / 数値 ID への耐性を固定する。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/account.dart';

Map<String, dynamic> _accountJson({
  String username = 'alice',
  String displayName = 'Alice',
  Map<String, dynamic> extra = const {},
}) =>
    {
      'id': '1',
      'username': username,
      'display_name': displayName,
      'created_at': '2024-01-01T00:00:00.000Z',
      ...extra,
    };

void main() {
  group('Account.fromJson', () {
    test('acct 欠落時は username にフォールバックする', () {
      final account = Account.fromJson(_accountJson());
      expect(account.acct, 'alice');
    });

    test('acct があればそのまま使う', () {
      final account = Account.fromJson(
          _accountJson(extra: {'acct': 'alice@example.com'}));
      expect(account.acct, 'alice@example.com');
    });

    test('display_name 空文字時は username にフォールバックする', () {
      final account = Account.fromJson(_accountJson(displayName: ''));
      expect(account.displayName, 'alice');
    });

    test('avatar_static を avatar より優先する (header も同様)', () {
      final account = Account.fromJson(_accountJson(extra: {
        'avatar': 'https://example.com/animated.gif',
        'avatar_static': 'https://example.com/static.png',
        'header': 'https://example.com/header.gif',
        'header_static': 'https://example.com/header.png',
      }));
      expect(account.avatarUrl, 'https://example.com/static.png');
      expect(account.headerUrl, 'https://example.com/header.png');
    });

    test('avatar_static 無しは avatar、両方無しは空文字', () {
      final withAvatar = Account.fromJson(
          _accountJson(extra: {'avatar': 'https://example.com/a.png'}));
      expect(withAvatar.avatarUrl, 'https://example.com/a.png');

      final without = Account.fromJson(_accountJson());
      expect(without.avatarUrl, '');
      expect(without.headerUrl, '');
    });

    test('display_name が null (Misskey 系) でも username にフォールバックする', () {
      final json = _accountJson();
      json['display_name'] = null;
      final account = Account.fromJson(json);
      expect(account.displayName, 'alice');
    });

    test('display_name キー欠落でも username にフォールバックする', () {
      final json = _accountJson();
      json.remove('display_name');
      final account = Account.fromJson(json);
      expect(account.displayName, 'alice');
    });

    test('数値 ID (Pleroma/Akkoma 系) を文字列に正規化する', () {
      final json = _accountJson();
      json['id'] = 12345;
      final account = Account.fromJson(json);
      expect(account.id, '12345');
    });

    test('created_at が null / 不正でもクラッシュしない', () {
      final json = _accountJson();
      json['created_at'] = null;
      expect(() => Account.fromJson(json), returnsNormally);

      json['created_at'] = 'not-a-date';
      expect(() => Account.fromJson(json), returnsNormally);
    });

    test('counts / locked / bot / url / note / fields のデフォルト', () {
      final account = Account.fromJson(_accountJson());
      expect(account.followersCount, 0);
      expect(account.followingCount, 0);
      expect(account.statusesCount, 0);
      expect(account.locked, false);
      expect(account.bot, false);
      expect(account.url, '');
      expect(account.note, '');
      expect(account.fields, isEmpty);
      expect(account.emojis, isEmpty);
    });
  });

  group('Account.copyWith', () {
    test('指定したフィールドだけ差し替え、他は保持する', () {
      final account = Account.fromJson(_accountJson());
      final copied = account.copyWith(acct: 'alice@origin.example');
      expect(copied.acct, 'alice@origin.example');
      expect(copied.id, account.id);
      expect(copied.username, account.username);
      expect(copied.displayName, account.displayName);
      expect(copied.createdAt, account.createdAt);
    });
  });

  group('getter', () {
    test('displayNameOrUsername は displayName 優先', () {
      final account = Account.fromJson(_accountJson());
      expect(account.displayNameOrUsername, 'Alice');
    });

    test('avatarStatic / avatar は avatarUrl のエイリアス', () {
      final account = Account.fromJson(
          _accountJson(extra: {'avatar': 'https://example.com/a.png'}));
      expect(account.avatarStatic, account.avatarUrl);
      expect(account.avatar, account.avatarUrl);
    });
  });
}
