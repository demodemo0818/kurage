// プッシュ通知の Android tag (宛先アカウント識別) のテスト。
//
// アプリ内で既読にした時、表示中アカウント宛てのトレイ通知だけを tag で
// 判別して消す。表示時と削除時で同じ値にならないと消えないので、決定的で
// あること・アカウントごとに異なること・トークンを漏らさないことを固定する。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/services/push_notification_service.dart';

void main() {
  group('pushNotificationTagForToken', () {
    test('同じトークンからは常に同じ tag になる', () {
      expect(pushNotificationTagForToken('token-a'),
          pushNotificationTagForToken('token-a'));
    });

    test('トークンが違えば tag も違う', () {
      expect(pushNotificationTagForToken('token-a'),
          isNot(pushNotificationTagForToken('token-b')));
    });

    test('トークンそのものを含まない (acct_ + 16 桁の 16 進)', () {
      const token = 'secret-access-token';
      final tag = pushNotificationTagForToken(token);
      expect(tag, matches(RegExp(r'^acct_[0-9a-f]{16}$')));
      expect(tag, isNot(contains(token)));
    });
  });
}
