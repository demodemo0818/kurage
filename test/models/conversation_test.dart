// Conversation (DM 会話) のパースと派生プロパティのテスト。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/conversation.dart';

Map<String, dynamic> _accountJson({
  String id = '1',
  String username = 'alice',
  String displayName = 'Alice',
}) =>
    {
      'id': id,
      'username': username,
      'display_name': displayName,
      'created_at': '2024-01-01T00:00:00.000Z',
      'avatar': 'https://example.com/$username.png',
    };

Map<String, dynamic> _conversationJson({
  List<Map<String, dynamic>>? accounts,
  Map<String, dynamic>? lastStatus,
  bool? unread,
}) =>
    {
      'id': 'c1',
      if (unread != null) 'unread': unread,
      if (accounts != null) 'accounts': accounts,
      if (lastStatus != null) 'last_status': lastStatus,
    };

void main() {
  group('Conversation.fromJson', () {
    test('unread 欠落 → false / accounts 欠落 → [] / last_status 欠落 → null',
        () {
      final conv = Conversation.fromJson(_conversationJson());
      expect(conv.unread, false);
      expect(conv.accounts, isEmpty);
      expect(conv.lastStatus, isNull);
      expect(conv.lastMessageTime, isNull);
    });

    test('last_status ありで Status がパースされ lastMessageTime と一致する',
        () {
      final conv = Conversation.fromJson(_conversationJson(
        unread: true,
        accounts: [_accountJson()],
        lastStatus: {
          'id': 's1',
          'content': 'こんにちは',
          'created_at': '2026-01-15T10:00:00.000Z',
          'account': _accountJson(),
        },
      ));
      expect(conv.unread, true);
      expect(conv.lastStatus!.id, 's1');
      expect(
          conv.lastMessageTime, DateTime.parse('2026-01-15T10:00:00.000Z'));
    });
  });

  group('participantNames', () {
    test('参加者なしは「不明」', () {
      final conv = Conversation.fromJson(_conversationJson());
      expect(conv.participantNames, '不明');
    });

    test('displayName 空なら username を使う', () {
      final conv = Conversation.fromJson(_conversationJson(
        accounts: [_accountJson(displayName: '')],
      ));
      expect(conv.participantNames, 'alice');
    });

    test('複数参加者はカンマ区切りで結合する', () {
      final conv = Conversation.fromJson(_conversationJson(accounts: [
        _accountJson(),
        _accountJson(id: '2', username: 'bob', displayName: 'Bob'),
      ]));
      expect(conv.participantNames, 'Alice, Bob');
    });
  });

  group('participantAvatarUrl', () {
    test('参加者なしは空文字、ありは最初の参加者のアバター', () {
      expect(
          Conversation.fromJson(_conversationJson()).participantAvatarUrl, '');
      final conv = Conversation.fromJson(
          _conversationJson(accounts: [_accountJson()]));
      expect(conv.participantAvatarUrl, 'https://example.com/alice.png');
    });
  });

  group('copyWith', () {
    test('指定フィールドのみ差し替え、sourceAccountId を保持する', () {
      final conv = Conversation.fromJson(_conversationJson(unread: true));
      conv.sourceAccountId = 'acc1';
      final copied = conv.copyWith(unread: false);
      expect(copied.unread, false);
      expect(copied.id, 'c1');
      expect(copied.sourceAccountId, 'acc1');
    });
  });
}
