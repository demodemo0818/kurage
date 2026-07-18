// StatusEdit (投稿編集履歴の 1 バージョン) のパースのテスト。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/status_edit.dart';

Map<String, dynamic> _accountJson() => {
      'id': '1',
      'username': 'alice',
      'display_name': 'Alice',
      'created_at': '2024-01-01T00:00:00.000Z',
    };

void main() {
  group('StatusEdit.fromJson', () {
    test('最小 JSON でデフォルト値にフォールバックする', () {
      final edit = StatusEdit.fromJson({
        'created_at': '2026-01-15T10:00:00.000Z',
        'account': _accountJson(),
      });
      expect(edit.createdAt, DateTime.parse('2026-01-15T10:00:00.000Z'));
      expect(edit.content, '');
      expect(edit.spoilerText, '');
      expect(edit.sensitive, false);
      expect(edit.mediaAttachments, isEmpty);
      expect(edit.poll, isNull);
      expect(edit.emojis, isEmpty);
      expect(edit.account.username, 'alice');
    });

    test('poll / media / emojis 入りのバージョンをパースできる', () {
      final edit = StatusEdit.fromJson({
        'created_at': '2026-01-15T10:00:00.000Z',
        'content': '<p>編集後</p>',
        'spoiler_text': 'CW',
        'sensitive': true,
        'account': _accountJson(),
        'media_attachments': [
          {
            'id': 'm1',
            'type': 'image',
            'url': 'https://example.com/img.png',
          },
        ],
        'poll': {
          'id': 'p1',
          'expires_at': '2026-01-16T00:00:00.000Z',
          'expired': false,
          'multiple': false,
          'voters_count': 0,
          'options': [
            {'title': 'A'},
          ],
        },
        'emojis': [
          {'shortcode': 'party', 'url': 'https://example.com/party.gif'},
        ],
      });
      expect(edit.content, '<p>編集後</p>');
      expect(edit.spoilerText, 'CW');
      expect(edit.sensitive, true);
      expect(edit.mediaAttachments.single.id, 'm1');
      expect(edit.poll!.id, 'p1');
      expect(edit.emojis.single.shortcode, 'party');
    });
  });
}
