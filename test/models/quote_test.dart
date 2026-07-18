// Quote (Mastodon 4.4+ 公式引用) のパースと state マッピングのテスト。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/quote.dart';

void main() {
  group('QuoteState.fromString', () {
    const cases = <String, QuoteState>{
      'pending': QuoteState.pending,
      'accepted': QuoteState.accepted,
      'rejected': QuoteState.rejected,
      'revoked': QuoteState.revoked,
      'deleted': QuoteState.deleted,
      'unauthorized': QuoteState.unauthorized,
    };

    cases.forEach((raw, expected) {
      test('"$raw" → $expected', () {
        expect(QuoteState.fromString(raw), expected);
      });
    });

    test('null / 未知の文字列は unknown にフォールバックする', () {
      expect(QuoteState.fromString(null), QuoteState.unknown);
      expect(QuoteState.fromString('future_state'), QuoteState.unknown);
    });
  });

  group('Quote.fromJson', () {
    test('shallow quote (quoted_status null) は id だけ保持する', () {
      final quote = Quote.fromJson({
        'state': 'pending',
        'quoted_status_id': 's1',
        'quoted_status_account_id': 'a1',
      });
      expect(quote.state, QuoteState.pending);
      expect(quote.quotedStatus, isNull);
      expect(quote.quotedStatusId, 's1');
      expect(quote.quotedStatusAccountId, 'a1');
    });

    test('accepted で quoted_status の実体をパースする', () {
      final quote = Quote.fromJson({
        'state': 'accepted',
        'quoted_status': {
          'id': 's1',
          'content': '引用元投稿',
          'created_at': '2026-01-15T10:00:00.000Z',
          'account': {
            'id': '1',
            'username': 'alice',
            'display_name': 'Alice',
            'created_at': '2024-01-01T00:00:00.000Z',
          },
        },
      });
      expect(quote.state, QuoteState.accepted);
      expect(quote.quotedStatus!.id, 's1');
      expect(quote.quotedStatus!.account.username, 'alice');
    });
  });

  group('QuoteState.displayLabel', () {
    test('全 state に対応する文言を返す (accepted は空)', () {
      expect(QuoteState.pending.displayLabel, '承認待ち');
      expect(QuoteState.rejected.displayLabel, '引用が拒否されました');
      expect(QuoteState.revoked.displayLabel, '引用が取り消されました');
      expect(QuoteState.deleted.displayLabel, '引用元は削除されました');
      expect(QuoteState.unauthorized.displayLabel,
          'この投稿を閲覧する権限がありません');
      expect(QuoteState.accepted.displayLabel, '');
      expect(QuoteState.unknown.displayLabel, '引用元を表示できません');
    });
  });
}
