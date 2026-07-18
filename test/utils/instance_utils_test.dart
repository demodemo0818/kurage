// instance_utils (インスタンス名抽出 / フルハンドル生成) のテスト。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/utils/instance_utils.dart';

void main() {
  group('extractInstanceName', () {
    test('https URL からホスト名を抽出する', () {
      expect(extractInstanceName('https://mastodon.social'), 'mastodon.social');
    });

    test('パス付き URL でもホスト名だけ返す', () {
      expect(
        extractInstanceName('https://mastodon.example.com/web/home'),
        'mastodon.example.com',
      );
    });

    test('スキーム無し文字列は Uri.parse が成功して host が空になる (現挙動)', () {
      // Uri.parse('mastodon.social') は path 扱いになり host は '' を返す。
      // 呼び出し元は常に https:// 付き instanceUrl を渡す前提。
      expect(extractInstanceName('mastodon.social'), '');
    });
  });

  group('createFullUserId', () {
    test('@user@host 形式を生成する', () {
      expect(
        createFullUserId('alice', 'https://mastodon.example.com'),
        '@alice@mastodon.example.com',
      );
    });
  });

  group('formatAcct', () {
    test('リモート acct (@ 含み) は先頭に @ を付けるだけ', () {
      expect(
        formatAcct('user@example.com', 'https://local.example'),
        '@user@example.com',
      );
    });

    test('ローカル acct はフォールバックのインスタンスを補完する', () {
      expect(
        formatAcct('localuser', 'https://local.example'),
        '@localuser@local.example',
      );
    });
  });
}
