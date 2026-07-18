// Announcement (サーバお知らせ) のパースのテスト。
//
// published_at / updated_at は v4 で必須だが、古いサーバ互換のため
// published_at → updated_at → now の 2 段フォールバックがある。
// now フォールバックは差分 5 秒許容で検証する。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/announcement.dart';

Map<String, dynamic> _announcementJson({Map<String, dynamic> extra = const {}}) =>
    {
      'id': 'a1',
      'content': '<p>お知らせ</p>',
      ...extra,
    };

void main() {
  group('Announcement.fromJson', () {
    test('id が JSON int でも文字列に正規化される', () {
      final a = Announcement.fromJson(_announcementJson(extra: {'id': 42}));
      expect(a.id, '42');
    });

    test('content 欠落 → 空文字 / read 欠落 → false', () {
      final a = Announcement.fromJson({'id': 'a1'});
      expect(a.content, '');
      expect(a.read, false);
      expect(a.emojis, isEmpty);
      expect(a.reactions, isEmpty);
    });

    test('starts_at / ends_at: null・空文字・不正文字列はいずれも null', () {
      final a = Announcement.fromJson(_announcementJson(extra: {
        'starts_at': null,
        'ends_at': '',
      }));
      expect(a.startsAt, isNull);
      expect(a.endsAt, isNull);

      final b = Announcement.fromJson(
          _announcementJson(extra: {'starts_at': 'not-a-date'}));
      expect(b.startsAt, isNull);
    });

    test('published_at があればそのまま使う', () {
      final a = Announcement.fromJson(_announcementJson(extra: {
        'published_at': '2026-01-10T00:00:00.000Z',
        'updated_at': '2026-01-11T00:00:00.000Z',
      }));
      expect(a.publishedAt, DateTime.parse('2026-01-10T00:00:00.000Z'));
      expect(a.updatedAt, DateTime.parse('2026-01-11T00:00:00.000Z'));
    });

    test('published_at 欠落時は updated_at にフォールバックする', () {
      final a = Announcement.fromJson(_announcementJson(extra: {
        'updated_at': '2026-01-11T00:00:00.000Z',
      }));
      expect(a.publishedAt, DateTime.parse('2026-01-11T00:00:00.000Z'));
    });

    test('published_at / updated_at 両方欠落時は now にフォールバックする', () {
      final a = Announcement.fromJson(_announcementJson());
      expect(
        a.publishedAt.difference(DateTime.now()).abs(),
        lessThan(const Duration(seconds: 5)),
      );
      expect(
        a.updatedAt.difference(DateTime.now()).abs(),
        lessThan(const Duration(seconds: 5)),
      );
    });
  });

  group('Announcement.listFromJson', () {
    test('JSON 配列文字列をデコードしてリストを返す', () {
      final list = Announcement.listFromJson(
          '[{"id": "a1", "content": "x"}, {"id": "a2", "content": "y"}]');
      expect(list, hasLength(2));
      expect(list.first.id, 'a1');
      expect(list.last.content, 'y');
    });
  });

  group('AnnouncementReaction.fromJson', () {
    test('count が num → toInt / 欠落 → 0、me 欠落 → false', () {
      final r = AnnouncementReaction.fromJson({'name': '👍', 'count': 3.0});
      expect(r.count, 3);
      expect(r.me, false);
      expect(r.url, isNull);
      expect(r.staticUrl, isNull);

      final empty = AnnouncementReaction.fromJson({'name': '🎉'});
      expect(empty.count, 0);
    });

    test('カスタム絵文字リアクションは url / static_url を保持する', () {
      final r = AnnouncementReaction.fromJson({
        'name': 'party',
        'count': 1,
        'me': true,
        'url': 'https://example.com/party.gif',
        'static_url': 'https://example.com/party.png',
      });
      expect(r.me, true);
      expect(r.url, 'https://example.com/party.gif');
      expect(r.staticUrl, 'https://example.com/party.png');
    });
  });
}
