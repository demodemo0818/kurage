// Poll / PollOption / PollData のパース・シリアライズのテスト。
//
// votes_count は「サーバが集計を非公開にしている (hide_totals) と null」に
// なるため、null 許容のパースを固定する。PollData.toJson は投稿 API に
// 渡すリクエストボディなので、キー名 (snake_case) が変わると投票付き投稿が
// 出来なくなる — キー名そのものを検証する。

import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/models/poll.dart';

Map<String, dynamic> _pollJson({
  int? votesCount = 10,
  bool? voted,
  List<int>? ownVotes,
  List<Map<String, dynamic>>? emojis,
}) =>
    {
      'id': 'p1',
      'expires_at': '2026-01-15T10:00:00.000Z',
      'expired': false,
      'multiple': true,
      'voters_count': 5,
      if (votesCount != null) 'votes_count': votesCount,
      if (voted != null) 'voted': voted,
      if (ownVotes != null) 'own_votes': ownVotes,
      if (emojis != null) 'emojis': emojis,
      'options': [
        {'title': '選択肢A', 'votes_count': 7},
        {'title': '選択肢B', 'votes_count': 3},
      ],
    };

void main() {
  group('Poll.fromJson', () {
    test('全フィールド入り JSON をパースできる', () {
      final poll = Poll.fromJson(_pollJson(
        voted: true,
        ownVotes: [0, 1],
        emojis: [
          {'shortcode': 'party', 'url': 'https://example.com/party.gif'},
        ],
      ));
      expect(poll.id, 'p1');
      expect(poll.expiresAt, DateTime.parse('2026-01-15T10:00:00.000Z'));
      expect(poll.expired, false);
      expect(poll.multiple, true);
      expect(poll.votersCount, 5);
      expect(poll.votesCount, 10);
      expect(poll.voted, true);
      expect(poll.ownVotes, [0, 1]);
      expect(poll.options, hasLength(2));
      expect(poll.options.first.title, '選択肢A');
      expect(poll.emojis, hasLength(1));
      expect(poll.emojis!.first.shortcode, 'party');
    });

    test('optional フィールド欠落時は null になる', () {
      final poll = Poll.fromJson(_pollJson(votesCount: null));
      expect(poll.votesCount, isNull);
      expect(poll.voted, isNull);
      expect(poll.ownVotes, isNull);
      expect(poll.emojis, isNull);
    });

    test('expires_at が null (無期限投票) でもパースできる', () {
      final json = _pollJson();
      json['expires_at'] = null;
      final poll = Poll.fromJson(json);
      expect(poll.expiresAt, isNull);
    });

    test('voters_count が null (単一選択投票) は 0 に倒す', () {
      final json = _pollJson();
      json['voters_count'] = null;
      json['expired'] = null;
      json['multiple'] = null;
      final poll = Poll.fromJson(json);
      expect(poll.votersCount, 0);
      expect(poll.expired, false);
      expect(poll.multiple, false);
    });

    test('数値 ID と own_votes の非 int 値を正規化する', () {
      final json = _pollJson();
      json['id'] = 99;
      json['own_votes'] = [0, 1.0, 'x'];
      final poll = Poll.fromJson(json);
      expect(poll.id, '99');
      expect(poll.ownVotes, [0, 1]); // 非数値はスキップ、num は int 化
    });
  });

  group('PollOption.fromJson', () {
    test('votes_count null (集計非公開サーバ) を許容する', () {
      final option = PollOption.fromJson({'title': '非公開'});
      expect(option.title, '非公開');
      expect(option.votesCount, isNull);
    });
  });

  group('PollData.toJson', () {
    test('snake_case のキー名でリクエストボディを構築する', () {
      final data = PollData(
        options: ['A', 'B'],
        expiresInSeconds: 3600,
        multiple: true,
        hideTotals: true,
      );
      expect(data.toJson(), {
        'options': ['A', 'B'],
        'expires_in': 3600,
        'multiple': true,
        'hide_totals': true,
      });
    });

    test('multiple / hideTotals のデフォルトは false', () {
      final data = PollData(options: ['A'], expiresInSeconds: 300);
      final json = data.toJson();
      expect(json['multiple'], false);
      expect(json['hide_totals'], false);
    });
  });
}
