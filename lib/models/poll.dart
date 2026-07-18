// lib/models/poll.dart

import 'emoji.dart';
import 'json_utils.dart';

class Poll {
  final String id;

  /// 投票の締切。Mastodon API 仕様上 nullable (無期限投票)。
  final DateTime? expiresAt;
  final bool expired;
  final bool multiple;
  final int votersCount;
  final int? votesCount;
  final bool? voted;
  final List<int>? ownVotes;
  final List<PollOption> options;
  final List<Emoji>? emojis;

  Poll({
    required this.id,
    this.expiresAt,
    required this.expired,
    required this.multiple,
    required this.votersCount,
    this.votesCount,
    this.voted,
    this.ownVotes,
    required this.options,
    this.emojis,
  });

  factory Poll.fromJson(Map<String, dynamic> json) {
    return Poll(
      id: asIdString(json['id']),
      expiresAt: tryParseDateTime(json['expires_at']),
      expired: json['expired'] as bool? ?? false,
      multiple: json['multiple'] as bool? ?? false,
      // voters_count は仕様上 nullable (単一選択投票では null を返すサーバがある)
      votersCount: json['voters_count'] as int? ?? 0,
      votesCount: json['votes_count'] as int?,
      voted: json['voted'] as bool?,
      ownVotes: (json['own_votes'] as List<dynamic>?)
          ?.whereType<num>()
          .map((e) => e.toInt())
          .toList(),
      options: (json['options'] as List<dynamic>? ?? const [])
          .map((o) => PollOption.fromJson(o as Map<String, dynamic>))
          .toList(),
      emojis: (json['emojis'] as List<dynamic>?)
          ?.map((e) => Emoji.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class PollOption {
  final String title;
  final int? votesCount;

  PollOption({
    required this.title,
    this.votesCount,
  });

  factory PollOption.fromJson(Map<String, dynamic> json) {
    return PollOption(
      title: json['title'] as String? ?? '',
      votesCount: json['votes_count'] as int?,
    );
  }
}

// 投票作成用のデータクラス
class PollData {
  final List<String> options;
  final int expiresInSeconds;
  final bool multiple;
  final bool hideTotals;

  PollData({
    required this.options,
    required this.expiresInSeconds,
    this.multiple = false,
    this.hideTotals = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'options': options,
      'expires_in': expiresInSeconds,
      'multiple': multiple,
      'hide_totals': hideTotals,
    };
  }
}