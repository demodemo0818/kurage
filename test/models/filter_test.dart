// Mastodon Filters v2 (MastodonFilter ほか) のパースと失効判定のテスト。
//
// isExpired は DateTime.now() 依存なので、now からの相対オフセット
// (マージン 1 時間) で flaky にならないように組む (time_formatter_test と同方式)。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/filter.dart';

Map<String, dynamic> _filterJson({Map<String, dynamic> extra = const {}}) => {
      'id': 'f1',
      ...extra,
    };

void main() {
  group('MastodonFilter.fromJson', () {
    test('optional 欠落時のデフォルト群', () {
      final filter = MastodonFilter.fromJson(_filterJson());
      expect(filter.title, '');
      expect(filter.context, isEmpty);
      expect(filter.expiresAt, isNull);
      expect(filter.filterAction, 'warn');
      expect(filter.keywords, isEmpty);
      expect(filter.statuses, isEmpty);
    });

    test('全フィールド入り JSON をパースできる', () {
      final filter = MastodonFilter.fromJson(_filterJson(extra: {
        'title': 'ネタバレ',
        'context': ['home', 'notifications'],
        'expires_at': '2026-06-01T00:00:00.000Z',
        'filter_action': 'hide',
        'keywords': [
          {'id': 'k1', 'keyword': 'spoiler', 'whole_word': true},
        ],
        'statuses': [
          {'id': 'fs1', 'status_id': 's100'},
        ],
      }));
      expect(filter.title, 'ネタバレ');
      expect(filter.context, ['home', 'notifications']);
      expect(filter.expiresAt, DateTime.parse('2026-06-01T00:00:00.000Z'));
      expect(filter.filterAction, 'hide');
      expect(filter.keywords.single.keyword, 'spoiler');
      expect(filter.statuses.single.statusId, 's100');
    });

    test('expires_at が不正文字列なら tryParse で null になる', () {
      final filter = MastodonFilter.fromJson(
          _filterJson(extra: {'expires_at': 'not-a-date'}));
      expect(filter.expiresAt, isNull);
    });
  });

  group('MastodonFilter.isExpired', () {
    MastodonFilter filterWith(DateTime? expiresAt) => MastodonFilter(
          id: 'f1',
          title: 't',
          context: const ['home'],
          expiresAt: expiresAt,
          filterAction: 'warn',
        );

    test('過去なら true', () {
      final filter =
          filterWith(DateTime.now().subtract(const Duration(hours: 1)));
      expect(filter.isExpired, true);
    });

    test('未来なら false', () {
      final filter = filterWith(DateTime.now().add(const Duration(hours: 1)));
      expect(filter.isExpired, false);
    });

    test('null (無期限) なら false', () {
      expect(filterWith(null).isExpired, false);
    });
  });

  group('FilterKeyword.fromJson', () {
    test('whole_word 欠落 → false / keyword 欠落 → 空文字', () {
      final keyword = FilterKeyword.fromJson({'id': 'k1'});
      expect(keyword.keyword, '');
      expect(keyword.wholeWord, false);
    });
  });

  group('FilterStatus.fromJson', () {
    test('status_id 欠落 → 空文字', () {
      final status = FilterStatus.fromJson({'id': 'fs1'});
      expect(status.statusId, '');
    });
  });

  group('FilterResult.fromJson', () {
    test('keyword_matches / status_matches 欠落 → []', () {
      final result = FilterResult.fromJson({'filter': _filterJson()});
      expect(result.filter.id, 'f1');
      expect(result.keywordMatches, isEmpty);
      expect(result.statusMatches, isEmpty);
    });

    test('マッチ結果をパースできる', () {
      final result = FilterResult.fromJson({
        'filter': _filterJson(),
        'keyword_matches': ['spoiler'],
        'status_matches': ['s100'],
      });
      expect(result.keywordMatches, ['spoiler']);
      expect(result.statusMatches, ['s100']);
    });
  });
}
