// Profile (GET/PATCH /api/v1/profile, Mastodon 4.6+) のパースのテスト。
//
// Account とは別モデルで、note / fields は raw text (HTML 化しない)。
// nullable な tri-state (hide_collections / discoverable) を null のまま
// 保持すること、欠落フィールドが安全なデフォルトに落ちることを守る。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/profile.dart';

void main() {
  group('Profile.fromJson', () {
    test('全フィールド入り JSON をパースできる', () {
      final p = Profile.fromJson({
        'id': '123',
        'display_name': 'Alice',
        'note': '生テキストの自己紹介 <not html>',
        'fields': [
          {
            'name': 'Web',
            'value': 'https://example.com',
            'verified_at': '2026-01-01T00:00:00.000Z',
          },
          {'name': 'メモ', 'value': '素の値'},
        ],
        'avatar': 'https://example.com/a.png',
        'avatar_static': 'https://example.com/a_s.png',
        'avatar_description': 'アバターの説明',
        'header': 'https://example.com/h.png',
        'header_static': 'https://example.com/h_s.png',
        'header_description': 'ヘッダーの説明',
        'locked': true,
        'bot': true,
        'hide_collections': true,
        'discoverable': false,
        'indexable': true,
        'show_media': true,
        'show_media_replies': true,
        'show_featured': true,
        'attribution_domains': ['example.com', 'blog.example.com'],
      });

      expect(p.id, '123');
      expect(p.displayName, 'Alice');
      // note は raw text のまま (HTML エスケープ/除去をしない)
      expect(p.note, '生テキストの自己紹介 <not html>');
      expect(p.fields, hasLength(2));
      expect(p.fields.first.name, 'Web');
      expect(p.fields.first.value, 'https://example.com');
      expect(p.fields.first.isVerified, true);
      expect(p.fields[1].isVerified, false);
      expect(p.avatarDescription, 'アバターの説明');
      expect(p.headerDescription, 'ヘッダーの説明');
      expect(p.locked, true);
      expect(p.bot, true);
      expect(p.hideCollections, true);
      expect(p.discoverable, false);
      expect(p.indexable, true);
      expect(p.showMedia, true);
      expect(p.showMediaReplies, true);
      expect(p.showFeatured, true);
      expect(p.attributionDomains, ['example.com', 'blog.example.com']);
    });

    test('欠落フィールドは安全なデフォルトに落ちる', () {
      final p = Profile.fromJson({'id': '1'});
      expect(p.displayName, '');
      expect(p.note, '');
      expect(p.fields, isEmpty);
      expect(p.avatar, '');
      expect(p.avatarDescription, isNull);
      expect(p.headerDescription, isNull);
      expect(p.locked, false);
      expect(p.bot, false);
      expect(p.indexable, false);
      expect(p.showMedia, false);
      expect(p.attributionDomains, isEmpty);
    });

    test('hide_collections / discoverable は欠落時 null (tri-state を維持)', () {
      final p = Profile.fromJson({'id': '1'});
      expect(p.hideCollections, isNull);
      expect(p.discoverable, isNull);
    });
  });
}
