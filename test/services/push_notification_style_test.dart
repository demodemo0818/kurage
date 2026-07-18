// pushStyleForType (プッシュ通知の種別 → 絵文字/チャンネル/色マッピング) のテスト。
// 純粋 Dart ロジックなのでプラグイン初期化なしに検証できる。

import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/services/push_notification_style.dart';

void main() {
  group('pushStyleForType', () {
    test('種別ごとに期待するチャンネルと絵文字を返す', () {
      const cases = {
        'mention': ('notif_mention', '💬'),
        'reply': ('notif_mention', '💬'),
        'quote': ('notif_mention', '🗨️'),
        'reblog': ('notif_boost', '🔁'),
        'favourite': ('notif_favourite', '⭐'),
        'emoji_reaction': ('notif_favourite', '😀'),
        'follow': ('notif_follow', '👤'),
        'follow_request': ('notif_follow', '🤝'),
        'poll': ('notif_other', '📊'),
        'status': ('notif_other', '📝'),
        'update': ('notif_other', '✏️'),
      };
      cases.forEach((raw, expected) {
        final style = pushStyleForType(raw);
        expect(style.channel.id, expected.$1, reason: raw);
        expect(style.emoji, expected.$2, reason: raw);
      });
    });

    test('null・未知の種別は「その他」チャンネル + 絵文字なし', () {
      for (final raw in [null, '', 'admin.sign_up', 'unknown_future_type']) {
        final style = pushStyleForType(raw);
        expect(style.channel.id, 'notif_other', reason: '$raw');
        expect(style.emoji, isNull, reason: '$raw');
      }
    });

    test('アクセント色がアプリ内の種別配色と揃っている', () {
      expect(pushStyleForType('favourite').color, const Color(0xFFFFC107));
      expect(pushStyleForType('reblog').color, const Color(0xFF4CAF50));
      expect(pushStyleForType('mention').color, const Color(0xFF2196F3));
      expect(pushStyleForType(null).color, const Color(0xFF6750A4));
    });
  });

  group('allPushChannels', () {
    test('5 チャンネル定義があり ID に重複がない', () {
      expect(allPushChannels, hasLength(5));
      final ids = allPushChannels.map((c) => c.id).toSet();
      expect(ids, hasLength(5));
    });

    test('全種別のチャンネルが allPushChannels に含まれる', () {
      const rawTypes = [
        'mention', 'reply', 'quote', 'reblog', 'favourite', 'emoji_reaction',
        'follow', 'follow_request', 'poll', 'status', 'update', null,
      ];
      final channelIds = allPushChannels.map((c) => c.id).toSet();
      for (final raw in rawTypes) {
        expect(channelIds, contains(pushStyleForType(raw).channel.id),
            reason: '$raw');
      }
    });
  });
}
