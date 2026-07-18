// AnnualReport (Wrapstodon, Mastodon 4.6+) の寛容パースのテスト。
//
// data の内訳 (time_series / top_hashtags / top_statuses) は生のまま保持し、
// 未知フィールドやスキーマ変更で落とさないことを守る。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/annual_report.dart';

void main() {
  group('AnnualReport.fromJson', () {
    test('data の内訳を生のまま保持する', () {
      final r = AnnualReport.fromJson({
        'year': 2025,
        'schema_version': 3,
        'account_id': '99',
        'share_url': 'https://ex.com/wrap/2025',
        'data': {
          'archetype': 'lurker',
          'time_series': [
            {'month': 1, 'statuses': 10, 'followers': 2},
            {'month': 2, 'statuses': 5, 'followers': 1},
          ],
          'top_hashtags': [
            {'name': 'flutter', 'count': 7},
          ],
          'top_statuses': {'by_reblogs': '123', 'by_favourites': '456'},
          // 未知フィールドも raw に残る
          'most_used_apps': ['Kurage'],
        },
      });

      expect(r.year, 2025);
      expect(r.schemaVersion, 3);
      expect(r.accountId, '99');
      expect(r.shareUrl, 'https://ex.com/wrap/2025');
      expect(r.data.archetype, 'lurker');
      expect(r.data.timeSeries, hasLength(2));
      expect(r.data.timeSeries.first['statuses'], 10);
      expect(r.data.topHashtags.first['name'], 'flutter');
      expect(r.data.topStatuses['by_reblogs'], '123');
      // 未知フィールドは raw に保持される
      expect(r.data.raw['most_used_apps'], ['Kurage']);
    });

    test('data 欠落でも空のデフォルトで壊れない', () {
      final r = AnnualReport.fromJson({'year': 2024});
      expect(r.year, 2024);
      expect(r.data.archetype, '');
      expect(r.data.timeSeries, isEmpty);
      expect(r.data.topHashtags, isEmpty);
      expect(r.data.topStatuses, isEmpty);
      expect(r.accountId, isNull);
    });
  });

  group('AnnualReport.listFromResponse', () {
    test('封筒形式 (annual_reports キー) から取り出す', () {
      final list = AnnualReport.listFromResponse({
        'annual_reports': [
          {'year': 2025, 'data': {}},
          {'year': 2024, 'data': {}},
        ],
        'accounts': [],
        'statuses': [],
      });
      expect(list.map((r) => r.year), [2025, 2024]);
    });

    test('生配列でも取り出せる', () {
      final list = AnnualReport.listFromResponse([
        {'year': 2025, 'data': {}},
      ]);
      expect(list.single.year, 2025);
    });

    test('想定外の型は空リスト', () {
      expect(AnnualReport.listFromResponse('変な値'), isEmpty);
      expect(AnnualReport.listFromResponse(null), isEmpty);
    });
  });
}
