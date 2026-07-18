// Collection / CollectionItem (Mastodon 4.6+) のパースのテスト。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/collection.dart';

void main() {
  group('Collection.fromJson', () {
    test('全フィールド入り (items / tag 含む) をパースできる', () {
      final c = Collection.fromJson({
        'id': '10',
        'account_id': '99',
        'uri': 'https://ex.com/collections/10',
        'url': 'https://ex.com/@me/collections/10',
        'name': 'お気に入り作家',
        'description': '小説書きの人たち',
        'language': 'ja',
        'local': true,
        'sensitive': false,
        'discoverable': true,
        'tag': {'name': 'novel', 'url': 'https://ex.com/tags/novel'},
        'item_count': 2,
        'items': [
          {
            'id': 'i1',
            'account_id': 'a1',
            'state': 'accepted',
            'created_at': '2026-01-01T00:00:00.000Z',
          },
          {
            'id': 'i2',
            'account_id': 'a2',
            'state': 'pending',
            'created_at': '2026-01-02T00:00:00.000Z',
          },
        ],
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-03T00:00:00.000Z',
      });

      expect(c.id, '10');
      expect(c.accountId, '99');
      expect(c.name, 'お気に入り作家');
      expect(c.language, 'ja');
      expect(c.local, true);
      expect(c.discoverable, true);
      expect(c.tag?.name, 'novel');
      expect(c.itemCount, 2);
      expect(c.items, hasLength(2));
      expect(c.items[0].isPending, false);
      expect(c.items[1].isPending, true);
      expect(c.updatedAt, DateTime.parse('2026-01-03T00:00:00.000Z'));
    });

    test('items / tag が無い一覧レスポンス形でも壊れない', () {
      final c = Collection.fromJson({
        'id': '5',
        'account_id': '1',
        'name': 'リスト',
        'created_at': '2026-01-01T00:00:00.000Z',
      });
      expect(c.items, isEmpty);
      expect(c.tag, isNull);
      expect(c.itemCount, 0);
      // updated_at 欠落時は created_at に倒れる
      expect(c.updatedAt, DateTime.parse('2026-01-01T00:00:00.000Z'));
    });

    test('数値 id (派生サーバ) も文字列へ正規化', () {
      final c = Collection.fromJson({
        'id': 10,
        'account_id': 99,
        'created_at': '2026-01-01T00:00:00.000Z',
      });
      expect(c.id, '10');
      expect(c.accountId, '99');
    });
  });

  group('Collection.listFromJson', () {
    test('配列をパースし、非 Map 要素は無視する', () {
      final list = Collection.listFromJson([
        {
          'id': '1',
          'account_id': '1',
          'created_at': '2026-01-01T00:00:00.000Z',
        },
        'ゴミ',
        {
          'id': '2',
          'account_id': '1',
          'created_at': '2026-01-01T00:00:00.000Z',
        },
      ]);
      expect(list.map((c) => c.id), ['1', '2']);
    });
  });

  group('CollectionItem.fromJson', () {
    test('state 欠落時は accepted 扱い', () {
      final item = CollectionItem.fromJson({
        'id': 'i1',
        'account_id': 'a1',
        'created_at': '2026-01-01T00:00:00.000Z',
      });
      expect(item.state, 'accepted');
      expect(item.isPending, false);
    });
  });
}
